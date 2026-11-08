// ad_fblend_factor: each VkBlendFactor selects the right term: ZERO/15 -> +0,
// ONE -> 1.0, X -> X, ONE_MINUS_X -> ad_fp_add(1.0, X, sub), SRC_ALPHA_SATURATE ->
// 1.0 on alpha, min(sa, 1 - da) on R, G, B (reference: separate ad_fp_add +
// ad_fblend_minmax instances).
module fv_ad_fblend_factor;
    (* anyconst *) reg [3:0]  sel;
    (* anyconst *) reg        al;
    (* anyconst *) reg [31:0] s;
    (* anyconst *) reg [31:0] sa;
    (* anyconst *) reg [31:0] d;
    (* anyconst *) reg [31:0] da;
    (* anyconst *) reg [31:0] c;
    (* anyconst *) reg [31:0] ca;
    wire [31:0] f;
    ad_fblend_factor u (.sel(sel), .is_alpha(al), .s(s), .sa(sa), .d(d), .da(da), .c(c), .ca(ca), .f(f));
    reg [31:0] x;
    always @(*) begin
        case (sel)
            4'd2, 4'd3: x = s;   4'd4, 4'd5: x = d;   4'd6, 4'd7: x = sa;
            4'd8, 4'd9: x = da;  4'd10, 4'd11: x = c; 4'd12, 4'd13: x = ca;
            default: x = da;
        endcase
    end
    wire [31:0] om, sat;
    ad_fp_add        r_om  (.a(32'h3F80_0000), .b(x), .sub(1'b1), .y(om));
    ad_fblend_minmax r_sat (.a(sa), .b(om), .is_max(1'b0), .y(sat));
    always @(*) begin
        if (sel == 4'd0 || sel == 4'd15) a_zero: assert (f == 32'd0);
        if (sel == 4'd1) a_one: assert (f == 32'h3F80_0000);
        if (sel >= 4'd2 && sel <= 4'd13 && !sel[0]) a_x:  assert (f == x);
        if (sel >= 4'd2 && sel <= 4'd13 &&  sel[0]) a_om: assert (f == om);
        if (sel == 4'd14 && al)  a_sat_a: assert (f == 32'h3F80_0000);
        if (sel == 4'd14 && !al) a_sat:   assert (f == sat);
    end
endmodule
