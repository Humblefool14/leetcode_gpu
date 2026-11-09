// ad_vf_asm_lastuse -- last-use (prim_free) computation of ad_vf_asm (spec section 4).
// While a warp's primitives are formed (we), primitive number wj records itself as the last
// user of its three lanes.  At emission, primitive rj with lanes rl0..rl2 gets free bit s when
// it is the last user of rl_s and no lower slot names the same lane (points (p,p,p) and lines
// (a,b,b) free their entries once).  clr starts a warp (the table is only read for lanes the
// warp's own primitives wrote; clr resets it anyway).
module ad_vf_asm_lastuse (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clr,
    input  wire       we,
    input  wire [4:0] wj,
    input  wire [4:0] wl0,
    input  wire [4:0] wl1,
    input  wire [4:0] wl2,
    input  wire [4:0] rj,
    input  wire [4:0] rl0,
    input  wire [4:0] rl1,
    input  wire [4:0] rl2,
    output wire [2:0] free
);
    reg [4:0] lu [0:31];
    integer k;
    always @(posedge clk) begin
        if (!rst_n || clr) begin
            for (k = 0; k < 32; k = k + 1) lu[k] <= 5'd0;
        end else if (we) begin
            lu[wl0] <= wj; lu[wl1] <= wj; lu[wl2] <= wj;
        end
    end
    wire m0 = (lu[rl0] == rj);
    wire m1 = (lu[rl1] == rj) && (rl1 != rl0);
`ifdef MUT_ASM_FREE_BOTH
    wire m2 = (lu[rl2] == rj) && (rl2 != rl0);          // mutation: (a,b,b) frees b twice
`else
    wire m2 = (lu[rl2] == rj) && (rl2 != rl0) && (rl2 != rl1);
`endif
    assign free = {m2, m1, m0};
endmodule
