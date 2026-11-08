// ad_blend_unpack8: unpack(pack(x)) == x for the 8-bit formats (the channels they have; the
// missing ones read G/B = 0, A = 255), "format valid" exactly for the 7 formats, missing alpha
// reads 255, 5/6-bit fields expand by bit replication, A1 reads 0/255.
`include "ad_rop_state.vh"
module fv_ad_blend_unpack8;
    (* anyconst *) reg [7:0]  r, g, b, a, fmt;
    (* anyconst *) reg [31:0] lane;
    wire [31:0] bits, keep;
    wire [7:0]  r2, g2, b2, a2, ur, ug, ub, ua;
    wire        ok2, ok;
    ad_blend_pack8   u_pk (.r(r), .g(g), .b(b), .a(a), .fmt(fmt), .wm(4'hF), .bits(bits), .keep(keep));
    ad_blend_unpack8 u_rt (.lane(bits), .fmt(fmt), .r(r2), .g(g2), .b(b2), .a(a2), .ok(ok2));
    ad_blend_unpack8 u_up (.lane(lane), .fmt(fmt), .r(ur), .g(ug), .b(ub), .a(ua), .ok(ok));
    wire in_list = fmt == 8'd37 || fmt == 8'd51 || fmt == 8'd44 || fmt == 8'd9 ||
                   fmt == 8'd16 || fmt == 8'd4  || fmt == 8'd8;
    always @(*) begin
        a_ok: assert (ok == in_list);
        if (fmt == 8'd37 || fmt == 8'd51 || fmt == 8'd44)
            a_rt32: assert (r2 == r && g2 == g && b2 == b && a2 == a);
        if (fmt == 8'd9)  a_rt8:  assert (r2 == r && g2 == 8'd0 && b2 == 8'd0 && a2 == 8'hFF);
        if (fmt == 8'd16) a_rt16: assert (r2 == r && g2 == g && b2 == 8'd0 && a2 == 8'hFF);
        if (fmt == 8'd9 || fmt == 8'd16 || fmt == 8'd4) a_noalpha: assert (ua == 8'hFF);
        if (fmt == 8'd44) a_bgra: assert (ub == lane[7:0] && ug == lane[15:8] && ur == lane[23:16] && ua == lane[31:24]);
        if (fmt == 8'd37 || fmt == 8'd51) a_rgba: assert ({ua, ub, ug, ur} == lane);
        if (fmt == 8'd4) a_565: assert (ur[7:3] == lane[15:11] && ur[2:0] == lane[15:13] &&
                                        ug[7:2] == lane[10:5]  && ug[1:0] == lane[10:9]  &&
                                        ub[7:3] == lane[4:0]   && ub[2:0] == lane[4:2]);
        if (fmt == 8'd8) a_1555: assert (ua == (lane[15] ? 8'hFF : 8'h00) &&
                                         ur[7:3] == lane[14:10] && ur[2:0] == lane[14:12] &&
                                         ug[7:3] == lane[9:5]   && ug[2:0] == lane[9:7] &&
                                         ub[7:3] == lane[4:0]   && ub[2:0] == lane[4:2]);
        // the 5/6-bit round trip of an 8-bit value is within one quantization step
        if (fmt == 8'd4) a_565q: assert ((r2 >= r ? r2 - r : r - r2) <= 8'd4 &&
                                         (g2 >= g ? g2 - g : g - g2) <= 8'd2 &&
                                         (b2 >= b ? b2 - b : b - b2) <= 8'd4);
    end
endmodule
