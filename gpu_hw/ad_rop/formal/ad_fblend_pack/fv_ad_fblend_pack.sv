// ad_fblend_pack:
//  - keep is exactly ~(fields of the format whose write-mask bit is set), all ones for
//    inactive lanes and unsupported formats (table written independently here);
//  - raw is 0 wherever keep is 1;
//  - each written field holds the encoding of its own channel (reference encoders);
//  - round trip: pack(unpack(x)) == x on every written field, for every supported
//    format (fp16 NaN fields excluded: they become 0x7E00 by design).
module fv_ad_fblend_pack;
    (* anyconst *) reg [127:0] r;
    (* anyconst *) reg [7:0]   fmt;
    (* anyconst *) reg [3:0]   wm;
    (* anyconst *) reg         active;
    (* anyconst *) reg [63:0]  x;
    wire [63:0] raw, keep;
    ad_fblend_pack u (.r(r), .fmt(fmt), .wm(wm), .active(active), .raw(raw), .keep(keep));
    wire [31:0] R = r[31:0], G = r[63:32], B = r[95:64], A = r[127:96];
    // expected written-bit masks per channel
    reg [63:0] mR, mG, mB, mA;
    always @(*) begin
        mR = 0; mG = 0; mB = 0; mA = 0;
        case (fmt)
            8'd43, 8'd57: begin mR = 64'hFF; mG = 64'hFF00; mB = 64'hFF0000; mA = 64'hFF000000; end
            8'd50:        begin mB = 64'hFF; mG = 64'hFF00; mR = 64'hFF0000; mA = 64'hFF000000; end
            8'd64:        begin mR = 64'h3FF; mG = 64'hFFC00; mB = 64'h3FF00000; mA = 64'hC0000000; end
            8'd76:        begin mR = 64'hFFFF; end
            8'd83:        begin mR = 64'hFFFF; mG = 64'hFFFF0000; end
            8'd97:        begin mR = 64'hFFFF; mG = 64'hFFFF0000; mB = 64'hFFFF_0000_0000; mA = 64'hFFFF_0000_0000_0000; end
            default: ;
        endcase
    end
    wire [63:0] wexp = active ? (({64{wm[0]}} & mR) | ({64{wm[1]}} & mG) | ({64{wm[2]}} & mB) | ({64{wm[3]}} & mA)) : 64'd0;
    // reference encoders
    wire [7:0] sR, sG, sB, uA8; wire [9:0] tR, tG, tB; wire [1:0] tA; wire [15:0] hR, hG, hB, hA;
    ad_fblend_srgb_enc e_sr (.f(R), .c(sR));
    ad_fblend_srgb_enc e_sg (.f(G), .c(sG));
    ad_fblend_srgb_enc e_sb (.f(B), .c(sB));
    ad_f2unorm #(.N(8))  e_a8 (.f(A), .u(uA8));
    ad_f2unorm #(.N(10)) e_tr (.f(R), .u(tR));
    ad_f2unorm #(.N(10)) e_tg (.f(G), .u(tG));
    ad_f2unorm #(.N(10)) e_tb (.f(B), .u(tB));
    ad_f2unorm #(.N(2))  e_ta (.f(A), .u(tA));
    ad_fblend_f2h e_hr (.f(R), .h(hR));
    ad_fblend_f2h e_hg (.f(G), .h(hG));
    ad_fblend_f2h e_hb (.f(B), .h(hB));
    ad_fblend_f2h e_ha (.f(A), .h(hA));
    wire srgb = (fmt == 43) || (fmt == 57) || (fmt == 50);
    wire f16  = (fmt == 76) || (fmt == 83) || (fmt == 97);
    wire [63:0] nexp = (fmt == 43 || fmt == 57) ? {32'd0, uA8, sB, sG, sR} :
                       (fmt == 50)              ? {32'd0, uA8, sR, sG, sB} :
                       (fmt == 64)              ? {32'd0, tA, tB, tG, tR} :
                       f16                      ? {hA, hB, hG, hR} : 64'd0;
    // round trip
    wire [127:0] dx; wire fx, sx; wire [63:0] rawx, keepx;
    ad_fblend_unpack ux (.raw(x), .fmt(fmt), .d(dx), .fixed(fx), .supported(sx));
    ad_fblend_pack   px (.r(dx), .fmt(fmt), .wm(4'hF), .active(1'b1), .raw(rawx), .keep(keepx));
    function nan16; input [15:0] h; nan16 = (h[14:10] == 5'h1F) && (h[9:0] != 0); endfunction
    wire [63:0] nanmask = f16 ? {{16{nan16(x[63:48])}}, {16{nan16(x[47:32])}}, {16{nan16(x[31:16])}}, {16{nan16(x[15:0])}}} : 64'd0;
    always @(*) begin
        a_keep:  assert (keep == ~wexp);
        a_clean: assert ((raw & keep) == 64'd0);
        a_value: assert ((raw & wexp) == (nexp & wexp));
        if (sx) a_roundtrip: assert ((rawx & ~keepx & ~nanmask) == (x & ~keepx & ~nanmask));
    end
endmodule
