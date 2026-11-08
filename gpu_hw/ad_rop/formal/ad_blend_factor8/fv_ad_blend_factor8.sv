// ad_blend_factor8 equals an independently written reference mux for every select (0..31),
// dual and alpha flag and every channel value.
module fv_ad_blend_factor8;
    (* anyconst *) reg [4:0] sel;
    (* anyconst *) reg dual, is_alpha;
    (* anyconst *) reg [7:0] s_c, s_a, d_c, d_a, k_c, k_a, s1_c, s1_a;
    wire [7:0] f;
    ad_blend_factor8 dut (.sel(sel), .dual(dual), .is_alpha(is_alpha), .s_c(s_c), .s_a(s_a),
        .d_c(d_c), .d_a(d_a), .k_c(k_c), .k_a(k_a), .s1_c(s1_c), .s1_a(s1_a), .f(f));
    reg [7:0] r;
    always @(*) begin
        r = 8'd0;
        if (sel == 5'd1) r = 8'd255;
        if (sel == 5'd2) r = s_c;
        if (sel == 5'd3) r = 8'd255 - s_c;
        if (sel == 5'd4) r = d_c;
        if (sel == 5'd5) r = 8'd255 - d_c;
        if (sel == 5'd6) r = s_a;
        if (sel == 5'd7) r = 8'd255 - s_a;
        if (sel == 5'd8) r = d_a;
        if (sel == 5'd9) r = 8'd255 - d_a;
        if (sel == 5'd10) r = k_c;
        if (sel == 5'd11) r = 8'd255 - k_c;
        if (sel == 5'd12) r = k_a;
        if (sel == 5'd13) r = 8'd255 - k_a;
        if (sel == 5'd14) r = is_alpha ? 8'd255 : (s_a <= 8'd255 - d_a ? s_a : 8'd255 - d_a);
        if (dual && sel == 5'd15) r = s1_c;
        if (dual && sel == 5'd16) r = 8'd255 - s1_c;
        if (dual && sel == 5'd17) r = s1_a;
        if (dual && sel == 5'd18) r = 8'd255 - s1_a;
        a_ref: assert (f == r);
        if (!dual && sel >= 5'd15) a_nodual_zero: assert (f == 8'd0);
        if (sel >= 5'd19) a_hi_zero: assert (f == 8'd0);
    end
endmodule
