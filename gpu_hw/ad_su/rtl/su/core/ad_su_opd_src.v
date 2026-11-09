// ad_su_opd_src -- the value of one operand for the NPHYS lanes of a group
// (combinational leaf of ad_su_opd; design §3.2, tools/gsi1model.py opv()):
// 0-62 the GPR word (already forwarded), 63 rq, 64-95 the constant word c0-c31,
// 96-127 the specials: 96 zero, 97 one (1.0), 98 onei (1), 99 half, 100 two, 101 mone
// (-1.0), 102 lane (grp*NPHYS + i), 103 warp (WARP_BASE + slot), 104 exec (the warp's
// EXEC word), 105 killed (Boolean of the lane's KILLED bit), 106-108 wgx/wgy/wgz,
// 109 lidx (= lidn in v0: q_info has no workgroup shape), 110 lidy 0, 111 lidz 0,
// 112 lidn (LID + lane), 113 prim 0, 114 front (Boolean), 115-117 nwgx/nwgy/nwgz,
// 118 oneh2 (0x3C003C00), 119 mask (coverage / sample mask), 120 qstat, 121 sastat,
// 122 qtag (0 without SA), 123-127 0.  Values are cut to LW bits (LW 32 except in
// formal harnesses).
module ad_su_opd_src #(
    parameter NPHYS     = 8,
    parameter WARP_W    = 2,
    parameter GRP_W     = 2,
    parameter LW        = 32,
    parameter WARP_BASE = 0
) (
    input  wire [6:0]          n,
    input  wire [NPHYS*LW-1:0] gpr,
    input  wire [NPHYS*LW-1:0] rq,
    input  wire [31:0]         cw,
    input  wire [WARP_W-1:0]   warp,
    input  wire [GRP_W-1:0]    grp,
    input  wire [159:0]        q_info,
    input  wire [31:0]         q_exec,
    input  wire [31:0]         q_killed,
    output reg  [NPHYS*LW-1:0] v
);
`include "ad_su_uop.vh"
    reg [31:0] u;          // the uniform value of a constant or special
    reg [31:0] w;
    reg [4:0]  ln;
    integer i;
    always @(*) begin
        case (n)
        7'd96:  u = 32'h0;
        7'd97:  u = 32'h3F800000;
        7'd98:  u = 32'h1;
        7'd99:  u = 32'h3F000000;
        7'd100: u = 32'h40000000;
        7'd101: u = 32'hBF800000;
        7'd103: u = WARP_BASE + {{(32-WARP_W){1'b0}}, warp};
        7'd104: u = q_exec;
        7'd106: u = {16'd0, q_info[AD_WI_WGX +: 16]};
        7'd107: u = {16'd0, q_info[AD_WI_WGX + 16 +: 16]};
        7'd108: u = {16'd0, q_info[AD_WI_WGX + 32 +: 16]};
        7'd114: u = {32{q_info[AD_WI_FRONT]}};
        7'd115: u = {16'd0, q_info[AD_WI_NWGX +: 16]};
        7'd116: u = {16'd0, q_info[AD_WI_NWGX + 16 +: 16]};
        7'd117: u = {16'd0, q_info[AD_WI_NWGX + 32 +: 16]};
        7'd118: u = 32'h3C003C00;
        7'd119: u = q_info[AD_WI_MASK +: 32];
        default: u = (n >= 7'd64 && n < 7'd96) ? cw : 32'h0;
        endcase
        for (i = 0; i < NPHYS; i = i + 1) begin
            ln = grp * NPHYS + i;
            case (n)
            7'd102: w = {27'd0, ln};
            7'd105: w = {32{q_killed[ln]}};
            7'd109, 7'd112: w = {24'd0, q_info[AD_WI_LID +: 8]} + {27'd0, ln};
            default: w = u;
            endcase
            if (n < 7'd63)       v[LW*i +: LW] = gpr[LW*i +: LW];
            else if (n == 7'd63) v[LW*i +: LW] = rq[LW*i +: LW];
            else                 v[LW*i +: LW] = w[LW-1:0];
        end
    end
endmodule
