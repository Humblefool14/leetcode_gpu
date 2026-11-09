// ad_vf_asm_pout -- primitive output stage of ad_vf_asm (spec section 4, prim_last).
// A primitive enters (in_valid/in_ready) with its lanes, free bits, kind and its warp's PT base;
// it is held until the next one exists (then the held one goes out on prim_*) or the draw ends
// (fin: the held one goes out with prim_last).  PT entry of slot s = ptbase + lane_s (mod 256).
module ad_vf_asm_pout (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [4:0]  in_l0,
    input  wire [4:0]  in_l1,
    input  wire [4:0]  in_l2,
    input  wire [2:0]  in_free,
    input  wire [1:0]  in_kind,
    input  wire [7:0]  ptbase,
    input  wire        fin,        // draw ended: no further primitive
    output reg         hold_v,     // a primitive is held back
    output wire        prim_valid,
    input  wire        prim_ready,
    output reg  [25:0] prim_vtx,
    output reg  [2:0]  prim_free,
    output wire        prim_last
);
    assign prim_valid = hold_v && (in_valid || fin);
    assign prim_last  = hold_v && fin && !in_valid;
    assign in_ready   = in_valid && (!hold_v || prim_ready);
    wire   out_fire   = prim_valid && prim_ready;
    always @(posedge clk) begin
        if (!rst_n) begin
            hold_v <= 1'b0; prim_vtx <= 26'd0; prim_free <= 3'd0;
        end else if (in_ready) begin
            hold_v    <= 1'b1;
            prim_vtx  <= {in_kind, ptbase + {3'd0, in_l2}, ptbase + {3'd0, in_l1}, ptbase + {3'd0, in_l0}};
            prim_free <= in_free;
        end else if (out_fire) begin
            hold_v <= 1'b0;
        end
    end
endmodule
