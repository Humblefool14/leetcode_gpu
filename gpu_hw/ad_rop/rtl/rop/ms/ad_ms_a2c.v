// ad_ms_a2c -- alpha to coverage of one lane (spec/gpu/rop/ad_rop_ms.md §4).
// n = how many of 0.125, 0.375, 0.625, 0.875 the fp32 alpha reaches (fp
// compares of the bits; NaN and negatives, -0 included, reach none):
//   n 0 -> 4'b0000, 1 -> {0}, 2 -> {0,3}, 3 -> {0,1,3}, 4 -> all.
// half = alpha >= 0.5 (the one-sample rule).  Combinational.
// MUT_A2C_STEP moves the first threshold to 0.25 (TB mutation check).
module ad_ms_a2c (
    input  wire [31:0] alpha,
    output reg  [3:0]  mask,
    output wire        half
);
`ifdef MUT_A2C_STEP
    localparam [31:0] T0 = 32'h3E80_0000;   // 0.25 (mutation)
`else
    localparam [31:0] T0 = 32'h3E00_0000;   // 0.125
`endif
    localparam [31:0] T1 = 32'h3EC0_0000;   // 0.375
    localparam [31:0] T2 = 32'h3F20_0000;   // 0.625
    localparam [31:0] T3 = 32'h3F60_0000;   // 0.875
    localparam [31:0] TH = 32'h3F00_0000;   // 0.5

    // reached = !(alpha < t) && ordered  (alpha >= t)
    wire lt0, lt1, lt2, lt3, lth, un;
    wire eq0, eq1, eq2, eq3, eqh, un1, un2, un3, unh;
    ad_fp_cmp u_c0 (.a(alpha), .b(T0), .lt(lt0), .eq(eq0), .un(un));
    ad_fp_cmp u_c1 (.a(alpha), .b(T1), .lt(lt1), .eq(eq1), .un(un1));
    ad_fp_cmp u_c2 (.a(alpha), .b(T2), .lt(lt2), .eq(eq2), .un(un2));
    ad_fp_cmp u_c3 (.a(alpha), .b(T3), .lt(lt3), .eq(eq3), .un(un3));
    ad_fp_cmp u_ch (.a(alpha), .b(TH), .lt(lth), .eq(eqh), .un(unh));

    wire r0 = !un && !lt0;
    wire r1 = !un && !lt1;
    wire r2 = !un && !lt2;
    wire r3 = !un && !lt3;
    assign half = !un && !lth;

    always @(*) begin
        if (r3)      mask = 4'b1111;
        else if (r2) mask = 4'b1011;
        else if (r1) mask = 4'b1001;
        else if (r0) mask = 4'b0001;
        else         mask = 4'b0000;
    end
endmodule
