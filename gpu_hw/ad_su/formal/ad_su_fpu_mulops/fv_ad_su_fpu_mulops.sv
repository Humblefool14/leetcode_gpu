// fv_ad_su_fpu_mulops: the multiplier operands.
//  - float ops: the 24-bit significands {e != 0, m}, upper 9 bits 0; b is
//    1.0 (0x800000) for fadd, fsub and fract;
//  - mul, mulh: both sign-extended; mulhsu: a sign-, b zero-extended;
//    mulhu: both zero-extended;
module fv_ad_su_fpu_mulops;
`include "ad_su_uop.vh"
    (* anyconst *) reg [4:0] o;
    (* anyconst *) reg [31:0] a, b;
    wire [32:0] ma, mb;
    ad_su_fpu_mulops u (.o(o), .ia(a), .ib(b), .ma(ma), .mb(mb));
    wire [7:0] op = {3'd0, o};

    always @(*) begin
        if (op < AD_FPU_MUL) begin
            assert (ma == {9'd0, a[30:23] != 8'd0, a[22:0]});
            if (op == AD_FPU_FADD || op == AD_FPU_FSUB || op == AD_FPU_FRACT)
                assert (mb == {9'd0, 24'h800000});
            else
                assert (mb == {9'd0, b[30:23] != 8'd0, b[22:0]});
        end
        if (op == AD_FPU_MUL || op == AD_FPU_MULH) begin
            assert (ma == {a[31], a});
            assert (mb == {b[31], b});
        end
        if (op == AD_FPU_MULHSU) begin
            assert (ma == {a[31], a});
            assert (mb == {1'b0, b});
        end
        if (op == AD_FPU_MULHU) begin
            assert (ma == {1'b0, a});
            assert (mb == {1'b0, b});
        end
    end
endmodule
