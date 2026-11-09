// ad_vf_fetch -- VF attribute fetch (spec/gpu/vf/ad_vf_fetch.md).
//
// For each vertex from vb_* (one at a time) and each enabled attribute k (ATTR_DST[k] != 0) in
// ascending k: element (per vertex: the index; per instance: Vulkan's divisor rule), address
// ATTR_BASE + stride * element (mod 2^32), size from the format (ad_vf_fmt_info), ATTR_LIMIT
// check (49 bits), line-buffer lookup in stream s = k[1:0] (4 streams x 8 lines), AMB reads of
// the missing lines (tag {3'b0, s, entry}), then one af (lane-major order).  af_last on the last
// attribute of the vertex with vb_last; a warp with no enabled attribute sends one dummy af
// (attr 0, af_last).  The line buffers are cleared when the af with af_last is taken.
//
// FSM (spec §5): IDLE -(vb)-> ELEM -> [DIV] -> MUL -> PLAN -> [WAIT: REQ + DATA] -> EMIT
//                -> ELEM (next enabled attribute) | IDLE;  IDLE -(vb_last, no attribute)-> NONE.
//
// Leaves (rtl/vf/fetch/): ad_vf_fetch_regs (STATE), ad_vf_fetch_div (divider + memo),
// ad_vf_fetch_addr (multiply/add, lines), ad_vf_fetch_limit (ATTR_LIMIT), ad_vf_fetch_lbuf
// (one stream's line buffer, x4), ad_vf_fetch_extract (bytes); rtl/vf/fmt/ad_vf_fmt_info.
//
// Formal only (AD_FV_FETCH): the address and the limit result are taken from free inputs
// fv_addr / fv_oob (the arithmetic is proven in the leaves), and internal state is observable.
`include "ad_vf_state.vh"
module ad_vf_fetch #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire                         clk,
    input  wire                         rst_n,
    // STATE broadcast
    input  wire                         st_we,
    input  wire [8:0]                   st_idx,
    input  wire [31:0]                  st_wdata,
    // vertices of a warp
    input  wire                         vb_valid,
    output wire                         vb_ready,
    input  wire [31:0]                  vb_index,
    input  wire [31:0]                  vb_inst,
    input  wire [4:0]                   vb_lane,
    input  wire                         vb_last,
    // attribute data
    output wire                         af_valid,
    input  wire                         af_ready,
    output wire [3:0]                   af_attr,
    output wire [4:0]                   af_lane,
    output wire [127:0]                 af_raw,
    output wire                         af_oob,
    output wire                         af_last,
    output wire                         busy,
    // AMB client port
    output wire                         req_valid,
    input  wire                         req_ready,
    output wire                         req_write,
    output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
    output wire [LINE_BYTES-1:0]        req_be,
    output wire [LINE_BYTES*8-1:0]      req_wdata,
    output wire [7:0]                   req_tag,
    input  wire                         rsp_valid,
    input  wire                         rsp_write,
    input  wire [7:0]                   rsp_tag,
    input  wire [LINE_BYTES*8-1:0]      rsp_rdata,
    input  wire                         rsp_error
`ifdef AD_FV_FETCH
    // formal-only: free address / limit result, observation
    ,input  wire [31:0]                 fv_addr
    ,input  wire                        fv_oob
    ,output wire [3:0]                  fv_state
    ,output wire [3:0]                  fv_k
    ,output wire [31:0]                 fv_valid      // {stream 3 .. stream 0} x 8 entries
    ,output wire [31:0]                 fv_pend
    ,output wire [32*(ADDR_W-LINE_SHIFT)-1:0] fv_tags
    ,output wire                        fv_rq0
    ,output wire                        fv_rq1
    ,output wire [2:0]                  fv_e0
    ,output wire [2:0]                  fv_e1
    ,output wire                        fv_two
    ,output wire                        fv_vlast
    ,output wire                        fv_div_busy
