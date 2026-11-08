// fv_ad_su_tex_ret -- ad_su_tex_ret (NPHYS 8: two quads a group).  Records are numbered as they
// are pushed (rq_rd = 4 x the push number, rq_last and rq_sz taken from per-number constants);
// every other input is free.  Properties: the beats come in record order and, within a record,
// rd, rd+1, rd+2, rd+3 (texsz: rd only); l_last exactly on the last beat of a record with
// rq_last (one per instruction); l_wr 1, l_cls t; the beat held while l_valid && !l_ready; at most
// five records in the unit (four in the FIFO, one being returned).
module fv_ad_su_tex_ret (
    input wire clk,
    input wire rst_n,
    input wire rq_valid,
    input wire [1:0] rq_warp,
    input wire [1:0] rq_grp,
    input wire [2:0] rq_sbe,
    input wire [1:0] rq_qmask,
    input wire [7:0] rq_lanes,
    input wire tr_valid,
    input wire [511:0] tr_data,
    input wire l_ready
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    (* anyconst *) reg [7:0] lm, sm;
    reg [7:0] pc, rc;
    reg [1:0] bc;
    wire rq_ready, tr_ready, l_valid, l_wr, l_last;
    wire [1:0] l_warp, l_grp;
    wire [6:0] l_rd;
    wire [255:0] l_data;
    wire [7:0] l_lanes;
    wire [2:0] l_sbe, l_cls;
    ad_su_tex_ret #(.NPHYS(8), .WARP_W(2), .GRP_W(2), .SBE_W(2)) dut (
        .clk(clk), .rst_n(rst_n), .rq_valid(rq_valid), .rq_ready(rq_ready), .rq_warp(rq_warp),
        .rq_grp(rq_grp), .rq_rd({pc[4:0], 2'b00}), .rq_sbe(rq_sbe), .rq_last(lm[pc[2:0]]),
        .rq_sz(sm[pc[2:0]]), .rq_qmask(rq_qmask), .rq_lanes(rq_lanes), .tr_valid(tr_valid),
        .tr_ready(tr_ready), .tr_data(tr_data), .l_valid(l_valid), .l_ready(l_ready),
        .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes),
        .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe), .l_cls(l_cls));

    wire lastb = sm[rc[2:0]] ? (bc == 2'd0) : (bc == 2'd3);
    always @(posedge clk) begin
        if (!rst_n) begin
            pc <= 8'd0;
            rc <= 8'd0;
            bc <= 2'd0;
        end else begin
            if (rq_valid && rq_ready) pc <= pc + 8'd1;
            if (l_valid && l_ready) begin
                if (lastb) begin
                    rc <= rc + 8'd1;
                    bc <= 2'd0;
                end else bc <= bc + 2'd1;
            end
        end
    end
    reg pv;
    reg [6:0] prd;
    reg pl;
    always @(posedge clk) begin
        pv <= rst_n && l_valid && !l_ready;
        prd <= l_rd;
        pl <= l_last;
    end
    wire [7:0] inside = pc - rc;
    always @(*) if (rst_n && !init) begin
        assert (inside <= 8'd5);
        if (l_valid) begin
            assert (inside != 8'd0);
            assert (l_rd == {rc[4:0], bc});
            assert (l_last == (lm[rc[2:0]] && lastb));
            assert (l_wr && l_cls == 3'd3);
        end
        if (pv) assert (l_valid && l_rd == prd && l_last == pl);
    end
endmodule
