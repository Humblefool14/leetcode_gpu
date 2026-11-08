// ad_dtest_bounds -- depth bounds test of the stored depth z_a.
// z_a: D16 and D24 the stored UNORM as fp32 (ad_unorm2f, RNE), D32F the stored word.
// outside = !(z_a >= bmin && z_a <= bmax) in fp32 order (-0 = +0): a NaN z_a or a
// NaN bound is outside (a comparison with NaN is false).  Combinational.
module ad_dtest_bounds (
    input  wire [2:0]  fmt,      // {D16, D32F, D24S8}
    input  wire [31:0] stored,
    input  wire [31:0] bmin,
    input  wire [31:0] bmax,
    output wire [31:0] z_a,
    output wire        outside
);
    wire [31:0] f16, f24;
    ad_unorm2f #(.N(16)) u_u16 (.x(stored[15:0]), .f(f16));
    ad_unorm2f #(.N(24)) u_u24 (.x(stored[23:0]), .f(f24));
    assign z_a = fmt[1] ? stored : fmt[2] ? f16 : f24;
    wire lt0, eq0, un0, lt1, eq1, un1;
    ad_fp_cmp u_lo (.a(z_a), .b(bmin), .lt(lt0), .eq(eq0), .un(un0));
    ad_fp_cmp u_hi (.a(z_a), .b(bmax), .lt(lt1), .eq(eq1), .un(un1));
    // inside: z_a >= bmin (ordered, not lt) and z_a <= bmax (lt or eq)
    wire in_rng = !un0 && !lt0 && !un1 && (lt1 || eq1);
    assign outside = !in_rng;
endmodule
