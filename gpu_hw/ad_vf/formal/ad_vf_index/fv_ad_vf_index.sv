// fv_ad_vf_index -- ad_vf_index reduced to ADDR_W 8, LINE_BYTES 4 (task bmc8: 8), COUNT <= 7,
// INSTANCE_COUNT <= 3 (assumed on the STATE writes; the counters stay 32 bits).
// Memory: byte a of the address space is 0xFF on one arbitrary line (anyconst, to get restart
// markers) and a ^ key elsewhere; responses come for an outstanding tag only, in any order, any
// time after the request, with a free rsp_error.  The CP writes STATE only while idle.
// Checked: AMB client rules (shared ad_amb_client_props: payload held until ready), reads only,
// tag bit 0 only, at most two requests in flight; every iv item against a reference walk
// (index FIRST + n or the buffer's u16 / u32 at INDEX_BASE + (FIRST + n) * size, restart, inst
// FIRST_INSTANCE + i, last on the final item); iv held until taken; COUNT 0 / INSTANCE_COUNT 0:
// busy does not rise; a kick while busy changes nothing; after rsp_error no further iv, no new
// request, busy until every request is answered; idle => nothing in flight and no iv.
// Tasks: bmc (LINE_BYTES 4) and bmc8 (LINE_BYTES 8): every property, full 32-bit counters.
// prove: the control properties (FV_NODATA drops the index / inst / restart data checks) with
// the RTL's walk counters narrowed to 4 bits (AD_FV_IDX_CW = 4; COUNT <= 7, INSTANCE_COUNT <= 3).
`include "ad_vf_state.vh"
module fv_ad_vf_index #(
    parameter LB = 4,
    parameter LS = 2
) (
    input wire        clk,
    input wire        rst_n,
    input wire        st_we,
    input wire [8:0]  st_idx,
    input wire [31:0] st_wdata,
    input wire        kick,
    input wire        iv_ready,
    input wire        req_ready,
    input wire        rsp_valid,
    input wire        rsp_tag0,
    input wire        rsp_error
);
    localparam AW = 8, LW = AW - LS;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    (* anyconst *) reg [7:0] key;
    (* anyconst *) reg [LW-1:0] ffline;
    function [7:0] mb(input [AW-1:0] a); mb = (a[AW-1:LS] == ffline) ? 8'hFF : (a ^ key); endfunction

    wire busy, iv_valid, iv_restart, iv_last, req_valid, req_write; wire [31:0] iv_index, iv_inst;
    wire [LW-1:0] req_line; wire [LB-1:0] req_be; wire [LB*8-1:0] req_wdata; wire [7:0] req_tag;
    reg  [LB*8-1:0] rsp_rdata;
`ifdef AD_FV_IDX
    wire [1:0] f_st, b0, b1; wire f_eptr, f_rptr, f_we_act, f_we_lastn, f_kidx, f_wr_act; wire [3:0] f_we_n, f_we_i;
`endif
    ad_vf_index #(.ADDR_W(AW), .LINE_BYTES(LB), .LINE_SHIFT(LS)) dut (.clk(clk), .rst_n(rst_n), .st_we(st_we),
        .st_idx(st_idx), .st_wdata(st_wdata), .kick(kick), .busy(busy), .iv_valid(iv_valid), .iv_ready(iv_ready),
        .iv_index(iv_index), .iv_inst(iv_inst), .iv_restart(iv_restart), .iv_last(iv_last),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line), .req_be(req_be),
        .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(1'b0), .rsp_tag({7'd0, rsp_tag0}),
        .rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
`ifdef AD_FV_IDX
        , .fv_st(f_st), .fv_bst0(b0), .fv_bst1(b1), .fv_eptr(f_eptr), .fv_rptr(f_rptr), .fv_we_act(f_we_act),
        .fv_we_n(f_we_n), .fv_we_i(f_we_i), .fv_we_lastn(f_we_lastn), .fv_kidx(f_kidx), .fv_wr_act(f_wr_act)
