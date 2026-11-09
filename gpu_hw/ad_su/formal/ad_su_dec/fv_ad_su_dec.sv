// fv_ad_su_dec: the registered path of ad_su_dec.  Free d_valid/d_warp/
// d_pc/d_instr/u_ready each cycle.  d_ready = !u_valid || u_ready; a taken
// instruction appears on u_* the next cycle as ad_su_dec_core(d_instr) (a
// second copy of the combinational decode, the reference, registered by the harness); u_* holds while
// u_valid && !u_ready; nothing is lost or duplicated (taken - delivered =
// u_valid); after reset u_valid = 0.
module fv_ad_su_dec #(
    parameter NREGS = 32, parameter PACKED = 0, parameter SUBGROUP = 0,
    parameter HAS_SA = 0, parameter MS4 = 0
) (
    input wire clk,
    input wire rst_n,
    input wire d_valid,
    input wire [1:0] d_warp,
    input wire [15:0] d_pc,
    input wire [63:0] d_instr,
    input wire u_ready
);
`include "ad_su_uop.vh"
    wire d_ready, u_valid;
    wire [1:0] u_warp;
    wire [15:0] u_pc;
    wire [AD_UOP_W-1:0] u_uop;
    ad_su_dec #(.WARP_W(2), .UOP_W(AD_UOP_W), .NREGS(NREGS), .PACKED(PACKED), .SUBGROUP(SUBGROUP),
        .HAS_SA(HAS_SA), .MS4(MS4)) dut (.clk(clk), .rst_n(rst_n), .d_valid(d_valid),
        .d_ready(d_ready), .d_warp(d_warp), .d_pc(d_pc), .d_instr(d_instr), .u_valid(u_valid),
        .u_ready(u_ready), .u_warp(u_warp), .u_pc(u_pc), .u_uop(u_uop));

    // the reference: the decode of each taken instruction, kept
    reg [AD_UOP_W-1:0] h_uop;
    reg [1:0] h_warp;
    reg [15:0] h_pc;
    wire [AD_UOP_W-1:0] ref_uop;
    ad_su_dec_core #(.UOP_W(AD_UOP_W), .NREGS(NREGS), .PACKED(PACKED), .SUBGROUP(SUBGROUP),
        .HAS_SA(HAS_SA), .MS4(MS4)) ref_core (.instr(d_instr), .uop(ref_uop));

    reg init = 1'b1;
    reg p_stall = 1'b0;
    reg [AD_UOP_W-1:0] p_uop;
    reg [1:0] p_warp;
    reg [15:0] p_pc;
    reg [3:0] n_in = 0, n_out = 0;
    always @(posedge clk) begin
        init <= 1'b0;
        if (d_valid && d_ready) begin
            h_uop <= ref_uop; h_warp <= d_warp; h_pc <= d_pc;
        end
        p_stall <= rst_n && u_valid && !u_ready;
        p_uop <= u_uop; p_warp <= u_warp; p_pc <= u_pc;
        if (!rst_n) begin
            n_in <= 0; n_out <= 0;
        end else begin
            n_in <= n_in + (d_valid && d_ready);
            n_out <= n_out + (u_valid && u_ready);
        end
    end
    always @(*) begin
        if (init) assume(!rst_n);
        assert(d_ready == (!u_valid || u_ready));
        if (!init && rst_n) begin
            if (u_valid) assert(u_uop == h_uop && u_warp == h_warp && u_pc == h_pc);
            if (p_stall) assert(u_valid && u_uop == p_uop && u_warp == p_warp && u_pc == p_pc);
            assert(n_in - n_out == {3'd0, u_valid});
        end
    end
    always @(posedge clk) if (!init && $past(!rst_n)) assert(!u_valid);
    always @(*) if (!init && rst_n) cover(u_valid && u_uop[AD_UOP_UNIT +: 4] == AD_UNIT_TEX && p_stall);
endmodule
