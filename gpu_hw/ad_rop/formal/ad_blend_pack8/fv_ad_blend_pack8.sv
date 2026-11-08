// ad_blend_pack8: pack(unpack(p)) == p for R5G6B5 / A1R5G5B5 (and every 8-bit format) on the
// pixel's bits; 5/6-bit fields = round(v*31/255), round(v*63/255); A1 = (a >= 128);
// never writes outside the pixel or for a format outside the list; keep follows the write mask.
`include "ad_rop_state.vh"
module fv_ad_blend_pack8;
    (* anyconst *) reg [31:0] p;
    (* anyconst *) reg [7:0]  fmt, r, g, b, a;
    (* anyconst *) reg [3:0]  wm;
    wire [7:0] ur, ug, ub, ua; wire ok;
    wire [31:0] bits, keep, bits2, keep2;
    ad_blend_unpack8 u_up (.lane(p), .fmt(fmt), .r(ur), .g(ug), .b(ub), .a(ua), .ok(ok));
    ad_blend_pack8   u_pk (.r(ur), .g(ug), .b(ub), .a(ua), .fmt(fmt), .wm(4'hF), .bits(bits), .keep(keep));
    ad_blend_pack8   u_p2 (.r(r), .g(g), .b(b), .a(a), .fmt(fmt), .wm(wm), .bits(bits2), .keep(keep2));
    wire [31:0] pixm = (fmt == 8'd37 || fmt == 8'd51 || fmt == 8'd44) ? 32'hFFFFFFFF :
                       (fmt == 8'd9) ? 32'h000000FF :
                       (fmt == 8'd16 || fmt == 8'd4 || fmt == 8'd8) ? 32'h0000FFFF : 32'h0;
    wire [15:0] r31 = (r * 16'd31 + 16'd127) / 16'd255;
    wire [15:0] g63 = (g * 16'd63 + 16'd127) / 16'd255;
    wire [15:0] g31 = (g * 16'd31 + 16'd127) / 16'd255;
    wire [15:0] b31 = (b * 16'd31 + 16'd127) / 16'd255;
    always @(*) begin
        a_rt:     assert (bits == (p & pixm));            // pack(unpack(p)) == p on the pixel bits
        a_full:   assert (keep == ~pixm);                  // full write mask writes the whole pixel
        a_inside: assert ((bits2 & ~pixm) == 32'd0 && (~keep2 & ~pixm) == 32'd0);
        if (wm == 4'd0) a_wm0: assert (keep2 == 32'hFFFFFFFF);
        if (fmt == 8'd4) a_565: assert (bits2[15:11] == r31[4:0] && bits2[10:5] == g63[5:0] && bits2[4:0] == b31[4:0]);
        if (fmt == 8'd8) a_1555: assert (bits2[15] == (a >= 8'd128) && bits2[14:10] == r31[4:0] &&
                                         bits2[9:5] == g31[4:0] && bits2[4:0] == b31[4:0]);
        // channel write mask: R bit of wm controls exactly the R field
        if (fmt == 8'd37) a_wm37: assert (~keep2 == {{8{wm[3]}}, {8{wm[2]}}, {8{wm[1]}}, {8{wm[0]}}});
        if (fmt == 8'd44) a_wm44: assert (~keep2 == {{8{wm[3]}}, {8{wm[0]}}, {8{wm[1]}}, {8{wm[2]}}});
        if (fmt == 8'd4)  a_wm4:  assert (~keep2 == {16'd0, {5{wm[0]}}, {6{wm[1]}}, {5{wm[2]}}});
        if (fmt == 8'd8)  a_wm8:  assert (~keep2 == {16'd0, wm[3], {5{wm[0]}}, {5{wm[1]}}, {5{wm[2]}}});
    end
endmodule
