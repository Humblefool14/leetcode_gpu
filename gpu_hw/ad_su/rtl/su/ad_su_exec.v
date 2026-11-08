// ad_su_exec -- warp control (spec ad_su_exec.md): EXEC and KILLED per warp,
// exec.set/and/or/save, kill, the warp-uniform branches, end and bar.
// Groups of an EXEC-unit instruction arrive one per cycle (x_ready is always
// 1); the Booleans of rs1 (x_a != 0) are gathered over the groups and the
// whole-warp operation (ad_ctl_exec_op, semantics of tools/gsi1model.py) is
// applied at the last group: EXEC/KILLED change at the end of that cycle,
// wc_* (branch: wc_op 0 with wc_pc = taken ? pc + imm : pc + 1; end 1; bar 2)
// leave the next cycle.  exec.save writes, through the short result,
// all-ones/0 per lane from the warp's EXEC bit, every lane of each group
// (s_lanes all ones); its s_* come SHORT_LAT cycles after each group
// (ad_ctl_spipe).  init_* sets EXEC and clears KILLED.
module ad_su_exec #(
    parameter NPHYS     = 8,
    parameter NWARPS    = 4,
    parameter WARP_W    = 2,
    parameter GRP_W     = 2,
    parameter SBE_W     = 2,
    parameter UOP_W     = 108,
    parameter SHORT_LAT = 6
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                x_valid,
    input  wire [WARP_W-1:0]   x_warp,
    input  wire [GRP_W-1:0]    x_grp,
    input  wire                x_last,
    input  wire [SBE_W:0]      x_sbe,
    input  wire [15:0]         x_pc,
    input  wire [UOP_W-1:0]    x_uop,
    input  wire [NPHYS*32-1:0] x_a,
    input  wire [NPHYS*32-1:0] x_b,
    input  wire [NPHYS*32-1:0] x_c,
    input  wire [2*NPHYS-1:0]  x_mask,
    input  wire [31:0]         x_info,
    output wire                x_ready,
    output wire                s_valid,
    output wire [WARP_W-1:0]   s_warp,
    output wire [GRP_W-1:0]    s_grp,
    output wire [6:0]          s_rd,
    output wire [NPHYS*32-1:0] s_data,
    output wire [NPHYS-1:0]    s_lanes,
    output reg                 wc_valid,
    output reg  [WARP_W-1:0]   wc_warp,
    output reg  [1:0]          wc_op,
    output reg  [15:0]         wc_pc,
    input  wire [WARP_W-1:0]   q_warp,
    output wire [31:0]         q_exec,
    output wire [31:0]         q_killed,
    input  wire                init_valid,
    input  wire [WARP_W-1:0]   init_warp,
    input  wire [31:0]         init_mask
);
    `include "ad_su_uop.vh"

    reg [31:0] exec_r   [0:NWARPS-1];
    reg [31:0] killed_r [0:NWARPS-1];
    reg [31:0] stage;                     // Booleans of the earlier groups

    assign x_ready  = 1'b1;
    assign q_exec   = exec_r[q_warp];
    assign q_killed = killed_r[q_warp];

    wire        mine = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_EXEC;
    wire [7:0]  op   = x_uop[AD_UOP_OP +: 8];

    // Booleans of this group, placed at its lanes
    wire [NPHYS-1:0] gb;
    genvar l;
    generate for (l = 0; l < NPHYS; l = l + 1) begin : g_b
        assign gb[l] = x_a[32*l +: 32] != 32'd0;
    end endgenerate
    wire [31:0] gpos = {{(32-NPHYS){1'b0}}, gb} << (x_grp * NPHYS);
    wire [31:0] bt   = (stage | gpos) & (x_uop[AD_UOP_USE1] ? 32'hFFFF_FFFF : 32'd0);

    wire [31:0] exec_w   = exec_r[x_warp];
    wire [31:0] killed_w = killed_r[x_warp];
    wire [31:0] exec_n, killed_n;
    wire        taken, wc;
    wire [1:0]  wcop;
    ad_ctl_exec_op u_op (
        .op(op), .bt(bt), .exec_i(exec_w), .killed_i(killed_w),
        .exec_o(exec_n), .killed_o(killed_n), .taken(taken), .wc(wc), .wc_op(wcop));

    integer w;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (w = 0; w < NWARPS; w = w + 1) begin exec_r[w] <= 32'd0; killed_r[w] <= 32'd0; end
            stage    <= 32'd0;
            wc_valid <= 1'b0;
            wc_warp  <= {WARP_W{1'b0}};
            wc_op    <= 2'd0;
            wc_pc    <= 16'd0;
        end else begin
            wc_valid <= mine && x_last && wc;
            if (mine && x_last) begin
                stage           <= 32'd0;
                exec_r[x_warp]   <= exec_n;
                killed_r[x_warp] <= killed_n;
                wc_warp <= x_warp;
                wc_op   <= wcop;
                wc_pc   <= taken ? x_pc + x_uop[AD_UOP_IMM +: 16] : x_pc + 16'd1;
            end else if (mine) stage <= stage | gpos;
            if (init_valid) begin
                exec_r[init_warp]   <= init_mask;
                killed_r[init_warp] <= 32'd0;
            end
        end
    end

    // exec.save: the short result
    wire             sv = mine && op == AD_EXEC_SAVE && x_uop[AD_UOP_WRD];
    wire [31:0]      eg = exec_w >> (x_grp * NPHYS);
    wire [NPHYS*32-1:0] sdat;
    generate for (l = 0; l < NPHYS; l = l + 1) begin : g_s
        assign sdat[32*l +: 32] = eg[l] ? 32'hFFFF_FFFF : 32'd0;
    end endgenerate

    ad_ctl_spipe #(.N(SHORT_LAT), .W(WARP_W + GRP_W + 7 + NPHYS*32 + NPHYS)) u_sp (
        .clk(clk), .rst_n(rst_n), .in_valid(sv),
        .in_data({x_warp, x_grp, x_uop[AD_UOP_RD +: 7], sdat, {NPHYS{1'b1}}}),
        .out_valid(s_valid), .out_data({s_warp, s_grp, s_rd, s_data, s_lanes}));

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, x_sbe, x_b, x_c, x_mask, x_info, x_uop};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
