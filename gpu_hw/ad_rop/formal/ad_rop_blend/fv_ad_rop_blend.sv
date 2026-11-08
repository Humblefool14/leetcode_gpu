// fv_ad_rop_blend -- the whole ad_rop_blend (state + 4-lane pipeline), free inputs every cycle.
// a_lat:  b_rvalid == b_valid delayed by exactly 3 cycles (a reset in any of them clears it)
// a_mask: lanes with b_mask = 0 return b_dst exactly
// a_dis:  blend disabled, no logic op, RGBA8, full write mask -> pix = f2u8(src) per channel
// a_wm0:  write mask 0 -> pix = b_dst;  a_bad: format outside the list -> pix = b_dst
// a_copy: logic op COPY, full write mask -> pix = pack(f2u8(src)) on the pixel bits, b_dst above
// The beat's state comes from a raw mirror of the STATE words kept here.
`include "ad_rop_state.vh"
module fv_ad_rop_blend (
    input wire         clk,
    input wire         rst_n,
    input wire         st_we,
    input wire [8:0]   st_idx,
    input wire [31:0]  st_wdata,
    input wire         b_valid,
    input wire [511:0] b_src,
    input wire [511:0] b_src1,
    input wire         b_has_src1,
    input wire [127:0] b_dst,
    input wire [3:0]   b_mask,
    input wire [1:0]   b_rt
);
    localparam NL = 4;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);
    wire b_rvalid; wire [127:0] b_pix;
    ad_rop_blend dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .b_valid(b_valid), .b_src(b_src), .b_src1(b_src1), .b_has_src1(b_has_src1), .b_dst(b_dst),
        .b_mask(b_mask), .b_rt(b_rt), .b_rvalid(b_rvalid), .b_pix(b_pix));

    reg [31:0] m_bl [0:3];
    reg [31:0] m_wm, m_rtf, m_rtfmt, m_ropc, m_lop;
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) m_bl[i] <= 32'd0;
            m_wm <= 0; m_rtf <= 0; m_rtfmt <= 0; m_ropc <= 0; m_lop <= 0;
        end else if (st_we) begin
            if (st_idx == 9'h07A) m_bl[0] <= st_wdata;
            if (st_idx == 9'h084) m_bl[1] <= st_wdata;
            if (st_idx == 9'h085) m_bl[2] <= st_wdata;
            if (st_idx == 9'h086) m_bl[3] <= st_wdata;
            if (st_idx == 9'h07C) m_wm <= st_wdata;
            if (st_idx == 9'h07D) m_rtf <= st_wdata;
            if (st_idx == 9'h072) m_rtfmt <= st_wdata;
            if (st_idx == 9'h08D) m_ropc <= st_wdata;
            if (st_idx == 9'h08E) m_lop <= st_wdata;
        end
    end
    wire [7:0]  byte_f  = m_rtf >> (8 * b_rt);
    wire [7:0]  leg     = (m_rtfmt == 0) ? 8'd44 : (m_rtfmt == 1) ? 8'd37 :
                          (m_rtfmt == 2 || m_rtfmt == 3) ? 8'd4 : 8'd0;
    wire [7:0]  lb      = m_lop >> (8 * b_rt);
    wire [31:0] c_blend = m_bl[b_rt];
    wire [7:0]  c_fmt   = (b_rt == 2'd0 && byte_f == 8'd0) ? leg : byte_f;
    wire [3:0]  c_wm    = m_wm >> (4 * b_rt);
    wire        c_lo    = m_ropc[2] | lb[0];
    wire [3:0]  c_lop   = lb[4:1];
`include "fv_props.vh"
endmodule
