// fv_ad_su_lsu -- formal harness of ad_su_lsu (NPHYS 4, ADDR_W 8, 8-byte lines).
// Every input is free each cycle; reset in the first cycle only.  The D$ port
// is checked with formal/common/ad_amb_client_props.sv (payload held until
// ready; responses only for outstanding requests are assumed); the atomic
// port likewise (held until at_ready; at_rsp_valid only when one is
// outstanding).  Properties: a beat only for a taken group (one group in
// flight, fences excluded), its l_last is the group's x_last, so exactly one
// l_last per instruction; D$ and atomic requests only while a group is in
// flight; a beat (completion) only when no D$ request (in particular no
// write) and no atomic is outstanding; no group is taken while one is in flight.
// Helper invariants h_* (on the state, fv_st, an output of ad_su_lsu under
// `ifdef FORMAL) make the properties inductive: prove is k-induction (smtbmc z3).
module fv_ad_su_lsu (
    input wire clk,
    input wire rst_n,
    input wire x_valid, input wire [1:0] x_warp, input wire [2:0] x_grp, input wire x_last,
    input wire [2:0] x_sbe, input wire [107:0] x_uop,
    input wire [127:0] x_a, input wire [127:0] x_b, input wire [127:0] x_c, input wire [7:0] x_mask,
    input wire l_ready,
    input wire dc_req_ready, input wire dc_rsp_valid, input wire dc_rsp_write, input wire [7:0] dc_rsp_tag,
    input wire [63:0] dc_rsp_rdata, input wire dc_rsp_error,
    input wire at_ready, input wire at_rsp_valid, input wire [31:0] at_old, input wire at_error
);
    localparam NP = 4, AW = 8, LB = 8, LS = 3;
    `include "ad_su_uop.vh"
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) begin
        if (init) assume (!rst_n);
        else assume (rst_n);
    end

    wire x_ready, l_valid, l_wr, l_last, dc_req_valid, dc_req_write, at_valid, dc_inv;
    wire [1:0] l_warp; wire [2:0] l_grp, l_sbe, l_cls; wire [6:0] l_rd;
    wire [127:0] l_data; wire [3:0] l_lanes;
    wire [AW-LS-1:0] dc_req_line; wire [LB-1:0] dc_req_be; wire [LB*8-1:0] dc_req_wdata; wire [7:0] dc_req_tag;
    wire [2:0] fv_st;
    wire [3:0] at_op; wire [29:0] at_addr; wire [31:0] at_a, at_b;

    ad_su_lsu #(.NPHYS(NP), .GRP_W(3), .UOP_W(108), .ADDR_W(AW), .LINE_BYTES(LB), .LINE_SHIFT(LS)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp),
        .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last),
        .l_sbe(l_sbe), .l_cls(l_cls),
        .dc_req_valid(dc_req_valid), .dc_req_ready(dc_req_ready), .dc_req_write(dc_req_write),
        .dc_req_line(dc_req_line), .dc_req_be(dc_req_be), .dc_req_wdata(dc_req_wdata), .dc_req_tag(dc_req_tag),
        .dc_rsp_valid(dc_rsp_valid), .dc_rsp_write(dc_rsp_write), .dc_rsp_tag(dc_rsp_tag),
        .dc_rsp_rdata(dc_rsp_rdata), .dc_rsp_error(dc_rsp_error),
        .at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr), .at_a(at_a), .at_b(at_b),
        .at_rsp_valid(at_rsp_valid), .at_old(at_old), .at_error(at_error), .dc_inv(dc_inv), .fv_st(fv_st));

    wire [4:0] dc_out;
    ad_amb_client_props #(.LINE_BYTES(LB), .LINE_W(AW-LS), .CNT_W(5)) amb (
        .clk(clk), .rst_n(rst_n), .req_valid(dc_req_valid), .req_ready(dc_req_ready),
        .req_write(dc_req_write), .req_line(dc_req_line), .req_be(dc_req_be), .req_wdata(dc_req_wdata),
        .req_tag(dc_req_tag), .rsp_valid(dc_rsp_valid), .outstanding(dc_out));

    // atomic port: hold until taken; responses only when outstanding
    reg [3:0] at_out = 4'd0;
    reg pa_v, pa_r; reg [3:0] pa_op; reg [29:0] pa_addr; reg [31:0] pa_a, pa_b;
    reg past_ok = 1'b0;
    always @(posedge clk) begin
        past_ok <= rst_n;
        pa_v <= at_valid; pa_r <= at_ready; pa_op <= at_op; pa_addr <= at_addr; pa_a <= at_a; pa_b <= at_b;
        if (!rst_n) at_out <= 4'd0;
        else at_out <= at_out + (at_valid && at_ready) - at_rsp_valid;
    end
    always @(*) if (at_out == 4'd0 || !rst_n) assume (!at_rsp_valid);
    always @(posedge clk) if (past_ok && rst_n && pa_v && !pa_r) begin
        a_at_hold: assert (at_valid && at_op == pa_op && at_addr == pa_addr && at_a == pa_a && at_b == pa_b);
    end

    // groups in flight
    wire mine  = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_LSU;
    wire take  = mine && x_ready;
    wire fence = x_uop[AD_UOP_OP +: 8] == AD_LSU_FENCE;
    reg inflight = 1'b0, g_last = 1'b0;
    reg [2:0] g_sbe;
    always @(posedge clk) begin
        if (!rst_n) inflight <= 1'b0;
        else begin
            if (l_valid && l_ready) inflight <= 1'b0;
            if (take && !fence) begin inflight <= 1'b1; g_last <= x_last; g_sbe <= x_sbe; end
        end
    end
    always @(*) if (rst_n && !init) begin
        a_beat_taken:  assert (!l_valid || inflight);
        if (l_valid) begin
            a_last:     assert (l_last == g_last);
            a_sbe:      assert (l_sbe == g_sbe);
            a_wr_done:  assert (dc_out == 5'd0);
            a_at_done:  assert (at_out == 4'd0);
        end
        a_one:      assert (!(take && inflight && !(l_valid && l_ready)));
        a_req_in:   assert (!dc_req_valid || inflight);
        a_at_in:    assert (!at_valid || inflight);
        a_out1:     assert (dc_out <= 5'd1 && at_out <= 4'd1);
        // helper invariants (make the properties inductive for k-induction)
        h_idle:     assert (inflight == !x_ready);
        h_glast:    assert (!inflight || (l_last == g_last && l_sbe == g_sbe));
        h_st:       assert (fv_st <= 3'd5);
        h_wait:     assert ((fv_st == 3'd2) == (dc_out == 5'd1));
        h_atw:      assert ((fv_st == 3'd4) == (at_out == 4'd1));
    end
endmodule
