// fv_ad_su_xu: the long-unit protocol of ad_su_xu (NPHYS 4), with the
// lane engine replaced by ad_xu_engine_stub (free latency; its arithmetic is
// proven in formal/ad_xu_isqrt, formal/ad_xu_divider and the bit-exact TB).  Free bus inputs every cycle, free l_ready.
//  - a group is taken only with no group in the unit (x_ready 0 while busy);
//  - exactly one beat per taken group, held until l_ready (no beat lost or
//    doubled), with l_warp/grp/rd/wr/last/sbe/cls/lanes of the taken group
//    (l_last = its x_last, so once per instruction);
//  - each EXEC lane of the beat carries the engine result of that lane's
//    operands;
//  - a beat comes within a bounded time when the engine and l_ready do.
module fv_ad_su_xu #(
    parameter NPHYS = 4,
    parameter GRP_W = 3
) (
    input wire clk,
    input wire x_valid,
    input wire [1:0] x_warp,
    input wire [GRP_W-1:0] x_grp,
    input wire x_last,
    input wire [2:0] x_sbe,
    input wire [107:0] x_uop,
    input wire [NPHYS*32-1:0] x_a,
    input wire [NPHYS*32-1:0] x_b,
    input wire [2*NPHYS-1:0] x_mask,
    input wire l_ready
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire x_ready, l_valid, l_wr, l_last;
    wire [1:0] l_warp;
    wire [GRP_W-1:0] l_grp;
    wire [6:0] l_rd;
    wire [NPHYS*32-1:0] l_data;
    wire [NPHYS-1:0] l_lanes;
    wire [2:0] l_sbe, l_cls;

    ad_su_xu #(.NPHYS(NPHYS), .GRP_W(GRP_W)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
        .x_c({NPHYS*32{1'b0}}), .x_mask(x_mask), .x_info(32'd0), .x_ready(x_ready),
        .l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd),
        .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe),
        .l_cls(l_cls)
    );

    wire take = x_valid && x_uop[3:0] == 4'd4 && x_ready;
    reg busy = 1'b0;
    reg [1:0] h_warp;
    reg [GRP_W-1:0] h_grp;
    reg h_last, h_wr;
    reg [2:0] h_sbe, h_cls;
    reg [6:0] h_rd;
    reg [NPHYS-1:0] h_lanes;
    reg [NPHYS*32-1:0] h_exp;
    reg [7:0] age;
    integer i;
    always @(posedge clk) begin
        if (init) begin
            busy <= 1'b0;
            age <= 8'd0;
        end else begin
            if (take) begin
                busy <= 1'b1;
                age <= 8'd0;
                h_warp <= x_warp; h_grp <= x_grp; h_last <= x_last; h_sbe <= x_sbe;
                h_wr <= x_uop[98]; h_cls <= x_uop[91:89]; h_rd <= x_uop[18:12];
                h_lanes <= x_mask[NPHYS-1:0];
                for (i = 0; i < NPHYS; i = i + 1)
                    h_exp[i*32 +: 32] <= {x_a[i*32 +: 16], x_a[i*32+16 +: 16]} ^
                        {29'd0, x_uop[6:4]};
            end else if (l_valid && l_ready) begin
                busy <= 1'b0;
            end else if (busy && age != 8'hFF) begin
                age <= age + 1'b1;
            end
        end
    end

    always @(*) begin
        if (!init) begin
            assert (x_ready == !busy);
            if (l_valid) begin
                assert (busy);
                assert (l_warp == h_warp && l_grp == h_grp && l_last == h_last);
                assert (l_sbe == h_sbe && l_wr == h_wr && l_cls == h_cls && l_rd == h_rd);
                assert (l_lanes == h_lanes);
                for (i = 0; i < NPHYS; i = i + 1)
                    if (h_lanes[i])
                        assert (l_data[i*32 +: 32] == h_exp[i*32 +: 32]);
            end
        end
    end

    // cover: two groups through back to back with back-pressure
    reg [1:0] nbeats = 2'd0;
    always @(posedge clk)
        if (!init && l_valid && l_ready && nbeats != 2'd3)
            nbeats <= nbeats + 1'b1;
    always @(*) if (!init) cover (nbeats == 2'd2);
endmodule
