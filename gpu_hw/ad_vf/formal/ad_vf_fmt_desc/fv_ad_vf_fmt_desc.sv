// fv_ad_vf_fmt_desc -- ad_vf_fmt_desc equals the table generated from tools/fmtmodel.py
// (fmt_desc_ref.vh, written by tools/gen_conv_vectors.py) for every VkFormat 0..255 and every legacy
// code: ncomp and kind always, field width and swizzle where the format has data components.
module fv_ad_vf_fmt_desc (
    input wire clk
);
`include "fmt_desc_ref.vh"
    (* anyconst *) reg [7:0] vkfmt;
    (* anyconst *) reg [3:0] legacy;
    wire [2:0] ncomp, kind; wire [1:0] bw; wire bgra;
    ad_vf_fmt_desc dut (.vkfmt(vkfmt), .legacy(legacy), .ncomp(ncomp), .kind(kind), .bw(bw), .bgra(bgra));
    wire [8:0] r = fmt_desc_ref(vkfmt, legacy);
    always @(*) begin
        a_ncomp: assert (ncomp == r[8:6]);
        a_kind:  assert (kind == r[5:3]);
        if (r[8:6] != 3'd0) begin
            a_bw:   assert (bw == r[2:1]);
            a_bgra: assert (bgra == r[0]);
        end
    end
endmodule
