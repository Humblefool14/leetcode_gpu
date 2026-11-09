// fv_ad_vf_fetch -- ad_vf_fetch control.  Reduction: ADDR_W = 8 (LINE_SHIFT 5, LINE_BYTES 32:
// 3-bit line tags); built with AD_FV_FETCH the attribute's address and limit result come from the
// free inputs fv_addr / fv_oob at MUL (the arithmetic is proven in ad_vf_fetch_addr / _limit /
// _div); line data and af_raw are outside the cone of these properties.
// Environment: STATE written only while !busy (ad_vf.md §10); the memory answers only tags in
// flight, once, never the cycle of the request, read responses only (any order, any error).
// Properties:
//   AMB client (formal/common/ad_amb_client_props.sv: payload held until ready); read only;
//   tags {3'b0, s, entry}, unique among the requests in flight;
//   no request after a hit: a requested line is held by no valid entry of its stream, and the
//     requested entry is pending with that line;
//   af_last exactly once per warp: only while a warp (a vertex with vb_last taken) is open, and
//     the block is never idle with a warp open;  af payload held until af_ready;
//   busy: idle means no request in flight or presented, no af, no pending entry, divider idle.
module fv_ad_vf_fetch #(parameter AW = 8, parameter LS = 5, parameter LBY = 32) (
    input wire              clk,
    input wire              rst_n,
    input wire              st_we,
    input wire [8:0]        st_idx,
    input wire [31:0]       st_wdata,
    input wire              vb_valid,
    input wire [31:0]       vb_index,
    input wire [31:0]       vb_inst,
    input wire [4:0]        vb_lane,
    input wire              vb_last,
    input wire              af_ready,
    input wire              req_ready,
    input wire              rsp_valid,
    input wire              rsp_write,
    input wire [7:0]        rsp_tag,
    input wire [LBY*8-1:0]  rsp_rdata,
    input wire              rsp_error,
    input wire [31:0]       fv_addr,
    input wire              fv_oob
);
    localparam LW = AW - LS;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    wire vb_ready, af_valid, af_oob, af_last, busy, req_valid, req_write;
    wire [3:0] af_attr; wire [4:0] af_lane; wire [127:0] af_raw;
    wire [LW-1:0] req_line; wire [LBY-1:0] req_be; wire [LBY*8-1:0] req_wdata; wire [7:0] req_tag;
    wire [3:0] f_state, f_k; wire [31:0] f_valid, f_pend; wire [32*LW-1:0] f_tags;
    wire f_rq0, f_rq1, f_two, f_vlast, f_divb; wire [2:0] f_e0, f_e1;
    ad_vf_fetch #(.ADDR_W(AW), .LINE_BYTES(LBY), .LINE_SHIFT(LS)) dut (.clk(clk), .rst_n(rst_n),
        .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst), .vb_lane(vb_lane), .vb_last(vb_last),
        .af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane), .af_raw(af_raw),
        .af_oob(af_oob), .af_last(af_last), .busy(busy),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line), .req_be(req_be),
        .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
        .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
        .fv_addr(fv_addr), .fv_oob(fv_oob), .fv_state(f_state), .fv_k(f_k), .fv_valid(f_valid), .fv_pend(f_pend),
        .fv_tags(f_tags), .fv_rq0(f_rq0), .fv_rq1(f_rq1), .fv_e0(f_e0), .fv_e1(f_e1), .fv_two(f_two),
        .fv_vlast(f_vlast), .fv_div_busy(f_divb));

    // AMB client properties (hold until ready); req_valid qualified by rst_n (see fv_ad_amb_mux)
    wire [4:0] n_out;
    ad_amb_client_props #(.LINE_BYTES(LBY), .LINE_W(LW), .CNT_W(5)) u_props (.clk(clk), .rst_n(rst_n),
        .req_valid(req_valid && rst_n), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .outstanding(n_out));

    // memory side
    reg [31:0] out_t;
    wire req_fire = req_valid && req_ready;
    always @(*) begin
        if (rsp_valid) begin
            assume (rsp_tag[7:5] == 3'b000);
            assume (out_t[rsp_tag[4:0]]);
            assume (!rsp_write);
        end
        if (st_we) assume (!busy);
    end
    // warps
    reg w_open;
    wire vb_fire = vb_valid && vb_ready;
    wire af_fire = af_valid && af_ready;
    always @(posedge clk) begin
        if (!rst_n) begin out_t <= 32'd0; w_open <= 1'b0; end
        else begin
            if (rsp_valid) out_t[rsp_tag[4:0]] <= 1'b0;
            if (req_fire)  out_t[req_tag[4:0]] <= 1'b1;
            if (af_fire && af_last) w_open <= 1'b0;
            if (vb_fire && vb_last) w_open <= 1'b1;
        end
    end
    // af held until taken
    reg p_afv, p_afr, p_oob, p_last; reg [3:0] p_attr; reg [4:0] p_lane;
    always @(posedge clk) begin
        p_afv <= af_valid && rst_n; p_afr <= af_ready; p_oob <= af_oob; p_last <= af_last; p_attr <= af_attr; p_lane <= af_lane;
    end

    // stream / entry views
    wire [1:0] rs = req_tag[4:3];
    wire [2:0] re = req_tag[2:0];
    reg        hit_req, ent_ok;
    integer x;
    always @(*) begin
        hit_req = 1'b0; ent_ok = 1'b0;
        for (x = 0; x < 32; x = x + 1) if (rs == x / 8) begin
            if (f_valid[x] && f_tags[x*LW +: LW] == req_line) hit_req = 1'b1;
            if (re == x % 8 && f_pend[x] && f_tags[x*LW +: LW] == req_line) ent_ok = 1'b1;
        end
    end

    always @(*) if (!init && rst_n) begin
        a_rd:     assert (!req_valid || !req_write);
        if (req_valid) begin
            a_tag:    assert (req_tag[7:5] == 3'b000 && req_tag[4:3] == f_k[1:0]);
            a_uniq:   assert (!out_t[req_tag[4:0]]);
            a_nohit:  assert (!hit_req);
            a_ent:    assert (ent_ok);
        end
        if (af_valid && af_last) a_last: assert (w_open);
        if (vb_fire && vb_last)  a_once: assert (!w_open);
        if (!busy) begin
            a_idle_w:  assert (!w_open);
            a_idle_o:  assert (out_t == 32'd0 && n_out == 5'd0);
            a_idle_r:  assert (!req_valid && !af_valid);
            a_idle_p:  assert (f_pend == 32'd0);
            a_idle_d:  assert (!f_divb);
        end
        if (vb_ready) a_vbr: assert (!busy);
        if (p_afv && !p_afr) begin
            a_af_hold: assert (af_valid && af_attr == p_attr && af_lane == p_lane && af_oob == p_oob && af_last == p_last);
        end
        // helper invariants
        h_out:  assert ((out_t & ~f_pend) == 32'd0);              // in flight -> pending
        h_cnt:  assert (n_out == $countones(out_t));
        if (f_state != 4'd5) h_np: assert (f_pend == 32'd0);    // pending only in WAIT
        h_st:   assert (f_state <= 4'd7);
        c_last: cover (af_valid && af_last && af_ready && f_two);
        c_rsp2: cover (rsp_valid && out_t != 32'd0 && (out_t & ~(32'd1 << rsp_tag[4:0])) != 32'd0);
    end
endmodule