`endif
);
    localparam LW = ADDR_W - LINE_SHIFT;
    localparam LB = LINE_BYTES * 8;
    localparam S_IDLE = 4'd0, S_ELEM = 4'd1, S_DIV = 4'd2, S_MUL = 4'd3, S_PLAN = 4'd4,
               S_WAIT = 4'd5, S_EMIT = 4'd6, S_NONE = 4'd7;

    reg  [3:0]  state;
    reg  [3:0]  k;
    reg  [31:0] v_index, v_inst;
    reg  [4:0]  v_lane;
    reg         v_last;
    reg  [31:0] elem_r;
    reg  [31:0] addr_r;
    reg  [LW-1:0] line0_r, line1_r;
    reg         two_r, oob_r;
    reg  [2:0]  e0_r, e1_r;
    reg         rq0, rq1;

    // ---------------------------------------------------------------- STATE
    wire [15:0] en;
    wire [31:0] a_base, a_desc, a_dst, a_lim, first_inst;
    ad_vf_fetch_regs u_regs (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .k(k), .en(en), .base(a_base), .desc(a_desc), .dst(a_dst), .limit(a_lim), .first_inst(first_inst));

    wire [4:0] f_size; wire [2:0] f_ncomp, f_kind;
    ad_vf_fmt_info u_info (.vkfmt(a_dst[`AD_DST_VKFMT]), .legacy(a_desc[`AD_DESC_FMT]),
        .size(f_size), .ncomp(f_ncomp), .kind(f_kind));

    // enabled attributes: the first, and the next after k
    reg        any_en, has_next;
    reg [3:0]  first_k, next_k;
    integer j;
    always @(*) begin
        any_en = |en; has_next = 1'b0; first_k = 4'd0; next_k = 4'd0;
        for (j = 15; j >= 0; j = j - 1) begin
            if (en[j]) first_k = j[3:0];
            if (en[j] && j > k) begin has_next = 1'b1; next_k = j[3:0]; end
        end
    end

    // ---------------------------------------------------------------- element
    wire        a_inst = a_desc[`AD_DESC_INST];
    wire [7:0]  a_div  = a_desc[`AD_DESC_DIV];
    wire        need_div = a_inst && (a_div > 8'd1);
    wire [31:0] elem_now = !a_inst          ? v_index :
                           (a_div == 8'd0)  ? first_inst :
                                              v_inst;           // divisor 1
    wire        div_busy, div_done;
    wire [31:0] div_q; wire [7:0] div_r;
    ad_vf_fetch_div u_div (.clk(clk), .rst_n(rst_n), .start(state == S_ELEM && need_div),
        .n(v_inst - first_inst), .d(a_div), .busy(div_busy), .done(div_done), .q(div_q), .r(div_r));

    // ---------------------------------------------------------------- address, limit
    wire [31:0] m_addr; wire [48:0] m_end; wire [LW-1:0] m_l0, m_l1; wire m_two, m_oob;
    wire [LINE_SHIFT-1:0] m_off;
`ifdef AD_FV_FETCH
    ad_vf_fetch_addr #(.ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) u_addr (.base(fv_addr), .stride(16'd0),
        .elem(elem_r), .size(f_size), .addr(m_addr), .end49(m_end), .line0(m_l0), .line1(m_l1), .two(m_two), .off(m_off));
    wire m_oob_unused;
    ad_vf_fetch_limit u_lim (.end49(m_end), .limit(a_lim), .oob(m_oob_unused));
    assign m_oob = fv_oob;
`else
    ad_vf_fetch_addr #(.ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) u_addr (.base(a_base), .stride(a_desc[`AD_DESC_STRIDE]),
        .elem(elem_r), .size(f_size), .addr(m_addr), .end49(m_end), .line0(m_l0), .line1(m_l1), .two(m_two), .off(m_off));
    ad_vf_fetch_limit u_lim (.end49(m_end), .limit(a_lim), .oob(m_oob));
