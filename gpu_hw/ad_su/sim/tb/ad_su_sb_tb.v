// ad_su_sb_tb -- self-checking TB of ad_su_sb (spec §8 and §10).
// The TB is the decoder (u_*, held until u_ready), ad_su_opd (i_ready, and
// x_end for each issued instruction in order after a delay), ad_su_wb
// (rel_*) and checks feedback, issue, entries, counters, fault, wake and
// warp_ready.  Directed sections per spec §8 plus .interlock (the short-
// result interlock of §10, wb_stall).  The hazard rules over all uops are
// proved in formal/ad_su_sb.
`timescale 1ns/1ps
module ad_su_sb_tb;
    parameter NPHYS = 8;
    localparam NWARPS = 4, WARP_W = 2, NE = 4, SBE_W = 2, SHORT_LAT = 6, G = 32 / NPHYS;
    `include "ad_su_uop.vh"
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg                 u_valid = 0;
    reg  [WARP_W-1:0]   u_warp = 0;
    reg  [15:0]         u_pc = 0;
    reg  [AD_UOP_W-1:0] u_uop = 0;
    reg                 i_ready = 1;
    reg                 rel_valid = 0;
    reg  [WARP_W-1:0]   rel_warp = 0;
    reg  [SBE_W:0]      rel_sbe = 0;
    reg  [2:0]          rel_cls = 0;
    reg                 wb_stall = 0, rq_empty = 1, rq_full = 1, x_end = 0;
    wire u_ready, i_valid, fb_valid, busy, fault;
    wire [WARP_W-1:0] i_warp, fb_warp;
    wire [15:0] i_pc, fault_pc;
    wire [AD_UOP_W-1:0] i_uop;
    wire [SBE_W:0] i_sbe;
    wire [1:0] fb_kind;
    wire [NWARPS-1:0] wake, warp_ready;

    ad_su_sb #(.NWARPS(NWARPS), .WARP_W(WARP_W), .SB_ENTRIES(NE), .SBE_W(SBE_W), .UOP_W(AD_UOP_W),
               .NPHYS(NPHYS), .SHORT_LAT(SHORT_LAT)) dut (.*);

    integer errors = 0, cyc = 0, seed = 21;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- the opd model: x_end for issued instructions, in order, after xd cycles
    integer xq_due [0:255];
    integer xqh = 0, xqt = 0, xdel = 3;
    always @(posedge clk) begin
        if (rst_n && i_valid && i_ready) begin
            xq_due[xqt % 256] = cyc + xdel;
            if (xqt != xqh && xq_due[xqt % 256] <= xq_due[(xqt + 255) % 256]) xq_due[xqt % 256] = xq_due[(xqt + 255) % 256] + 1;
            xqt = xqt + 1;
        end
    end
    always @(negedge clk) begin
        x_end = 0;
        if (xqh != xqt && xq_due[xqh % 256] <= cyc) begin x_end = 1; xqh = xqh + 1; end
    end

    // ---- uop builders
    function [AD_UOP_W-1:0] mk(input [3:0] unit, input [7:0] op, input [2:0] cls, input [2:0] ndst,
                              input [6:0] rd, input wrd, input [6:0] r1, input u1, input [6:0] r2, input u2,
                              input [6:0] r3, input u3);
        begin
            mk = 0;
            mk[AD_UOP_UNIT +: 4] = unit; mk[AD_UOP_OP +: 8] = op; mk[AD_UOP_CLS +: 3] = cls;
            mk[AD_UOP_NDST +: 3] = ndst; mk[AD_UOP_RD +: 7] = rd; mk[AD_UOP_WRD] = wrd;
            mk[AD_UOP_RS1 +: 7] = r1; mk[AD_UOP_USE1] = u1; mk[AD_UOP_RS2 +: 7] = r2; mk[AD_UOP_USE2] = u2;
            mk[AD_UOP_RS3 +: 7] = r3; mk[AD_UOP_USE3] = u3;
        end
    endfunction
    function [AD_UOP_W-1:0] alu(input [6:0] rd, input [6:0] a, input [6:0] b);
        alu = mk(AD_UNIT_ALU, 0, AD_CLS_A, 1, rd, 1, a, 1, b, 1, 0, 0);
    endfunction
    function [AD_UOP_W-1:0] lw(input [6:0] rd, input [6:0] a);
        lw = mk(AD_UNIT_LSU, AD_LSU_LW, AD_CLS_M, 1, rd, 1, a, 1, 0, 0, 0, 0);
    endfunction
    function [AD_UOP_W-1:0] sw(input [6:0] a, input [6:0] b);
        sw = mk(AD_UNIT_LSU, AD_LSU_SW, AD_CLS_M, 0, 0, 0, a, 1, b, 1, 0, 0);
    endfunction
    function [AD_UOP_W-1:0] texl(input [6:0] rd, input [6:0] a);
        begin texl = mk(AD_UNIT_TEX, AD_TEX_TEXL, AD_CLS_T, 4, rd, 1, a, 1, 0, 0, 0, 0); texl[AD_UOP_PAIR] = 1; end
    endfunction
    function [AD_UOP_W-1:0] rcp(input [6:0] rd, input [6:0] a);
        rcp = mk(AD_UNIT_XU, AD_XU_RCP, AD_CLS_X, 1, rd, 1, a, 1, 0, 0, 0, 0);
    endfunction
    function [AD_UOP_W-1:0] waitu(input [3:0] m, input [3:0] t, input [3:0] x);
        begin waitu = mk(AD_UNIT_CTL, AD_CTL_WAIT, AD_CLS_A, 0, 0, 0, 0, 0, 0, 0, 0, 0);
              waitu[AD_UOP_IMM +: 12] = {x, t, m}; end
    endfunction

    // ---- send one uop: returns fb kind, issued flag, sbe
    reg [1:0] r_kind; reg r_iss; reg [SBE_W:0] r_sbe; integer r_wait;
    task send(input [WARP_W-1:0] w, input [15:0] pc, input [AD_UOP_W-1:0] uop);
        begin
            @(negedge clk);
            u_valid = 1; u_warp = w; u_pc = pc; u_uop = uop; r_wait = 0;
            #1;
            while (!u_ready) begin @(negedge clk); r_wait = r_wait + 1; #1; if (r_wait > 500) begin
                $display("FAIL ad_su_sb: hang pc %0d", pc); errors = errors + 1; disable send; end end
            if (!fb_valid || fb_warp !== w) begin $display("FAIL ad_su_sb: no feedback pc %0d", pc); errors = errors + 1; end
            if (i_valid && (i_warp !== w || i_pc !== pc || i_uop !== uop)) begin
                $display("FAIL ad_su_sb: issue payload"); errors = errors + 1; end
            r_kind = fb_kind; r_iss = i_valid && i_ready; r_sbe = i_sbe;
            @(posedge clk); #1;
            u_valid = 0;
        end
    endtask
    task chk(input [1:0] kind, input iss, input [8*40-1:0] what);
        if (r_kind !== kind || r_iss !== iss) begin
            $display("FAIL ad_su_sb: %0s: kind %0d issued %0d (exp %0d %0d)", what, r_kind, r_iss, kind, iss);
            errors = errors + 1;
        end
    endtask
    task rel_one(input [WARP_W-1:0] w, input [SBE_W:0] e, input [2:0] c);
        begin
            @(negedge clk); rel_valid = 1; rel_warp = w; rel_sbe = e; rel_cls = c;
            #1; if (wake !== (1 << w)) begin $display("FAIL ad_su_sb: wake"); errors = errors + 1; end
            @(negedge clk); rel_valid = 0;
        end
    endtask
    task idle(input integer n); repeat (n) @(negedge clk); endtask

    reg [SBE_W:0] e1, e2, e3, e4s;
    integer e0, i, j, n;
    reg [6:0] ra;
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        // ---------------- raw
        e0 = errors;
        send(0, 10, lw(5, 1)); chk(0, 1, "lw"); e1 = r_sbe;
        if (warp_ready[0] !== 0 || warp_ready[1] !== 1) begin $display("FAIL ad_su_sb.raw: warp_ready"); errors = errors + 1; end
        if (!busy) begin $display("FAIL ad_su_sb.raw: busy"); errors = errors + 1; end
        idle(12);
        send(0, 11, alu(6, 5, 1)); chk(2, 0, "raw read");
        send(0, 11, alu(6, 1, 5)); chk(2, 0, "raw read rs2");
        send(0, 11, alu(5, 1, 2)); chk(2, 0, "waw short over long");
        send(1, 11, alu(6, 5, 1)); chk(0, 1, "other warp");
        send(0, 11, alu(6, 4, 7)); chk(0, 1, "independent");
        idle(12);
        rel_one(0, e1, AD_CLS_M);
        if (warp_ready[0] !== 1 || busy) begin $display("FAIL ad_su_sb.raw: after release"); errors = errors + 1; end
        send(0, 11, alu(6, 5, 1)); chk(0, 1, "raw after release");
        // release in the same cycle as the check (release before allocate)
        idle(12);
        send(0, 12, lw(5, 1)); e1 = r_sbe;
        @(negedge clk); u_valid = 1; u_warp = 0; u_pc = 13; u_uop = alu(7, 5, 5);
        rel_valid = 1; rel_warp = 0; rel_sbe = e1; rel_cls = AD_CLS_M; #1;
        if (!(u_ready && i_valid && fb_kind == 0)) begin $display("FAIL ad_su_sb.raw: release-before-check"); errors = errors + 1; end
        @(negedge clk); rel_valid = 0; u_valid = 0;
        idle(12);
        if (errors == e0) $display("PASS ad_su_sb.raw");
        // ---------------- waw
        e0 = errors;
        send(1, 20, texl(8, 2)); chk(0, 1, "texl"); e1 = r_sbe;
        for (i = 6; i < 14; i = i + 1) begin
            send(1, 21, alu(i, 1, 2)); chk((i >= 8 && i <= 11) ? 2 : 0, !(i >= 8 && i <= 11), "waw rd");
            idle(10);
        end
        send(1, 22, lw(6, 1)); chk(0, 1, "lw r6 (below)"); e2 = r_sbe;
        send(1, 23, lw(7, 6)); chk(2, 0, "lw reading pending r6");
        idle(4);
        // texture .3.c: rs1 5, rs1+1 6, rs3 = rs1+2 = 7, rs3+1 = 8 (pending)
        u_uop = mk(AD_UNIT_TEX, AD_TEX_TEXL | (1 << AD_TEX_CFORM), AD_CLS_T, 4, 20, 1, 3, 1, 0, 0, 7, 1);
        u_uop[AD_UOP_PAIR] = 1; u_uop[AD_UOP_SUB + 4] = 1;
        send(1, 24, u_uop); chk(2, 0, ".3.c rs3+1 pending");
        u_uop[AD_UOP_SUB + 4] = 0;
        send(1, 25, u_uop); chk(0, 1, ".c without .3 issues"); e3 = r_sbe;
        u_uop[AD_UOP_SUB + 4] = 1; u_uop[AD_UOP_OP + AD_TEX_CFORM] = 0;
        send(1, 26, u_uop); chk(2, 0, ".3 without .c: rd 20..23 pending (waw)");
        rel_one(1, e1, AD_CLS_T); rel_one(1, e2, AD_CLS_M); rel_one(1, e3, AD_CLS_T);
        idle(12);
        if (errors == e0) $display("PASS ad_su_sb.waw");
        // ---------------- full
        e0 = errors;
        send(2, 30, lw(1, 40)); e1 = r_sbe;
        send(2, 31, texl(4, 40)); e2 = r_sbe;
        send(2, 32, rcp(9, 40)); e3 = r_sbe;
        send(2, 33, lw(10, 40)); e4s = r_sbe;
        if ({e1, e2, e3, e4s} !== {3'd0, 3'd1, 3'd2, 3'd3}) begin $display("FAIL ad_su_sb.full: entries %0d %0d %0d %0d", e1, e2, e3, e4s); errors = errors + 1; end
        send(2, 34, lw(11, 40)); chk(2, 0, "no free entry");
        send(2, 35, sw(40, 41)); chk(0, 1, "store needs no entry");
        send(2, 36, alu(20, 40, 41)); chk(0, 1, "short issues");
        send(3, 37, lw(11, 40)); chk(0, 1, "other warp's long");
        if (r_sbe !== 0) begin $display("FAIL ad_su_sb.full: warp 3 entry"); errors = errors + 1; end
        e1 = r_sbe;
        rel_one(2, 3'd2, AD_CLS_X);
        send(2, 34, lw(11, 40)); chk(0, 1, "after release");
        if (r_sbe !== 2) begin $display("FAIL ad_su_sb.full: reuse entry 2"); errors = errors + 1; end
        rel_one(2, 0, AD_CLS_M); rel_one(2, 1, AD_CLS_T); rel_one(2, 2, AD_CLS_M); rel_one(2, 3, AD_CLS_M);
        rel_one(2, 3'b111, AD_CLS_M); rel_one(3, e1, AD_CLS_M);
        idle(12);
        if (busy) begin $display("FAIL ad_su_sb.full: busy after releases"); errors = errors + 1; end
        if (errors == e0) $display("PASS ad_su_sb.full");
        // ---------------- wait / fence / end
        e0 = errors;
        for (i = 0; i < 3; i = i + 1) begin send(0, 40, sw(1, 2)); chk(0, 1, "sw"); end
        send(0, 41, rcp(9, 1)); chk(0, 1, "rcp"); e1 = r_sbe;
        send(0, 42, waitu(1, 15, 15)); chk(2, 0, "wait cm<=1 with 3");
        rel_one(0, 3'b111, AD_CLS_M);
        send(0, 42, waitu(1, 15, 15)); chk(2, 0, "wait cm<=1 with 2");
        rel_one(0, 3'b111, AD_CLS_M);
        send(0, 42, waitu(1, 15, 15)); chk(0, 0, "wait satisfied: consumed");
        send(0, 43, waitu(15, 15, 0)); chk(2, 0, "wait cx 0");
        u_uop = mk(AD_UNIT_LSU, AD_LSU_FENCE, AD_CLS_A, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        send(0, 44, u_uop); chk(2, 0, "fence with cm 1");
        rel_one(0, 3'b111, AD_CLS_M);
        send(0, 44, u_uop); chk(0, 1, "fence issues");
        u_uop = mk(AD_UNIT_EXEC, AD_EXEC_END, AD_CLS_A, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        send(0, 45, u_uop); chk(2, 0, "end with cx 1");
        rel_one(0, e1, AD_CLS_X);
        send(0, 45, u_uop); chk(1, 1, "end issues, kind 1");
        send(0, 46, mk(AD_UNIT_NONE, 0, AD_CLS_A, 0, 0, 0, 0, 0, 0, 0, 0, 0)); chk(0, 0, "nop consumed");
        send(0, 47, mk(AD_UNIT_EXEC, AD_EXEC_BANY, AD_CLS_A, 0, 0, 0, 3, 1, 0, 0, 0, 0)); chk(1, 1, "branch kind 1");
        send(0, 48, mk(AD_UNIT_EXEC, AD_EXEC_SET, AD_CLS_A, 0, 0, 0, 3, 1, 0, 0, 0, 0)); chk(0, 1, "exec.set kind 0");
        // counter at 63: a long instruction replays
        for (i = 0; i < 63; i = i + 1) send(1, 49, sw(1, 2));
        send(1, 50, sw(1, 2)); chk(2, 0, "cm at 63");
        send(1, 51, waitu(15, 15, 15)); chk(2, 0, "wait cm 63 > 15");
        for (i = 0; i < 63; i = i + 1) rel_one(1, 3'b111, AD_CLS_M);
        idle(12);
        if (busy) begin $display("FAIL ad_su_sb.wait: busy"); errors = errors + 1; end
        if (errors == e0) $display("PASS ad_su_sb.wait");
        // ---------------- fault
        e0 = errors;
        u_uop = 0; u_uop[AD_UOP_ILL] = 1;
        send(3, 16'h1234, u_uop); chk(1, 0, "ILL kind 1, no issue");
        #1; if (!fault || fault_pc !== 16'h1234) begin $display("FAIL ad_su_sb.fault: pulse"); errors = errors + 1; end
        @(posedge clk); #1; if (fault) begin $display("FAIL ad_su_sb.fault: long pulse"); errors = errors + 1; end
        if (errors == e0) $display("PASS ad_su_sb.fault");
        // ---------------- interlock (spec §10)
        e0 = errors;
        xdel = 5;
        // writer r30 (short) then reader of r30: held until x_end, then until count <= G+1
        send(2, 60, alu(30, 1, 2));
        n = cyc;
        send(2, 61, alu(31, 30, 1)); chk(0, 1, "reader issues after the hold");
        // x_end at issue + xdel (+1), then SHORT_LAT+1 - (G+1) more cycles
        if (r_wait < xdel + SHORT_LAT + 1 - (G + 1) - 1 || r_wait > xdel + SHORT_LAT + 1 - (G + 1) + 2) begin
            $display("FAIL ad_su_sb.interlock: reader held %0d cycles", r_wait); errors = errors + 1; end
        if (r_wait == 0) begin $display("FAIL ad_su_sb.interlock: not held"); errors = errors + 1; end
        // other warp is not held; a long writer of the rd waits for the count's end
        send(2, 62, alu(30, 1, 2));
        send(3, 63, alu(31, 30, 1)); chk(0, 1, "other warp");
        if (r_wait != 0) begin $display("FAIL ad_su_sb.interlock: other warp held"); errors = errors + 1; end
        send(2, 64, lw(30, 1)); e1 = r_sbe;
        if (r_wait < xdel + SHORT_LAT) begin $display("FAIL ad_su_sb.interlock: long writer held only %0d", r_wait); errors = errors + 1; end
        rel_one(2, e1, AD_CLS_M);
        // wb_stall holds an issue but not a replay
        @(negedge clk); wb_stall = 1; u_valid = 1; u_warp = 1; u_uop = alu(3, 1, 2); #1;
        if (u_ready || i_valid) begin $display("FAIL ad_su_sb.interlock: wb_stall"); errors = errors + 1; end
        @(negedge clk); wb_stall = 0; #1;
        if (!u_ready) begin $display("FAIL ad_su_sb.interlock: after wb_stall"); errors = errors + 1; end
        @(negedge clk); u_valid = 0;
        idle(20);
        if (errors == e0) $display("PASS ad_su_sb.interlock");
        if (errors == 0) $display("PASS ad_su_sb");
        else $display("FAIL ad_su_sb: %0d errors", errors);
        $finish;
    end
endmodule