`endif
        );
    wire [4:0] outst;
    ad_amb_client_props #(.LINE_BYTES(LB), .LINE_W(LW), .CNT_W(5)) u_props (.clk(clk), .rst_n(rst_n),
        .req_valid(req_valid && rst_n), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .outstanding(outst));

    // memory side: per tag one request outstanding at most (asserted), answered once
    reg pend0, pend1; reg [LW-1:0] pl0, pl1;
    integer k;
    always @(*) begin
        if (rsp_valid) assume (rsp_tag0 ? pend1 : pend0);
        rsp_rdata = {LB*8{1'b0}};
        for (k = 0; k < LB; k = k + 1) rsp_rdata[8*k +: 8] = mb({(rsp_tag0 ? pl1 : pl0), {LS{1'b0}}} + k);
    end
    always @(posedge clk) begin
        if (!rst_n) begin pend0 <= 1'b0; pend1 <= 1'b0; end
        else begin
            if (rsp_valid && !rsp_tag0) pend0 <= 1'b0;
            if (rsp_valid &&  rsp_tag0) pend1 <= 1'b0;
            if (req_valid && req_ready) begin
                if (req_tag[0]) begin pend1 <= 1'b1; pl1 <= req_line; end
                else            begin pend0 <= 1'b1; pl0 <= req_line; end
            end
        end
    end

    // STATE shadow (the CP writes only while idle) and small counts
    reg [31:0] h_base, h_first, h_count, h_finst, h_icnt; reg [1:0] h_fmt; reg h_rst;
    always @(*) if (st_we) begin
        assume (!busy);
        if (st_idx == `AD_S_COUNT) assume (st_wdata <= 32'd7);
        if (st_idx == `AD_S_INSTANCE_COUNT) assume (st_wdata <= 32'd3);
        if (st_idx == `AD_S_INDEX_BASE) assume (st_wdata[1:0] == 2'b00);   // aligned to the index size
    end
    always @(posedge clk) begin
        if (!rst_n) begin h_base <= 0; h_first <= 0; h_count <= 0; h_finst <= 0; h_icnt <= 0; h_fmt <= 0; h_rst <= 0; end
        else if (st_we) begin
            if (st_idx == `AD_S_INDEX_BASE)     h_base  <= st_wdata;
            if (st_idx == `AD_S_INDEX_FORMAT)   h_fmt   <= st_wdata[1:0];
            if (st_idx == `AD_S_FIRST)          h_first <= st_wdata;
            if (st_idx == `AD_S_COUNT)          h_count <= st_wdata;
            if (st_idx == `AD_S_FIRST_INSTANCE) h_finst <= st_wdata;
            if (st_idx == `AD_S_INSTANCE_COUNT) h_icnt  <= st_wdata;
            if (st_idx == `AD_S_PRIM_RESTART)   h_rst   <= st_wdata[0];
        end
    end

    // reference walk
    reg r_on, r_err; reg [2:0] r_n; reg [1:0] r_i; reg [31:0] r_first, r_finst, r_base; reg [2:0] r_cn; reg [1:0] r_ci;
    reg [1:0] r_fmt; reg r_rst;
    wire start = kick && !busy && h_count != 0 && h_icnt != 0;
    wire r_u32 = r_fmt[1];
    wire [AW-1:0] r_a = r_base[AW-1:0] + (r_u32 ? ((r_first[AW-1:0] + r_n) << 2) : ((r_first[AW-1:0] + r_n) << 1));
    wire [31:0] r_raw = r_u32 ? {mb(r_a + 3), mb(r_a + 2), mb(r_a + 1), mb(r_a)} : {16'd0, mb(r_a + 1), mb(r_a)};
    wire [31:0] r_idx = (r_fmt == 2'd0) ? r_first + r_n : r_raw;
    wire r_rs = (r_fmt != 2'd0) && r_rst && (r_u32 ? (&r_raw) : (&r_raw[15:0]));
    wire r_last = (r_n == r_cn - 1) && (r_i == r_ci - 1);
    always @(posedge clk) begin
        if (!rst_n) begin r_on <= 1'b0; r_err <= 1'b0; end
        else begin
            if (start) begin
                r_on <= 1'b1; r_err <= 1'b0; r_n <= 0; r_i <= 0; r_first <= h_first; r_finst <= h_finst; r_base <= h_base;
                r_cn <= h_count[2:0]; r_ci <= h_icnt[1:0]; r_fmt <= h_fmt; r_rst <= h_rst;
            end
            if (rsp_valid && rsp_error && busy) r_err <= 1'b1;
            if (iv_valid && iv_ready) begin
                if (r_last) r_on <= 1'b0;
                else if (r_n == r_cn - 1) begin r_n <= 0; r_i <= r_i + 1'b1; end
                else r_n <= r_n + 1'b1;
            end
        end
    end

    reg p_iv = 1'b0, p_ir, p_err, p_rv = 1'b0; reg [31:0] p_ix, p_in; reg p_rs, p_la, p_busy = 1'b0;
    always @(posedge clk) begin
        p_iv <= iv_valid && rst_n; p_ir <= iv_ready; p_ix <= iv_index; p_in <= iv_inst; p_rs <= iv_restart;
        p_la <= iv_last; p_err <= r_err; p_busy <= busy && rst_n; p_rv <= req_valid && rst_n;
    end
    always @(*) if (!init && rst_n) begin
        a_rd:    assert (!req_valid || (!req_write && req_tag[7:1] == 7'd0));
        a_out:   assert (outst <= 5'd2);
        a_pend:  assert (outst == {4'd0, pend0} + {4'd0, pend1});
        if (req_valid) a_tagfree: assert (req_tag[0] ? !pend1 : !pend0);     // one request per buffer
        if (r_on && !r_err) a_busy1: assert (busy);
        if (busy) a_busy2: assert (r_on || r_err);
        if (r_err && (outst != 0 || req_valid)) a_drain: assert (busy);
        if (!busy) a_idle: assert (!req_valid && outst == 5'd0 && !iv_valid);
        if (iv_valid) a_on: assert (r_on && !r_err);
        if (iv_valid) a_last: assert (iv_last == r_last);
`ifndef FV_NODATA
        if (iv_valid) begin
            a_idx:  assert (iv_index == r_idx);
            a_rs:   assert (iv_restart == r_rs);
            a_inst: assert (iv_inst == r_finst + r_i);
        end
        if (p_iv && !p_ir && !r_err) a_ivdata: assert (iv_index == p_ix && iv_inst == p_in && iv_restart == p_rs);
`endif
        if (r_err && req_valid) a_noreq: assert (p_rv);                        // no new request after rsp_error
        if (p_iv && !p_ir && !r_err) a_ivhold: assert (iv_valid && iv_last == p_la);
        if (!p_busy && busy) a_rise: assert (r_on);
    end
`ifdef AD_FV_IDX
    // helper invariants for the prove task (white box, AD_FV_IDX ports)
    wire [1:0] be = f_eptr ? b1 : b0, bo = f_eptr ? b0 : b1;
    always @(*) if (!init && rst_n) begin
        h_b: assert (b0 != 2'd3 && b1 != 2'd3);
        h_p0: assert (pend0 == (b0 == 2'd1 && !(req_valid && !req_tag[0])));
        h_p1: assert (pend1 == (b1 == 2'd1 && !(req_valid && req_tag[0])));
        if (req_valid) h_rq: assert (req_tag[0] == !f_rptr && (req_tag[0] ? b1 : b0) == 2'd1);
        h_ord: assert (f_rptr == f_eptr ? ((b0 == 2'd0) == (b1 == 2'd0)) : (be != 2'd0 && bo == 2'd0));
        h_on: assert (r_on == f_we_act);
        if (f_st == 2'd1) h_walk: assert (r_on && !r_err);
        if (f_st == 2'd2) h_drn: assert (r_err);
        h_st: assert (f_st != 2'd3);
        if (!busy) h_idle: assert (b0 != 2'd1 && b1 != 2'd1);
        if (r_on) begin
            h_n: assert (f_we_n == {1'b0, r_n} && f_we_i == {2'b0, r_i});
            h_m: assert (f_we_lastn == (r_n == r_cn - 1));
            h_k: assert (f_kidx == (r_fmt != 2'd0));
        end
    end
`endif
endmodule
