// fv_atom_abstract -- stands in for ad_mem_atom_alu in the ad_su_lds harness
// (compositional: the real leaf is proven against an independent reference
// in formal/ad_mem_atom_alu).  The LDS properties (indivisibility, lane
// order, the compare operand) hold for any function of (op, old, a, cmp) used
// alike by the DUT and the reference; this one is cheap for the solvers and
// depends on every input.
module ad_mem_atom_alu (
    input  wire [3:0]  op,
    input  wire [31:0] old,
    input  wire [31:0] a,
    input  wire [31:0] cmp,
    output wire [31:0] nv
);
    assign nv = (old == cmp) ? a : (old ^ a ^ {28'd0, op});
endmodule
