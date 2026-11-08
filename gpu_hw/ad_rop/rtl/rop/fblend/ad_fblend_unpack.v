// ad_fblend_unpack -- one stored 64-bit pixel lane to 4 x fp32 linear (R, G, B, A
// at d[32c +: 32]).  sRGB R, G, B via the EOTF LUT (ad_fblend_srgb_lut), sRGB
// alpha unorm2f(8), A2B10G10R10 unorm2f(10)/(2), fp16 exact (ad_fblend_h2f).
// Missing channels: G, B read 0.0, A reads 1.0.  Unsupported formats read 0 and
// supported = 0.  fixed = 1 for the fixed-point formats (sRGB, UNORM10).
// Combinational.
module ad_fblend_unpack (
    input  wire [63:0]  raw,
    input  wire [7:0]   fmt,
    output reg  [127:0] d,
    output wire         fixed,
    output wire         supported
);
    localparam [7:0] F43 = 8'd43, F50 = 8'd50, F57 = 8'd57, F64 = 8'd64,
                     F76 = 8'd76, F83 = 8'd83, F97 = 8'd97;
    localparam [31:0] ONE = 32'h3F80_0000;
    wire srgb = (fmt == F43) || (fmt == F50) || (fmt == F57);
    assign fixed     = srgb || (fmt == F64);
    assign supported = fixed || (fmt == F76) || (fmt == F83) || (fmt == F97);

    // sRGB: B8G8R8A8 swaps the R and B bytes
    wire bgr = (fmt == F50);
    wire [31:0] sr, sg, sb, sa;
    ad_fblend_srgb_lut u_lr (.c(bgr ? raw[23:16] : raw[7:0]),  .f(sr));
    ad_fblend_srgb_lut u_lg (.c(raw[15:8]),                    .f(sg));
    ad_fblend_srgb_lut u_lb (.c(bgr ? raw[7:0]   : raw[23:16]), .f(sb));
    ad_unorm2f #(.N(8))  u_la (.x(raw[31:24]), .f(sa));
    // A2B10G10R10
    wire [31:0] ur, ug, ub, ua;
    ad_unorm2f #(.N(10)) u_ur (.x(raw[9:0]),   .f(ur));
    ad_unorm2f #(.N(10)) u_ug (.x(raw[19:10]), .f(ug));
    ad_unorm2f #(.N(10)) u_ub (.x(raw[29:20]), .f(ub));
    ad_unorm2f #(.N(2))  u_ua (.x(raw[31:30]), .f(ua));
    // fp16
    wire [31:0] hr, hg, hb, ha;
    ad_fblend_h2f u_hr (.h(raw[15:0]),  .f(hr));
    ad_fblend_h2f u_hg (.h(raw[31:16]), .f(hg));
    ad_fblend_h2f u_hb (.h(raw[47:32]), .f(hb));
    ad_fblend_h2f u_ha (.h(raw[63:48]), .f(ha));

    always @(*) begin
        if (srgb)             d = {sa, sb, sg, sr};
        else if (fmt == F64)  d = {ua, ub, ug, ur};
        else if (fmt == F76)  d = {ONE, 32'd0, 32'd0, hr};
        else if (fmt == F83)  d = {ONE, 32'd0, hg, hr};
        else if (fmt == F97)  d = {ha, hb, hg, hr};
        else                  d = 128'd0;
    end
endmodule
