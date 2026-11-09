// fv_ad_vf_fmt_comp -- ad_vf_fmt_comp against a reference written another way: the descriptor
// comes from the fmtmodel table (fmt_desc_ref.vh) for an arbitrary VkFormat / legacy code; the
// field is extracted by shifting the 128-bit raw word (not part-selects), swizzled by a case,
// converted by separate instances of the (separately proven) converter leaves, and the fill
// (0, 0, 0, 1 / 1.0) is applied for i >= ncomp or oob.  Inputs: anyconst raw, format, oob, i.
module fv_ad_vf_fmt_comp (
    input wire clk
);
`include "fmt_desc_ref.vh"
    (* anyconst *) reg [7:0]   vkfmt;
    (* anyconst *) reg [3:0]   legacy;
    (* anyconst *) reg [127:0] raw;
    (* anyconst *) reg         oob;
    (* anyconst *) reg [1:0]   i;

    wire [8:0] r = fmt_desc_ref(vkfmt, legacy);
    wire [2:0] n = r[8:6], kind = r[5:3]; wire [1:0] bw = r[2:1]; wire bgra = r[0];
    wire [31:0] word;
    ad_vf_fmt_comp dut (.raw(raw), .ncomp(n), .kind(kind), .bw(bw), .bgra(bgra), .oob(oob), .i(i), .word(word));

    reg [1:0] j;
    always @(*) case ({bgra, i})
        3'b100: j = 2'd2;
        3'b110: j = 2'd0;
        default: j = i;
    endcase
    wire [127:0] s8  = raw >> ({5'd0, j} * 7'd8);
    wire [127:0] s16 = raw >> ({5'd0, j} * 7'd16);
    wire [127:0] s32 = raw >> ({5'd0, j} * 7'd32);
    wire [31:0]  sp  = raw[31:0] >> ({3'd0, i} * 5'd10);
    wire [7:0]  x8  = s8[7:0];
    wire [15:0] x16 = s16[15:0];
    wire [31:0] x32 = s32[31:0];
    wire [9:0]  x10 = sp[9:0];
    wire [1:0]  x2  = sp[1:0];
    wire [31:0] h, u8, u16, u10, u2, n8, n16;
    ad_vf_fmt_h2f             r_h   (.h(x16), .f(h));
    ad_vf_fmt_unorm #(.N(8))  r_u8  (.c(x8),  .f(u8));
    ad_vf_fmt_unorm #(.N(16)) r_u16 (.c(x16), .f(u16));
    ad_vf_fmt_unorm #(.N(10)) r_u10 (.c(x10), .f(u10));
    ad_vf_fmt_unorm #(.N(2))  r_u2  (.c(x2),  .f(u2));
    ad_vf_fmt_snorm #(.N(8))  r_n8  (.c(x8),  .f(n8));
    ad_vf_fmt_snorm #(.N(16)) r_n16 (.c(x16), .f(n16));

    reg [31:0] ref_w; reg legal;
    always @(*) begin
        ref_w = 32'd0; legal = 1'b1;
        if (oob || i >= n) ref_w = (i != 2'd3) ? 32'd0 : (kind == 3'd3 || kind == 3'd4) ? 32'd1 : 32'h3F80_0000;
        else case ({kind, bw})
            {3'd0, 2'd1}: ref_w = h;                          // SFLOAT16
            {3'd0, 2'd2}: ref_w = x32;                        // SFLOAT32
            {3'd1, 2'd0}: ref_w = u8;
            {3'd1, 2'd1}: ref_w = u16;
            {3'd1, 2'd3}: ref_w = (i == 2'd3) ? u2 : u10;      // A2B10G10R10
            {3'd2, 2'd0}: ref_w = n8;
            {3'd2, 2'd1}: ref_w = n16;
            {3'd3, 2'd0}: ref_w = x8;
            {3'd3, 2'd1}: ref_w = x16;
            {3'd3, 2'd2}: ref_w = x32;
            {3'd4, 2'd0}: ref_w = $signed(x8);
            {3'd4, 2'd1}: ref_w = $signed(x16);
            {3'd4, 2'd2}: ref_w = x32;
            default: legal = 1'b0;
        endcase
    end
    always @(*) begin
        a_legal: assert (legal);              // the table has no other {kind, width}
        a_word:  assert (word == ref_w);
    end
endmodule
