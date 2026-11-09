// fv_ad_vf_fetch_extract -- byte extraction against a per-byte reference: raw byte i is
// lo[off + i] when off + i < LINE_BYTES, else hi[off + i - LINE_BYTES] (i = 0..15).
// Combinational: lo, hi, off anyconst.  LBY 32 (LS 5) or 64 (LS 6).
module fv_ad_vf_fetch_extract #(parameter LBY = 32, parameter LS = 5) (input wire clk);
    (* anyconst *) reg [LBY*8-1:0] lo;
    (* anyconst *) reg [LBY*8-1:0] hi;
    (* anyconst *) reg [LS-1:0]    off;
    wire [127:0] raw;
    ad_vf_fetch_extract #(.LINE_BYTES(LBY), .LINE_SHIFT(LS)) dut (.lo(lo), .hi(hi), .off(off), .raw(raw));
    genvar i;
    generate for (i = 0; i < 16; i = i + 1) begin : g_b
        wire [LS:0] p = {1'b0, off} + i;
        wire [7:0]  r = (p < LBY) ? lo[8*p[LS-1:0] +: 8] : hi[8*p[LS-1:0] +: 8];
        always @(*) assert (raw[8*i +: 8] == r);
    end endgenerate
endmodule
