// ad_blend_state: the selected state of attachment rt equals the one derived from a raw mirror
// of the STATE words (written independently here): BLEND/BLEND1-3 [26:0], format (RT_FORMATS
// byte, or RT_FORMAT's legacy code for RT0 when the byte is 0), write mask nibble, logic op
// enable (ROP_CTRL[2] | LOGIC_OP[8k]) and op, the constant (BLEND_CONST bytes, or with
// ROP_CTRL[1] the fp32 words converted by the generic ad_f2unorm #(8) when written), ROP_CTRL[7].
// Free inputs every cycle (module ports); reset in the first cycle and whenever rst_n = 0.
`include "ad_rop_state.vh"
module fv_ad_blend_state (
    input wire        clk,
    input wire        rst_n,
    input wire        st_we,
    input wire [8:0]  st_idx,
    input wire [31:0] st_wdata,
    input wire [1:0]  rt
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);

    wire [26:0] blend; wire [7:0] fmt; wire [3:0] wmask, lop_op; wire lop_en, dual; wire [31:0] kconst;
    ad_blend_state dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .rt(rt), .blend(blend), .fmt(fmt), .wmask(wmask), .lop_en(lop_en), .lop_op(lop_op),
        .kconst(kconst), .dual(dual));

    // raw mirror (the fp constants are stored converted: one converter on st_wdata)
    reg [31:0] m_bl [0:3];
    reg [31:0] m_bc, m_wm, m_rtf, m_rtfmt, m_ropc, m_lop;
    reg [7:0]  m_kf [0:3];
    wire [7:0] cv;
    ad_f2unorm #(.N(8)) u_cv (.f(st_wdata), .u(cv));
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin m_bl[i] <= 32'd0; m_kf[i] <= 8'd0; end
            m_bc <= 0; m_wm <= 0; m_rtf <= 0; m_rtfmt <= 0; m_ropc <= 0; m_lop <= 0;
        end else if (st_we) begin
            if (st_idx == 9'h07A) m_bl[0] <= st_wdata;
            if (st_idx == 9'h084) m_bl[1] <= st_wdata;
            if (st_idx == 9'h085) m_bl[2] <= st_wdata;
            if (st_idx == 9'h086) m_bl[3] <= st_wdata;
            if (st_idx == 9'h07B) m_bc <= st_wdata;
            if (st_idx == 9'h07C) m_wm <= st_wdata;
            if (st_idx == 9'h07D) m_rtf <= st_wdata;
            if (st_idx == 9'h072) m_rtfmt <= st_wdata;
            if (st_idx == 9'h08D) m_ropc <= st_wdata;
            if (st_idx == 9'h08E) m_lop <= st_wdata;
            if (st_idx >= 9'h087 && st_idx <= 9'h08A) m_kf[st_idx - 9'h087] <= cv;
        end
    end
    wire [7:0] byte_f = m_rtf >> (8 * rt);
    wire [7:0] leg    = (m_rtfmt == 0) ? 8'd44 : (m_rtfmt == 1) ? 8'd37 :
                        (m_rtfmt == 2 || m_rtfmt == 3) ? 8'd4 : 8'd0;
    wire [7:0] e_fmt  = (rt == 2'd0 && byte_f == 8'd0) ? leg : byte_f;
    wire [7:0] lb     = m_lop >> (8 * rt);
    wire [31:0] e_k   = m_ropc[1] ? {m_kf[3], m_kf[2], m_kf[1], m_kf[0]} : m_bc;
    wire [3:0] e_wm   = m_wm >> (4 * rt);
    always @(*) begin
        if (!init) begin
            a_blend: assert (blend == m_bl[rt][26:0]);
            a_fmt:   assert (fmt == e_fmt);
            a_wm:    assert (wmask == e_wm);
            a_lopen: assert (lop_en == (m_ropc[2] | lb[0]));
            a_lop:   assert (lop_op == lb[4:1]);
            a_k:     assert (kconst == e_k);
            a_dual:  assert (dual == m_ropc[7]);
        end
    end
endmodule
