// ad_fblend_h2f: never produces an fp32 denormal; keeps the sign of non-NaN values;
// NaN -> 0x7FC00000, inf -> inf; strictly monotonic on non-negative non-NaN fp16
// (h1 < h2 -> f1 < f2, so distinct values stay distinct); exactness: f2h(h2f(h)) == h.
module fv_ad_fblend_h2f;
    (* anyconst *) reg [15:0] h1;
    (* anyconst *) reg [15:0] h2;
    wire [31:0] f1, f2; wire [15:0] r1;
    ad_fblend_h2f u1 (.h(h1), .f(f1));
    ad_fblend_h2f u2 (.h(h2), .f(f2));
    ad_fblend_f2h ur (.f(f1), .h(r1));
    wire n1 = (h1[14:10] == 5'h1F) && (h1[9:0] != 0);
    wire n2 = (h2[14:10] == 5'h1F) && (h2[9:0] != 0);
    always @(*) begin
        a_no_denorm: assert (!(f1[30:23] == 8'd0 && f1[22:0] != 0));
        if (!n1) a_sign: assert (f1[31] == h1[15]);
        if (n1) a_nan: assert (f1 == 32'h7FC0_0000);
        if (h1[14:0] == 15'h7C00) a_inf: assert (f1 == {h1[15], 31'h7F80_0000});
        if (!n1 && !n2 && !h1[15] && !h2[15] && h1 < h2) a_mono: assert (f1 < f2);
        if (!n1) a_exact: assert (r1 == h1);
    end
endmodule
