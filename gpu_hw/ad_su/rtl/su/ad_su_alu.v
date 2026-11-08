// ad_su_alu -- the SU's integer ALU, NPHYS lanes (spec/gpu/su/ad_su_alu.md).
// The lanes (ad_su_alu_lane) are combinational before the first of the SHORT_LAT
// stages of ad_su_spipe; s_* comes exactly SHORT_LAT cycles after the group was
// taken.  Forwarding taps fw4_* / fw5_* (stages SHORT_LAT-2 / SHORT_LAT-1) feed
// ad_su_opd's forwarding network; valid only for WRD uops with rd < 63.
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module ad_su_alu #(
    parameter NPHYS     = 8,
    parameter NWARPS    = 4,
    parameter WARP_W    = 2,
    parameter GRP_W     = 2,
    parameter SBE_W     = 2,
    parameter UOP_W     = 108,
    parameter SHORT_LAT = 6
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  x_valid,
    input  wire [WARP_W-1:0]     x_warp,
    input  wire [GRP_W-1:0]      x_grp,
    input  wire                  x_last,
    input  wire [SBE_W:0]        x_sbe,
    input  wire [15:0]           x_pc,
    input  wire [UOP_W-1:0]      x_uop,
    input  wire [NPHYS*32-1:0]   x_a,
    input  wire [NPHYS*32-1:0]   x_b,
    input  wire [NPHYS*32-1:0]   x_c,
    input  wire [2*NPHYS-1:0]    x_mask,
    input  wire [31:0]           x_info,
    output wire                  x_ready,
    output wire                  s_valid,
    output wire [WARP_W-1:0]     s_warp,
    output wire [GRP_W-1:0]      s_grp,
    output wire [6:0]            s_rd,
    output wire [NPHYS*32-1:0]   s_data,
    output wire [NPHYS-1:0]      s_lanes,
    output wire                  fw4_valid,
    output wire [WARP_W-1:0]     fw4_warp,
    output wire [GRP_W-1:0]      fw4_grp,
    output wire [6:0]            fw4_rd,
    output wire [NPHYS*32-1:0]   fw4_data,
    output wire [NPHYS-1:0]      fw4_lanes,
    output wire                  fw5_valid,
    output wire [WARP_W-1:0]     fw5_warp,
    output wire [GRP_W-1:0]      fw5_grp,
    output wire [6:0]            fw5_rd,
    output wire [NPHYS*32-1:0]   fw5_data,
    output wire [NPHYS-1:0]      fw5_lanes
);
`include "ad_su_uop.vh"
    assign x_ready = 1'b1;
    wire [7:0]  op   = x_uop[AD_UOP_OP +: 8];
    wire [31:0] imm  = x_uop[AD_UOP_IMM +: 32];
    wire        mine = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_ALU;
    wire [NPHYS*32-1:0] r;
    genvar i;
    generate
        for (i = 0; i < NPHYS; i = i + 1) begin : lane
            ad_su_alu_lane u (
                .op(op[4:0]), .a(x_a[32*i +: 32]),
                .b(op[AD_ALU_IMMB] ? imm : x_b[32*i +: 32]),
                .c(x_c[32*i +: 32]), .imm(imm), .r(r[32*i +: 32]));
        end
    endgenerate
`ifdef MUT_ALU_LAT
    localparam NST = SHORT_LAT - 1;     // mutation: one cycle early
`else
    localparam NST = SHORT_LAT;
`endif
    ad_su_spipe #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .N(NST)) pl (
        .clk(clk), .rst_n(rst_n),
        .in_valid(mine && x_uop[AD_UOP_WRD]), .in_warp(x_warp), .in_grp(x_grp),
        .in_rd(x_uop[AD_UOP_RD +: 7]), .in_data(r), .in_lanes(x_mask[NPHYS-1:0]),
        .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd), .s_data(s_data),
        .s_lanes(s_lanes),
        .fw4_valid(fw4_valid), .fw4_warp(fw4_warp), .fw4_grp(fw4_grp), .fw4_rd(fw4_rd),
        .fw4_data(fw4_data), .fw4_lanes(fw4_lanes),
        .fw5_valid(fw5_valid), .fw5_warp(fw5_warp), .fw5_grp(fw5_grp), .fw5_rd(fw5_rd),
        .fw5_data(fw5_data), .fw5_lanes(fw5_lanes));
endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
