// fv_ad_su_dcache -- formal harness of ad_su_dcache, reduced: ADDR_W 6,
// 4-byte lines (16 lines of memory), DC_BYTES 8 (2 cache lines).
// Reset in the first cycle only.  Upstream: a legal client (payload held
// until ready).  Downstream: formal/common/ad_amb_client_props.sv (the D$'s
// request held until ready; responses only for outstanding requests) and a
// memory model for one symbolic line S (anyconst): its value mem_s (free
// initial value) is written by an MC write of S answered without error, and
// a read of S answered without error returns mem_s; other lines return any data.
// Properties: (integrity) a read of S answered without error returns mem_s;
// (no hit after inv) a read taken while no fill has been kept since the last
// inv makes an MC request before it is answered; one upstream response per
// request, at most one MC request outstanding.
module fv_ad_su_dcache (
    input wire clk,
    input wire rst_n,
    input wire inv,
    input wire u_req_valid, input wire u_req_write, input wire [3:0] u_req_line,
    input wire [3:0] u_req_be, input wire [31:0] u_req_wdata, input wire [7:0] u_req_tag,
    input wire m_req_ready, input wire m_rsp_valid, input wire m_rsp_write, input wire [7:0] m_rsp_tag,
    input wire [31:0] m_rsp_rdata, input wire m_rsp_error
);
    localparam AW = 6, LB = 4, LS = 2, LW = 4;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) begin
        if (init) assume (!rst_n);
        else assume (rst_n);
    end

    wire u_req_ready, u_rsp_valid, u_rsp_write, u_rsp_error;
    wire [7:0] u_rsp_tag; wire [31:0] u_rsp_rdata;
    wire m_req_valid, m_req_write; wire [LW-1:0] m_req_line; wire [LB-1:0] m_req_be;
    wire [31:0] m_req_wdata; wire [7:0] m_req_tag;
    wire [2:0] fv_st; wire fv_drop; wire [1:0] fv_vld; wire [31:0] fv_rdl, fv_data; wire [LW-1:0] fv_tag;
    (* anyconst *) reg [LW-1:0] S;
    ad_su_dcache #(.ADDR_W(AW), .LINE_BYTES(LB), .LINE_SHIFT(LS), .DC_BYTES(8)) dut (
        .clk(clk), .rst_n(rst_n), .inv(inv),
        .u_req_valid(u_req_valid), .u_req_ready(u_req_ready), .u_req_write(u_req_write),
        .u_req_line(u_req_line), .u_req_be(u_req_be), .u_req_wdata(u_req_wdata), .u_req_tag(u_req_tag),
        .u_rsp_valid(u_rsp_valid), .u_rsp_write(u_rsp_write), .u_rsp_tag(u_rsp_tag),
        .u_rsp_rdata(u_rsp_rdata), .u_rsp_error(u_rsp_error),
        .m_req_valid(m_req_valid), .m_req_ready(m_req_ready), .m_req_write(m_req_write),
        .m_req_line(m_req_line), .m_req_be(m_req_be), .m_req_wdata(m_req_wdata), .m_req_tag(m_req_tag),
        .m_rsp_valid(m_rsp_valid), .m_rsp_write(m_rsp_write), .m_rsp_tag(m_rsp_tag),
        .m_rsp_rdata(m_rsp_rdata), .m_rsp_error(m_rsp_error),
        .fv_st(fv_st), .fv_drop(fv_drop), .fv_vld(fv_vld), .fv_rdl(fv_rdl), .fv_idx(S[0]), .fv_data(fv_data), .fv_tag(fv_tag));

    wire [2:0] m_out;
    ad_amb_client_props #(.LINE_BYTES(LB), .LINE_W(LW), .CNT_W(3)) amb (
        .clk(clk), .rst_n(rst_n), .req_valid(m_req_valid), .req_ready(m_req_ready),
        .req_write(m_req_write), .req_line(m_req_line), .req_be(m_req_be), .req_wdata(m_req_wdata),
        .req_tag(m_req_tag), .rsp_valid(m_rsp_valid), .outstanding(m_out));

    // upstream client: payload held until ready
    reg past_ok = 1'b0;
    reg pu_v, pu_r, pu_w; reg [3:0] pu_l, pu_be; reg [31:0] pu_d; reg [7:0] pu_t;
    always @(posedge clk) begin
        past_ok <= rst_n;
        pu_v <= u_req_valid; pu_r <= u_req_ready; pu_w <= u_req_write; pu_l <= u_req_line;
        pu_be <= u_req_be; pu_d <= u_req_wdata; pu_t <= u_req_tag;
    end
    always @(*) if (past_ok && rst_n && pu_v && !pu_r)
        assume (u_req_valid && u_req_write == pu_w && u_req_line == pu_l && u_req_be == pu_be &&
                u_req_wdata == pu_d && u_req_tag == pu_t);

    // symbolic line and its memory
    (* anyconst *) reg [31:0]   mem_init;
    reg [31:0] mem_s;
    reg mo_w, minv; reg [LW-1:0] mo_l; reg [3:0] mo_be; reg [31:0] mo_d;
    reg [31:0] merged;
    integer b;
    always @(*) for (b = 0; b < 4; b = b + 1) merged[8*b +: 8] = mo_be[b] ? mo_d[8*b +: 8] : mem_s[8*b +: 8];
    always @(posedge clk) begin
        if (!rst_n) begin mem_s <= mem_init; minv <= 1'b0; end
        else begin
            if (inv) minv <= 1'b1;
            if (m_req_valid && m_req_ready) begin
                mo_w <= m_req_write; mo_l <= m_req_line; mo_be <= m_req_be; mo_d <= m_req_wdata; minv <= inv;
            end
            if (m_rsp_valid && mo_w && !m_rsp_error && mo_l == S) mem_s <= merged;
        end
    end
    always @(*) if (rst_n && m_rsp_valid && !mo_w && mo_l == S && !m_rsp_error) assume (m_rsp_rdata == mem_s);

    // upstream bookkeeping
    reg [2:0] u_out;
    reg uo_w, rec_clean, saw_m, since_inv; reg [3:0] uo_l;
    wire u_take = u_req_valid && u_req_ready;
    always @(posedge clk) begin
        if (!rst_n) begin u_out <= 3'd0; since_inv <= 1'b1; saw_m <= 1'b0; rec_clean <= 1'b0; end
        else begin
            u_out <= u_out + u_take - u_rsp_valid;
            if (u_take) begin uo_w <= u_req_write; uo_l <= u_req_line; rec_clean <= since_inv || inv; saw_m <= 1'b0; end
            if (m_req_valid && m_req_ready) saw_m <= 1'b1;
            if (inv) since_inv <= 1'b1;
            else if (m_rsp_valid && !mo_w && !m_rsp_error && !minv) since_inv <= 1'b0;
        end
    end
    always @(*) if (rst_n && !init) begin
        a_one_rsp:  assert (!u_rsp_valid || u_out == 3'd1);
        a_u_out:    assert (u_out <= 3'd1);
        a_m_out:    assert (m_out <= 3'd1);
        if (u_rsp_valid && !uo_w && uo_l == S && !u_rsp_error) a_data: assert (u_rsp_rdata == mem_s);
        if (u_rsp_valid && !uo_w && rec_clean) a_noinvhit: assert (saw_m);
        if (u_rsp_valid) a_wflag: assert (u_rsp_write == uo_w);
        // helper invariants (k-induction); states 0 idle 1 hit 2 mreq 3 mwait
        h_st:    assert (fv_st <= 3'd3);
        h_uout:  assert ((u_out == 3'd1) == (fv_st != 3'd0));
        h_mout:  assert ((m_out == 3'd1) == (fv_st == 3'd3));
        if (fv_st != 3'd0) h_uo: assert (uo_l == m_req_line && uo_w == m_req_write);
        if (fv_st == 3'd3) h_mo: assert (mo_l == m_req_line && mo_w == m_req_write &&
                                         (!mo_w || (mo_be == m_req_be && mo_d == m_req_wdata)));
        if (fv_vld[S[0]] && fv_tag[2:0] == S[3:1]) h_line: assert (fv_data == mem_s);
        if (fv_st != 3'd0 && m_req_line == S) h_rdl: assert (fv_rdl == fv_data);
        if (fv_st == 3'd1 && m_req_line == S) h_hit: assert (fv_rdl == mem_s);
        if (since_inv) h_inv: assert (fv_vld == 2'b00);
        if (fv_st == 3'd1) h_hitc: assert (!rec_clean);
        if (fv_st == 3'd3) h_sawm: assert (saw_m);
        if (fv_st == 3'd3 && minv) h_drop: assert (fv_drop);
    end
endmodule
