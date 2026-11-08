// ad_rop_occ -- occlusion counter (spec/gpu/rop/ad_rop_occ.md).
// count <= (clear ? 0 : count) + (inc_valid && ROP_CTRL[0] ? inc_n : 0); 40-bit wrap.
`include "ad_rop_state.vh"
module ad_rop_occ (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        st_we,
    input  wire [8:0]  st_idx,
    input  wire [31:0] st_wdata,
    input  wire        inc_valid,
    input  wire [4:0]  inc_n,
    input  wire        clear,
    output reg  [39:0] count
);
    reg occ_en;   // ROP_CTRL[0]

    wire [39:0] base = clear ? 40'd0 : count;
`ifdef MUT_OCC_EN
    wire [39:0] add  = inc_valid ? {35'd0, inc_n} : 40'd0;   // mutation: ignores ROP_CTRL[0]
`else
    wire [39:0] add  = (inc_valid && occ_en) ? {35'd0, inc_n} : 40'd0;
`endif

    always @(posedge clk) begin
        if (!rst_n) begin
            occ_en <= 1'b0;
            count  <= 40'd0;
        end else begin
            if (st_we && st_idx == `AD_S_ROP_CTRL) occ_en <= st_wdata[`AD_ROPC_OCC];
            count <= base + add;
        end
    end
endmodule
