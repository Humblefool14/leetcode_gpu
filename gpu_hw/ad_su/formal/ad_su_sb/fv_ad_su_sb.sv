// fv_ad_su_sb -- formal harness of ad_su_sb (NWARPS 2, SB_ENTRIES 2, NPHYS 8,
// SHORT_LAT 2).  Every input is free except: the uop is held until u_ready.
// The release / x_end environment, the shadow of entries and counters and the
// properties "never issues a reader (or writer) of a pending long
// destination", "an allocation takes a free entry", "counters never
// underflow/overflow" are in the RTL under AD_SB_FV (they need the shadow
// next to the registers for the induction).  Here: exactly one fault, the
// cycle after, per consumed ILL uop, with its pc; an ILL uop is consumed at
// once with feedback 1 and not issued; wait/nop consumed are not issued.
module fv_ad_su_sb (
    input wire         clk,
    input wire         u_valid,
    input wire [0:0]   u_warp,
    input wire [15:0]  u_pc,
    input wire [107:0] u_uop,
    input wire         i_ready,
    input wire         rel_valid,
    input wire [0:0]   rel_warp,
    input wire [1:0]   rel_sbe,
    input wire [2:0]   rel_cls,
    input wire         wb_stall, rq_empty, rq_full, x_end
);
    `include "ad_su_uop.vh"
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire u_ready, i_valid, fb_valid, busy, fault;
    wire [0:0] i_warp, fb_warp;
    wire [15:0] i_pc, fault_pc;
    wire [107:0] i_uop;
    wire [1:0] i_sbe, fb_kind, wake, warp_ready;
    ad_su_sb #(.NWARPS(2), .WARP_W(1), .SB_ENTRIES(2), .SBE_W(1), .UOP_W(108), .NPHYS(8), .SHORT_LAT(2)) dut (
        .clk(clk), .rst_n(rst_n), .u_valid(u_valid), .u_ready(u_ready), .u_warp(u_warp), .u_pc(u_pc),
        .u_uop(u_uop), .i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp), .i_pc(i_pc), .i_uop(i_uop),
        .i_sbe(i_sbe), .fb_valid(fb_valid), .fb_warp(fb_warp), .fb_kind(fb_kind), .wake(wake),
        .warp_ready(warp_ready), .rel_valid(rel_valid), .rel_warp(rel_warp), .rel_sbe(rel_sbe),
        .rel_cls(rel_cls), .wb_stall(wb_stall), .rq_empty(rq_empty), .rq_full(rq_full), .x_end(x_end),
        .busy(busy), .fault(fault), .fault_pc(fault_pc));

    reg p_uv, p_ur; reg [0:0] p_w; reg [15:0] p_pc; reg [107:0] p_uop;
    always @(posedge clk) begin p_uv <= rst_n && u_valid; p_ur <= u_ready; p_w <= u_warp; p_pc <= u_pc; p_uop <= u_uop; end
    always @(*) if (rst_n) begin
        if (p_uv && !p_ur) assume (u_valid && u_warp == p_w && u_pc == p_pc && u_uop == p_uop);
    end else assume (!u_valid && !rel_valid && !x_end);

    reg p_ill; reg [15:0] p_illpc;
    always @(posedge clk) begin
        p_ill <= rst_n && u_valid && u_ready && u_uop[AD_UOP_ILL];
        p_illpc <= u_pc;
    end
    wire [3:0] unit = u_uop[AD_UOP_UNIT +: 4];
    always @(*) if (rst_n) begin
        a_fault: assert (fault == p_ill);
        if (fault) a_fault_pc: assert (fault_pc == p_illpc);
        if (u_valid && u_uop[AD_UOP_ILL]) a_ill_taken: assert (u_ready && fb_valid && fb_kind == 2'd1 && !i_valid);
        if (u_valid && !u_uop[AD_UOP_ILL] && (unit == AD_UNIT_NONE || (unit == AD_UNIT_CTL && u_uop[AD_UOP_OP +: 8] == AD_CTL_WAIT))) a_nop: assert (!i_valid);
        a_fb: assert (fb_valid == (u_valid && u_ready));
        if (i_valid) a_iv: assert (u_valid);
    end
endmodule
