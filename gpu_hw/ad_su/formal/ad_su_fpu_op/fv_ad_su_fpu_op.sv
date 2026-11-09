// fv_ad_su_fpu_op: one lane's operation, the multiplier product pr free
// (its value only matters through ad_su_ffma_p, whose properties hold for
// any product, and mul*, which pass pr through).
//  - compares are Boolean (all ones or 0), fne = ~feq, fle = feq | flt,
//    feq symmetric, never flt(a, b) and flt(b, a); NaN: only fne is true;
//  - fmin/fmax symmetric, min <= max, each the flushed a, the flushed b or
//    0x7FC00000 (both NaN);
//  - fsgnj = {b[31], a[30:0]} without sat;
//  - mul = pr[31:0], mulh* = pr[63:32];
//  - sat on a float result gives a value in [+0, 1.0]; sat does not change
//    the integer results;
//  - every NaN float result (but fsgnj's) is 0x7FC00000, none is a denormal.
module fv_ad_su_fpu_op;
`include "ad_su_uop.vh"
    localparam [31:0] QNAN = 32'h7FC00000;
    (* anyconst *) reg [4:0] o;
    (* anyconst *) reg [31:0] a, b, c;
    (* anyconst *) reg [2:0] rm;
    (* anyconst *) reg st;
    (* anyconst *) reg [63:0] pr;
    (* anyconst *) reg [4:0] o2;    // a second op on the same operands

    wire [31:0] y, y_sw, y_ns, y2;
    ad_su_fpu_op u   (.o(o), .ia(a), .ib(b), .ic(c), .irm(rm), .ist(st), .pr(pr), .res(y));
    ad_su_fpu_op u_s (.o(o), .ia(b), .ib(a), .ic(c), .irm(rm), .ist(st), .pr(pr), .res(y_sw));
    ad_su_fpu_op u_n (.o(o), .ia(a), .ib(b), .ic(c), .irm(rm), .ist(1'b0), .pr(pr), .res(y_ns));
    ad_su_fpu_op u_2 (.o(o2), .ia(a), .ib(b), .ic(c), .irm(rm), .ist(1'b0), .pr(pr), .res(y2));

    wire [7:0] op = {3'd0, o}, op2 = {3'd0, o2};
    wire [31:0] fa = a[30:23] == 8'd0 ? {a[31], 31'd0} : a;
    wire [31:0] fb = b[30:23] == 8'd0 ? {b[31], 31'd0} : b;
    wire nan_a = fa[30:23] == 8'hFF && fa[22:0] != 23'd0;
    wire nan_b = fb[30:23] == 8'hFF && fb[22:0] != 23'd0;
    wire isf = op <= AD_FPU_FMAX || op == AD_FPU_FCVTSW || op == AD_FPU_FCVTSWU ||
               op == AD_FPU_FROUND || op == AD_FPU_FRACT;
    function [32:0] key(input [31:0] f);
        key = f[31] ? {1'b0, ~f} : {1'b1, f};
    endfunction

    always @(*) begin
        if (op >= AD_FPU_FEQ && op <= AD_FPU_FNE) begin
            assert (y == 32'd0 || y == 32'hFFFFFFFF);
            if (op != AD_FPU_FLT && op != AD_FPU_FLE)
                assert (y == y_sw);
            if (nan_a || nan_b)
                assert (y == (op == AD_FPU_FNE ? 32'hFFFFFFFF : 32'd0));
            if (op == AD_FPU_FLT)
                assert (!(y[0] && y_sw[0]));
            if (op == AD_FPU_FNE && op2 == AD_FPU_FEQ)
                assert (y == ~y2);
            if (op == AD_FPU_FLE && op2 == AD_FPU_FLT)
                assert (y[0] == (y2[0] || (!nan_a && !nan_b &&
                        ((fa[30:0] == 31'd0 && fb[30:0] == 31'd0) || fa == fb))));
        end
        if (op == AD_FPU_FMIN || op == AD_FPU_FMAX) begin
            assert (y == y_sw);
            assert (y_ns == fa || y_ns == fb || (y_ns == QNAN && nan_a && nan_b));
            if (op == AD_FPU_FMIN && op2 == AD_FPU_FMAX && !nan_a && !nan_b)
                assert (key(y_ns) <= key(y2));
        end
        if (op == AD_FPU_FSGNJ)
            assert (y_ns == {b[31], a[30:0]});
        if (op == AD_FPU_MUL)
            assert (y == pr[31:0]);
        if (op >= AD_FPU_MULH && op <= AD_FPU_MULHU)
            assert (y == pr[63:32]);
        if (isf && st)
            assert (!y[31] && y <= 32'h3F800000);
        if (!isf)
            assert (y == y_ns);
        if (isf && op != AD_FPU_FSGNJ) begin
            if (y_ns[30:23] == 8'hFF && y_ns[22:0] != 23'd0)
                assert (y_ns == QNAN);
            if (y_ns[30:23] == 8'd0)
                assert (y_ns[22:0] == 23'd0);
        end
    end
endmodule