`endif

    // ---------------------------------------------------------------- line buffers
    wire [1:0]  s = k[1:0];
    wire        clr = af_valid && af_ready && af_last;
    wire [3:0]  sh0, sh1, srv0, srv1;
    wire [11:0] she0, she1, sae0, sae1;
    wire [4*LB-1:0] srd0, srd1;
    wire [31:0] lb_valid, lb_pend;
    wire [32*LW-1:0] lb_tags;
    wire        rsp_rd = rsp_valid && !rsp_write;
    // the selected stream's lookup, allocation and read results
    reg         h0, h1, rv0s, rv1s;
    reg  [2:0]  he0, he1, ae0, ae1;
    reg  [LB-1:0] lo, hi;
    integer si;
    always @(*) begin
        h0 = 1'b0; h1 = 1'b0; rv0s = 1'b0; rv1s = 1'b0; he0 = 3'd0; he1 = 3'd0; ae0 = 3'd0; ae1 = 3'd0;
        lo = {LB{1'b0}}; hi = {LB{1'b0}};
        for (si = 0; si < 4; si = si + 1) if (s == si) begin
            h0 = sh0[si]; h1 = sh1[si]; rv0s = srv0[si]; rv1s = srv1[si];
            he0 = she0[3*si +: 3]; he1 = she1[3*si +: 3]; ae0 = sae0[3*si +: 3]; ae1 = sae1[3*si +: 3];
            lo = srd0[LB*si +: LB]; hi = srd1[LB*si +: LB];
        end
    end
    wire        plan_rd = (state == S_PLAN) && !oob_r;
    wire        miss0 = plan_rd && !h0;
    wire        miss1 = plan_rd && two_r && !h1;

    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : g_s
        ad_vf_fetch_lbuf #(.LW(LW), .LINE_BYTES(LINE_BYTES)) u_lb (.clk(clk), .rst_n(rst_n), .clr(clr),
            .l0(line0_r), .l1(line1_r), .two(two_r),
            .h0(sh0[g]), .he0(she0[3*g +: 3]), .h1(sh1[g]), .he1(she1[3*g +: 3]),
            .a_en0(miss0 && s == g), .a_en1(miss1 && s == g), .ae0(sae0[3*g +: 3]), .ae1(sae1[3*g +: 3]),
            .w_en(rsp_rd && rsp_tag[4:3] == g), .w_ent(rsp_tag[2:0]), .w_data(rsp_rdata), .w_err(rsp_error),
            .r_e0(e0_r), .r_e1(e1_r), .rd0(srd0[LB*g +: LB]), .rd1(srd1[LB*g +: LB]), .rv0(srv0[g]), .rv1(srv1[g]),
            .o_valid(lb_valid[8*g +: 8]), .o_pend(lb_pend[8*g +: 8]), .o_tags(lb_tags[8*LW*g +: 8*LW]));
    end endgenerate

    wire data_ok = !rq0 && !rq1 && rv0s && (!two_r || rv1s);

    // ---------------------------------------------------------------- AMB requests
    assign req_valid = (state == S_WAIT) && (rq0 || rq1);
    assign req_write = 1'b0;
    assign req_line  = rq0 ? line0_r : line1_r;
    assign req_be    = {LINE_BYTES{1'b0}};
    assign req_wdata = {LB{1'b0}};
    assign req_tag   = {3'b000, s, rq0 ? e0_r : e1_r};
    wire   req_fire  = req_valid && req_ready;

    // ---------------------------------------------------------------- af
    wire [127:0]  ex_raw;
    ad_vf_fetch_extract #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) u_ex (.lo(lo), .hi(hi),
        .off(addr_r[LINE_SHIFT-1:0]), .raw(ex_raw));
    assign af_valid = (state == S_EMIT) || (state == S_NONE);
    assign af_attr  = (state == S_NONE) ? 4'd0 : k;
    assign af_lane  = v_lane;
    assign af_raw   = (state == S_EMIT && !oob_r) ? ex_raw : 128'd0;
    assign af_oob   = (state == S_EMIT) && oob_r;
    assign af_last  = (state == S_NONE) || (state == S_EMIT && v_last && !has_next);
    assign vb_ready = (state == S_IDLE);
    assign busy     = (state != S_IDLE);

    // ---------------------------------------------------------------- FSM
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; k <= 4'd0; v_index <= 32'd0; v_inst <= 32'd0; v_lane <= 5'd0; v_last <= 1'b0;
            elem_r <= 32'd0; addr_r <= 32'd0; line0_r <= {LW{1'b0}}; line1_r <= {LW{1'b0}};
            two_r <= 1'b0; oob_r <= 1'b0; e0_r <= 3'd0; e1_r <= 3'd0; rq0 <= 1'b0; rq1 <= 1'b0;
        end else begin
            case (state)
                S_IDLE: if (vb_valid) begin
                    v_index <= vb_index; v_inst <= vb_inst; v_lane <= vb_lane; v_last <= vb_last;
                    k <= first_k;
                    if (any_en)       state <= S_ELEM;
                    else if (vb_last) state <= S_NONE;
                end
                S_ELEM: begin
                    elem_r <= elem_now;
                    state  <= need_div ? S_DIV : S_MUL;
                end
                S_DIV: if (div_done) begin
                    elem_r <= first_inst + div_q;
                    state  <= S_MUL;
                end
                S_MUL: begin
                    addr_r <= m_addr; line0_r <= m_l0; line1_r <= m_l1; two_r <= m_two; oob_r <= m_oob;
                    state  <= S_PLAN;
                end
                S_PLAN: begin
                    e0_r <= h0 ? he0 : ae0;
                    e1_r <= h1 ? he1 : ae1;
                    rq0  <= miss0;
                    rq1  <= miss1;
                    state <= (miss0 || miss1) ? S_WAIT : S_EMIT;
                end
                S_WAIT: begin
                    if (req_fire) begin
                        if (rq0) rq0 <= 1'b0; else rq1 <= 1'b0;
                    end
                    if (data_ok) state <= S_EMIT;
                end
                S_EMIT: if (af_ready) begin
                    if (has_next) begin k <= next_k; state <= S_ELEM; end
                    else state <= S_IDLE;
                end
                S_NONE: if (af_ready) state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef AD_FV_FETCH
    assign fv_state = state; assign fv_k = k; assign fv_valid = lb_valid; assign fv_pend = lb_pend;
    assign fv_tags = lb_tags; assign fv_rq0 = rq0; assign fv_rq1 = rq1; assign fv_e0 = e0_r; assign fv_e1 = e1_r;
    assign fv_two = two_r; assign fv_vlast = v_last; assign fv_div_busy = div_busy;
`endif
endmodule
