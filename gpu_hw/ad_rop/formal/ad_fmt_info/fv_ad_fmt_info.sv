// fv_ad_fmt_info -- the format table's consistency: ps in {1,2,4,8,16} exactly when
// supported, ps = 2^lps, path 3 exactly when unsupported, a channel exactly when supported,
// blendable = path 0 or 1, the 24 path-2 formats (independent list) on path 2.
module fv_ad_fmt_info (input wire clk);
    (* anyconst *) reg [7:0] fmt;
    wire sup, bl; wire [4:0] ps; wire [2:0] lps; wire [1:0] path; wire [3:0] chm;
    ad_fmt_info dut (.i_fmt(fmt), .o_sup(sup), .o_ps(ps), .o_lps(lps), .o_path(path), .o_chm(chm), .o_blendable(bl));
    wire is_p2 = (fmt == 13) || (fmt == 14) || (fmt == 20) || (fmt == 21) || (fmt == 41) || (fmt == 42) ||
                 (fmt == 55) || (fmt == 56) || (fmt == 68) || (fmt == 74) || (fmt == 75) || (fmt == 81) ||
                 (fmt == 82) || (fmt == 95) || (fmt == 96) || (fmt == 98) || (fmt == 99) || (fmt == 100) ||
                 (fmt == 101) || (fmt == 102) || (fmt == 103) || (fmt == 107) || (fmt == 108) || (fmt == 109);
    wire is_p01 = (fmt == 37) || (fmt == 44) || (fmt == 51) || (fmt == 4) || (fmt == 8) || (fmt == 9) || (fmt == 16) ||
                  (fmt == 43) || (fmt == 50) || (fmt == 57) || (fmt == 64) || (fmt == 76) || (fmt == 83) || (fmt == 97);
    always @(*) begin
        a_ps:    assert (sup ? (ps == 1 || ps == 2 || ps == 4 || ps == 8 || ps == 16) : (ps == 0));
        a_lps:   assert (!sup || ps == (5'd1 << lps));
        a_path:  assert (sup == (path != 2'd3));
        a_chm:   assert (sup == (chm != 4'd0));
        a_bl:    assert (bl == (path == 2'd0 || path == 2'd1));
        a_p2:    assert (is_p2 == (path == 2'd2));
        a_sup:   assert (sup == (is_p2 || is_p01));
        a_r:     assert (!sup || chm[0]);                 // every format has R
        a_p16:   assert (!(ps == 16) || path == 2'd2);    // 16-byte pixels: R32G32B32A32 only
    end
endmodule
