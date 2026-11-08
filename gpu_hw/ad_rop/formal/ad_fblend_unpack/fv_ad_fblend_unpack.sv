// ad_fblend_unpack bit placement: for every format each channel is the decode of
// exactly its field (reference decoders on the expected slices), missing channels
// read G = B = 0.0 and A = 1.0, unsupported formats read 0 with supported = 0,
// and fixed / supported flag the right formats.
module fv_ad_fblend_unpack;
    (* anyconst *) reg [63:0] raw;
    (* anyconst *) reg [7:0]  fmt;
    wire [127:0] d; wire fixed, supported;
    ad_fblend_unpack u (.raw(raw), .fmt(fmt), .d(d), .fixed(fixed), .supported(supported));
    wire [31:0] R = d[31:0], G = d[63:32], B = d[95:64], A = d[127:96];
    // reference decoders on fixed slices
    wire [31:0] l0, l1, l2, a8, u0, u1, u2, a2, h0, h1, h2, h3;
    ad_fblend_srgb_lut r_l0 (.c(raw[7:0]),   .f(l0));
    ad_fblend_srgb_lut r_l1 (.c(raw[15:8]),  .f(l1));
    ad_fblend_srgb_lut r_l2 (.c(raw[23:16]), .f(l2));
    ad_unorm2f #(.N(8))  r_a8 (.x(raw[31:24]), .f(a8));
    ad_unorm2f #(.N(10)) r_u0 (.x(raw[9:0]),   .f(u0));
    ad_unorm2f #(.N(10)) r_u1 (.x(raw[19:10]), .f(u1));
    ad_unorm2f #(.N(10)) r_u2 (.x(raw[29:20]), .f(u2));
    ad_unorm2f #(.N(2))  r_a2 (.x(raw[31:30]), .f(a2));
    ad_fblend_h2f r_h0 (.h(raw[15:0]),  .f(h0));
    ad_fblend_h2f r_h1 (.h(raw[31:16]), .f(h1));
    ad_fblend_h2f r_h2 (.h(raw[47:32]), .f(h2));
    ad_fblend_h2f r_h3 (.h(raw[63:48]), .f(h3));
    localparam [31:0] ONE = 32'h3F80_0000;
    wire sup = (fmt == 43) || (fmt == 50) || (fmt == 57) || (fmt == 64) || (fmt == 76) || (fmt == 83) || (fmt == 97);
    always @(*) begin
        a_sup:   assert (supported == sup);
        a_fixed: assert (fixed == ((fmt == 43) || (fmt == 50) || (fmt == 57) || (fmt == 64)));
        if (fmt == 43 || fmt == 57) a_rgba8: assert (R == l0 && G == l1 && B == l2 && A == a8);
        if (fmt == 50)              a_bgra8: assert (R == l2 && G == l1 && B == l0 && A == a8);
        if (fmt == 64)              a_a2b10: assert (R == u0 && G == u1 && B == u2 && A == a2);
        if (fmt == 76)              a_r16:   assert (R == h0 && G == 0 && B == 0 && A == ONE);
        if (fmt == 83)              a_rg16:  assert (R == h0 && G == h1 && B == 0 && A == ONE);
        if (fmt == 97)              a_rgba16: assert (R == h0 && G == h1 && B == h2 && A == h3);
        if (!sup)                   a_unsup: assert (d == 128'd0);
    end
endmodule
