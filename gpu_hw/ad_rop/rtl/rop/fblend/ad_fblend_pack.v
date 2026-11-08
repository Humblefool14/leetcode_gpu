// ad_fblend_pack -- 4 x fp32 (R, G, B, A at r[32c +: 32]) to one stored 64-bit
// lane: raw (new bits) and keep (1 = keep the stored bit).  Encoders: sRGB R, G, B
// ad_fblend_srgb_enc, sRGB alpha ad_f2unorm #(8), UNORM10/2 ad_f2unorm #(10)/#(2),
// fp16 ad_fblend_f2h.  keep = 1 for channels whose write-mask bit wm[c] is 0,
// bits beyond the format's size, unsupported formats and inactive lanes
// (active = 0).  raw is 0 wherever keep is 1.  Combinational.
module ad_fblend_pack (
    input  wire [127:0] r,
    input  wire [7:0]   fmt,
    input  wire [3:0]   wm,
    input  wire         active,
    output wire [63:0]  raw,
    output wire [63:0]  keep
);
    localparam [7:0] F43 = 8'd43, F50 = 8'd50, F57 = 8'd57, F64 = 8'd64,
                     F76 = 8'd76, F83 = 8'd83, F97 = 8'd97;
    wire [31:0] cr = r[31:0], cg = r[63:32], cb = r[95:64], ca = r[127:96];
    wire srgb = (fmt == F43) || (fmt == F50) || (fmt == F57);
    wire bgr  = (fmt == F50);

    wire [7:0] er, eg, eb, ea;
    ad_fblend_srgb_enc  u_er (.f(cr), .c(er));
    ad_fblend_srgb_enc  u_eg (.f(cg), .c(eg));
    ad_fblend_srgb_enc  u_eb (.f(cb), .c(eb));
    ad_f2unorm #(.N(8)) u_ea (.f(ca), .u(ea));
    wire [9:0] ur, ug, ub; wire [1:0] ua;
    ad_f2unorm #(.N(10)) u_ur (.f(cr), .u(ur));
    ad_f2unorm #(.N(10)) u_ug (.f(cg), .u(ug));
    ad_f2unorm #(.N(10)) u_ub (.f(cb), .u(ub));
    ad_f2unorm #(.N(2))  u_ua (.f(ca), .u(ua));
    wire [15:0] hr, hg, hb, ha;
    ad_fblend_f2h u_hr (.f(cr), .h(hr));
    ad_fblend_f2h u_hg (.f(cg), .h(hg));
    ad_fblend_f2h u_hb (.f(cb), .h(hb));
    ad_fblend_f2h u_ha (.f(ca), .h(ha));

    // per-channel field masks m{R,G,B,A} and the new bits
    reg [63:0] nv, mr, mg, mb, ma;
    always @(*) begin
        nv = 64'd0; mr = 64'd0; mg = 64'd0; mb = 64'd0; ma = 64'd0;
        if (srgb) begin
            nv = {32'd0, ea, bgr ? er : eb, eg, bgr ? eb : er};
            mr = bgr ? 64'h0000_0000_00FF_0000 : 64'h0000_0000_0000_00FF;
            mg = 64'h0000_0000_0000_FF00;
            mb = bgr ? 64'h0000_0000_0000_00FF : 64'h0000_0000_00FF_0000;
            ma = 64'h0000_0000_FF00_0000;
        end else if (fmt == F64) begin
            nv = {32'd0, ua, ub, ug, ur};
            mr = 64'h0000_0000_0000_03FF;
            mg = 64'h0000_0000_000F_FC00;
            mb = 64'h0000_0000_3FF0_0000;
            ma = 64'h0000_0000_C000_0000;
        end else if (fmt == F76 || fmt == F83 || fmt == F97) begin
            nv = {ha, hb, hg, hr};
            mr = 64'h0000_0000_0000_FFFF;
            mg = (fmt != F76) ? 64'h0000_0000_FFFF_0000 : 64'd0;
            mb = (fmt == F97) ? 64'h0000_FFFF_0000_0000 : 64'd0;
            ma = (fmt == F97) ? 64'hFFFF_0000_0000_0000 : 64'd0;
        end
    end
    wire [63:0] wr = active ? (({64{wm[0]}} & mr) | ({64{wm[1]}} & mg) |
                               ({64{wm[2]}} & mb) | ({64{wm[3]}} & ma)) : 64'd0;
    assign keep = ~wr;
    assign raw  = nv & wr;
endmodule
