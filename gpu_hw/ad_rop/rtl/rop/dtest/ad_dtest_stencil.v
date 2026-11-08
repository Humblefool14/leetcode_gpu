// ad_dtest_stencil -- the stencil test of one entry and the stencil to write.
// test = (sref & cmask) cop (s_a & cmask) (VkCompareOp, unsigned).  The op is
// fail_op when the test fails, else pass_op / zfail_op by the depth result dres.
// The written stencil keeps the bits outside wmask: (s_a & ~wmask) | (new & wmask).
// Combinational.
module ad_dtest_stencil (
    input  wire [7:0] s_a,
    input  wire [7:0] sref,
    input  wire [7:0] cmask,
    input  wire [7:0] wmask,
    input  wire [2:0] cop,
    input  wire [2:0] fail_op,
    input  wire [2:0] pass_op,
    input  wire [2:0] zfail_op,
    input  wire       dres,     // depth result (1 when the depth test is off)
    output wire       spass,    // stencil test passed
    output wire [7:0] swr,      // stencil to write
    output wire       sdiff     // swr differs from s_a (byte 3 enable)
);
    wire [7:0] a = sref & cmask;
    wire [7:0] b = s_a  & cmask;
    ad_cmp_op u_cmp (.op(cop), .lt(a < b), .eq(a == b), .un(1'b0), .pass(spass));
    wire [2:0] op = !spass ? fail_op : (dres ? pass_op : zfail_op);
    wire [7:0] snew;
    ad_dtest_stencil_op u_op (.op(op), .s(s_a), .sref(sref), .n(snew));
    assign swr   = (s_a & ~wmask) | (snew & wmask);
    assign sdiff = (swr != s_a);
endmodule
