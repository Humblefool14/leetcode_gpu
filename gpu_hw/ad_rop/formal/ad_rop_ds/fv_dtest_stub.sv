// fv_dtest_stub -- abstraction of ad_rop_dtest for the ad_rop_ds / ad_ds_row harnesses:
// free pass/wword/wbe each cycle, constrained only by properties proven on the real
// module (formal/ad_rop_dtest): cov = 0 -> pass = 0, wbe = 0; no single format ->
// wbe = 0; D16 never enables bytes 2-3.
module ad_rop_dtest (
    input  wire [9:0]  depth,
    input  wire [26:0] sfront,
    input  wire [26:0] sback,
    input  wire [24:0] sops,
    input  wire [31:0] bmin,
    input  wire [31:0] bmax,
    input  wire        cov,
    input  wire        front,
    input  wire [31:0] zf,
    input  wire [31:0] stored,
    output wire        pass,
    output wire [31:0] wword,
    output wire [3:0]  wbe
);
    (* anyseq *) reg        f_pass;
    (* anyseq *) reg [31:0] f_wword;
    (* anyseq *) reg [3:0]  f_wbe;
    wire hasfmt = depth[7:5] == 3'b001 || depth[7:5] == 3'b010 || depth[7:5] == 3'b100;
    assign pass  = cov && f_pass;
    assign wword = f_wword;
    assign wbe   = (cov && hasfmt) ? (depth[7] ? {2'b00, f_wbe[1:0]} : f_wbe) : 4'd0;
endmodule
