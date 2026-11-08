// ad_ctl_sb_sil -- the short-result interlock of ad_su_sb (design §3.1.1,
// spec ad_su_sb §10).  Every issued instruction enters an in-order list
// (OQ entries) until x_end (its last group leaves ad_su_opd); a short writer
// (class a/f, rd < 63) then gets a tracker counting SHORT_LAT+1 cycles
// (the count is SHORT_LAT+1 in the cycle after x_end and falls by one per
// cycle; the tracker is free at 0).  For the instruction being checked
// (warp q_warp):
//   hold_rd: a GPR source equals the rd of a short writer of the same warp
//            that is still in the list, or whose count is above G + 1
//            (G = 32/NPHYS);
//   hold_wr: its destination range (a long writer's) covers such an rd that
//            is in the list or counting at all.
// full: the list has no room (the parent does not issue).  Sources are
// 8-bit operand numbers (GPR when below 63), as ad_ctl_sb_ovl.
module ad_ctl_sb_sil #(
    parameter WARP_W    = 2,
    parameter NPHYS     = 8,
    parameter SHORT_LAT = 6,
    parameter OQ        = 4
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              push,
    input  wire [WARP_W-1:0] push_warp,
    input  wire              push_sw,
    input  wire [5:0]        push_rd,
    input  wire              x_end,
    input  wire [WARP_W-1:0] q_warp,
    input  wire [4:0]        q_use,
    input  wire [39:0]       q_src,
    input  wire              q_dst_use,
    input  wire [5:0]        q_dst,
    input  wire              q_dst_w4,
    output reg               hold_rd,
    output reg               hold_wr,
    output wire              full,
    output wire              idle
);
    localparam G   = 32 / NPHYS;
    localparam NT  = SHORT_LAT + 2;
    localparam CW  = $clog2(SHORT_LAT + 2);
    localparam QW  = $clog2(OQ + 1);
    localparam [CW-1:0] CNT0 = SHORT_LAT + 1;

    // the in-order list (entry 0 is the oldest)
    reg [WARP_W-1:0] lw [0:OQ-1];
    reg              ls [0:OQ-1];
    reg [5:0]        lr [0:OQ-1];
    reg [QW-1:0]     ln;
    // trackers
    reg              tv [0:NT-1];
    reg [WARP_W-1:0] tw [0:NT-1];
    reg [5:0]        tr [0:NT-1];
    reg [CW-1:0]     tc [0:NT-1];

    assign full = ln == OQ;
    reg any_t;
    integer i, s;
    always @(*) begin
        any_t = 1'b0;
        for (i = 0; i < NT; i = i + 1) if (tv[i]) any_t = 1'b1;
    end
    assign idle = ln == 0 && !any_t;

    wire pop = x_end && ln != 0;
    // free tracker for the popped short writer
    reg [CW:0] fr;
    always @(*) begin
        fr = NT;
        for (i = NT - 1; i >= 0; i = i - 1) if (!tv[i]) fr = i;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            ln <= 0;
            for (i = 0; i < NT; i = i + 1) begin tv[i] <= 1'b0; tc[i] <= 0; end
        end else begin
            for (i = 0; i < NT; i = i + 1)
                if (tv[i]) begin
                    tc[i] <= tc[i] - 1'b1;
                    if (tc[i] == 1) tv[i] <= 1'b0;
                end
            if (pop && ls[0] && fr != NT) begin
                tv[fr] <= 1'b1; tw[fr] <= lw[0]; tr[fr] <= lr[0]; tc[fr] <= CNT0;
            end
            if (pop) begin
                for (i = 0; i < OQ - 1; i = i + 1) begin
                    lw[i] <= lw[i+1]; ls[i] <= ls[i+1]; lr[i] <= lr[i+1];
                end
            end
            if (push) begin
                lw[ln - pop] <= push_warp; ls[ln - pop] <= push_sw; lr[ln - pop] <= push_rd;
            end
            ln <= ln + push - pop;
        end
    end

    // query
    reg [7:0] n, dlo, dhi;
    always @(*) begin
        hold_rd = 1'b0;
        hold_wr = 1'b0;
        n = 8'd0;
        dlo = {2'b00, q_dst};
        dhi = dlo + (q_dst_w4 ? 8'd4 : 8'd1);
        for (i = 0; i < OQ; i = i + 1)
            if (i < ln && ls[i] && lw[i] == q_warp) begin
                for (s = 0; s < 5; s = s + 1) begin
                    n = q_src[8*s +: 8];
                    if (q_use[s] && n < 8'd63 && n == {2'b00, lr[i]}) hold_rd = 1'b1;
                end
                if (q_dst_use && {2'b00, lr[i]} >= dlo && {2'b00, lr[i]} < dhi) hold_wr = 1'b1;
            end
        for (i = 0; i < NT; i = i + 1)
            if (tv[i] && tw[i] == q_warp) begin
                for (s = 0; s < 5; s = s + 1) begin
                    n = q_src[8*s +: 8];
                    if (q_use[s] && n < 8'd63 && n == {2'b00, tr[i]} && tc[i] > G + 1) hold_rd = 1'b1;
                end
                if (q_dst_use && {2'b00, tr[i]} >= dlo && {2'b00, tr[i]} < dhi) hold_wr = 1'b1;
            end
    end
endmodule
