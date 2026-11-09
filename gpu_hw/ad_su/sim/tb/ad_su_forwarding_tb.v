// ad_su_forwarding_tb -- ad_su_opd's forwarding network in a loop: ad_su_opd ->
// ad_su_alu / ad_su_fpu -> ad_su_wb -> ad_su_rf (RF writes also on fwd_wb_*, the units'
// fw4_/fw5_ taps on fwd_alu_*/fwd_fpu_*), NPHYS 4, 8, 16 and 32.  The RF is first
// filled with random words through the VF input port.  Then dense dependent chains of
// ALU ops (sel takes two read slots) and FPU integer multiplies (mul, mulh, mulhsu,
// mulhu) on r0-r7 of two warps; EXEC (q_exec) changes at random every cycle, so the
// groups write partial lane sets.  Every group taken on the bus is checked against a
// sequential model (operand values per lane = all older groups applied).
// Phase 1 (no back-pressure): an instruction issues as soon as each of its groups lands
// at least 5 cycles after its producer's (the EX4 tap): for NPHYS 4 dependents go
// back to back.  Phase 2: random unit_ready back-pressure (replayed reads), a dependent
// issues max(0, 4 - 32/NPHYS) cycles after its producer's last group was taken.
//  .b2b   operands right with dependents at the minimum distance (forwarded from EX4)
//  .prio  lanes where two or more writers matched (EX4 over EX5 over WB over bypass); this
//         happens at NPHYS 16 and 32 only: with 4 or more groups an instruction is too long
//         for two writers of one register to sit in EX4..bypass together (the leaf proof
//         formal/ad_core_fwd_sel covers the order exhaustively)
//  .lanes partial lane masks: forwarded and RF words in one group
`timescale 1ns/1ps
module fwd_h #(parameter NPHYS = 8, parameter SEED = 1, parameter NINS = 1000) (
    input wire clk, input wire rst_n, output reg done, output reg [31:0] err,
    output reg [31:0] n_ex4, output reg [31:0] n_multi, output reg [31:0] n_part, output reg [31:0] n_b2b,
    output reg [31:0] n_chk
);
`include "ad_su_uop.vh"
    localparam G = 32 / NPHYS, GRP_W = (G > 1) ? $clog2(G) : 1, WARP_W = 2, DW = NPHYS * 32;
    // ---------------- the loop ----------------
    reg i_valid = 0; wire i_ready; reg [1:0] i_warp = 0; reg [107:0] i_uop = 0;
    wire r_en; wire [1:0] r_warp, q_warp; wire [GRP_W-1:0] r_grp; wire [5:0] r_reg1, r_reg2; wire [DW-1:0] r_data1, r_data2;
    wire x_valid, x_last; wire [1:0] x_warp; wire [GRP_W-1:0] x_grp; wire [2:0] x_sbe; wire [15:0] x_pc; wire [107:0] x_uop;
    wire [DW-1:0] x_a, x_b, x_c; wire [2*NPHYS-1:0] x_mask; wire [31:0] x_info; wire cr_en, rq_pop; wire [14:0] cr_idx;
    reg [15:0] ur = 16'hFFFF; wire a_rdy, f_rdy;
    wire [15:0] unit_ready = ur & ~(16'd1 << AD_UNIT_ALU) & ~(16'd1 << AD_UNIT_FPU) |
                             ((ur[AD_UNIT_ALU] & a_rdy) << AD_UNIT_ALU) | ((ur[AD_UNIT_FPU] & f_rdy) << AD_UNIT_FPU);
    wire x_take = x_valid && unit_ready[x_uop[AD_UOP_UNIT +: 4]];
    reg [31:0] qe [0:3];
    wire a4v, a5v, f4v, f5v, asv, fsv; wire [1:0] a4w, a5w, f4w, f5w, asw, fsw; wire [GRP_W-1:0] a4g, a5g, f4g, f5g, asg, fsg;
    wire [6:0] a4r, a5r, f4r, f5r, asr, fsr; wire [DW-1:0] a4d, a5d, f4d, f5d, asd, fsd; wire [NPHYS-1:0] a4l, a5l, f4l, f5l, asl, fsl;
    wire w_en; wire [1:0] w_warp; wire [GRP_W-1:0] w_grp; wire [5:0] w_reg; wire [DW-1:0] w_data; wire [NPHYS-1:0] w_lanes;
    reg in_we = 0; reg [1:0] in_warp = 0; reg [5:0] in_reg = 0; reg [4:0] in_lane = 0; reg [31:0] in_data = 0;
    ad_su_opd #(.NPHYS(NPHYS), .WARP_W(2), .GRP_W(GRP_W)) opd (
        .clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp), .i_pc(16'd0), .i_uop(i_uop),
        .i_sbe(3'd7), .r_en(r_en), .r_warp(r_warp), .r_grp(r_grp), .r_reg1(r_reg1), .r_reg2(r_reg2),
        .r_data1(r_data1), .r_data2(r_data2), .cr_en(cr_en), .cr_idx(cr_idx), .cr_data(96'd0),
        .q_warp(q_warp), .q_info(160'd0), .q_exec(qe[q_warp]), .q_killed(32'd0), .rq_pop(rq_pop), .rq_data({DW{1'b0}}),
        .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop),
        .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask), .x_info(x_info), .unit_ready(unit_ready),
        .fwd_alu_ex4_valid(a4v), .fwd_alu_ex4_warp(a4w), .fwd_alu_ex4_grp(a4g), .fwd_alu_ex4_rd(a4r), .fwd_alu_ex4_data(a4d), .fwd_alu_ex4_lanes(a4l),
        .fwd_alu_ex5_valid(a5v), .fwd_alu_ex5_warp(a5w), .fwd_alu_ex5_grp(a5g), .fwd_alu_ex5_rd(a5r), .fwd_alu_ex5_data(a5d), .fwd_alu_ex5_lanes(a5l),
        .fwd_fpu_ex4_valid(f4v), .fwd_fpu_ex4_warp(f4w), .fwd_fpu_ex4_grp(f4g), .fwd_fpu_ex4_rd(f4r), .fwd_fpu_ex4_data(f4d), .fwd_fpu_ex4_lanes(f4l),
        .fwd_fpu_ex5_valid(f5v), .fwd_fpu_ex5_warp(f5w), .fwd_fpu_ex5_grp(f5g), .fwd_fpu_ex5_rd(f5r), .fwd_fpu_ex5_data(f5d), .fwd_fpu_ex5_lanes(f5l),
        .fwd_wb_valid(w_en), .fwd_wb_warp(w_warp), .fwd_wb_grp(w_grp), .fwd_wb_rd({1'b0, w_reg}), .fwd_wb_data(w_data), .fwd_wb_lanes(w_lanes));
    ad_su_alu #(.NPHYS(NPHYS), .WARP_W(2), .GRP_W(GRP_W)) alu (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid && unit_ready[AD_UNIT_ALU]), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask), .x_info(x_info),
        .x_ready(a_rdy), .s_valid(asv), .s_warp(asw), .s_grp(asg), .s_rd(asr), .s_data(asd), .s_lanes(asl),
        .fw4_valid(a4v), .fw4_warp(a4w), .fw4_grp(a4g), .fw4_rd(a4r), .fw4_data(a4d), .fw4_lanes(a4l),
        .fw5_valid(a5v), .fw5_warp(a5w), .fw5_grp(a5g), .fw5_rd(a5r), .fw5_data(a5d), .fw5_lanes(a5l));
    ad_su_fpu #(.NPHYS(NPHYS), .WARP_W(2), .GRP_W(GRP_W)) fpu (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid && unit_ready[AD_UNIT_FPU]), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask), .x_info(x_info),
        .x_ready(f_rdy), .s_valid(fsv), .s_warp(fsw), .s_grp(fsg), .s_rd(fsr), .s_data(fsd), .s_lanes(fsl),
        .fw4_valid(f4v), .fw4_warp(f4w), .fw4_grp(f4g), .fw4_rd(f4r), .fw4_data(f4d), .fw4_lanes(f4l),
        .fw5_valid(f5v), .fw5_warp(f5w), .fw5_grp(f5g), .fw5_rd(f5r), .fw5_data(f5d), .fw5_lanes(f5l));
    ad_su_wb #(.NPHYS(NPHYS), .WARP_W(2), .GRP_W(GRP_W), .SBE_W(2)) wb (
        .clk(clk), .rst_n(rst_n), .s_valid({4'd0, fsv, asv}), .s_warp({8'd0, fsw, asw}), .s_grp({{(4*GRP_W){1'b0}}, fsg, asg}),
        .s_rd({28'd0, fsr, asr}), .s_data({{(4*DW){1'b0}}, fsd, asd}), .s_lanes({{(4*NPHYS){1'b0}}, fsl, asl}),
        .l_valid(6'd0), .l_ready(), .l_warp(12'd0), .l_grp({(6*GRP_W){1'b0}}), .l_rd(42'd0), .l_data({(6*DW){1'b0}}),
        .l_lanes({(6*NPHYS){1'b0}}), .l_wr(6'd0), .l_last(6'd0), .l_sbe(18'd0), .l_cls(18'd0),
        .in_we({1'b0, in_we}), .in_warp({2'd0, in_warp}), .in_reg({6'd0, in_reg}), .in_lane({5'd0, in_lane}), .in_data({32'd0, in_data}),
        .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg), .w_data(w_data), .w_lanes(w_lanes),
        .rel_valid(), .rel_warp(), .rel_sbe(), .rel_cls(), .rq_push(), .rq_data(), .wb_stall());
    ad_su_rf #(.NPHYS(NPHYS), .NWARPS(4), .WARP_W(2), .GRP_W(GRP_W), .NREGS(32)) rf (
        .clk(clk), .rst_n(rst_n), .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg), .w_data(w_data), .w_lanes(w_lanes),
        .r_en(r_en), .r_warp(r_warp), .r_grp(r_grp), .r_reg1(r_reg1), .r_reg2(r_reg2), .r_data1(r_data1), .r_data2(r_data2),
        .scrub(1'b0), .scrub_busy());
    // ---------------- model ----------------
    reg [31:0] m [0:2*8*32-1];        // warps 0-1, r0-r7, 32 lanes
    function [31:0] aref(input [7:0] op, input [31:0] a, input [31:0] b0, input [31:0] c, input [31:0] imm);
        reg [31:0] b;
        begin
            b = op[7] ? imm : b0;
            case (op[4:0])
            0: aref = a + b;  1: aref = a - b;  2: aref = a << b[4:0];
            3: aref = ($signed(a) < $signed(b)) ? 32'hFFFFFFFF : 0;  4: aref = (a < b) ? 32'hFFFFFFFF : 0;
            5: aref = a ^ b;  6: aref = a >> b[4:0];  7: aref = $signed(a) >>> b[4:0];
            8: aref = a | b;  9: aref = a & b;
            10: aref = ($signed(a) < $signed(b)) ? a : b;  11: aref = ($signed(a) < $signed(b)) ? b : a;
            12: aref = (a < b) ? a : b;  13: aref = (a < b) ? b : a;
            14: aref = a & ~b; 15: aref = a | ~b; 16: aref = ~(a ^ b); 17: aref = (a & b) | (~a & c); 18: aref = imm;
            default: aref = 0;
            endcase
        end
    endfunction
    function [31:0] fref(input [7:0] op, input [31:0] a, input [31:0] b);
        reg [63:0] p;
        begin
            case (op)
            20: p = a * b;
            21: p = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
            22: p = $signed({{32{a[31]}}, a}) * $signed({32'd0, b});
            default: p = {32'd0, a} * {32'd0, b};
            endcase
            fref = (op == 20) ? p[31:0] : p[63:32];
        end
    endfunction
    function [31:0] mv(input [6:0] n, input integer w, input integer lane);
        mv = (n < 8) ? m[(w * 8 + n) * 32 + lane] : (n == 102) ? lane : (n == 98) ? 1 : 0;
    endfunction
    // dependency bookkeeping per (warp, reg): acceptance cycle, read slots, last-group take cycle
    integer pa [0:15]; integer ps [0:15]; integer pt [0:15]; integer pid [0:15];
    integer acc_id [0:63]; integer nacc = 0, ntk = 0;
    integer cyc = 0, seed, ins = 0, phase = 0, fill = 0, i, k, ln, o, w;
    reg [107:0] u; reg [6:0] n [0:2]; reg [31:0] e, gv, res;
    integer last_acc = -10, uw = 0; reg [6:0] last_rd = 0; reg have_u = 0; reg [5:0] mm; integer mo;
    function integer slots(input [107:0] uu);
        slots = (uu[AD_UOP_USE1] && uu[AD_UOP_RS1 +: 7] < 63 && uu[AD_UOP_USE2] && uu[AD_UOP_RS2 +: 7] < 63 &&
                 uu[AD_UOP_USE3] && uu[AD_UOP_RS3 +: 7] < 63) ? 2 : 1;
    endfunction
    task gen;
        reg [3:0] unit; reg [7:0] op;
        begin
            u = 0;
            if ({$random(seed)} % 5 == 0) begin
                unit = AD_UNIT_FPU; op = 20 + {$random(seed)} % 4;
                u[AD_UOP_USE1] = 1; u[AD_UOP_USE2] = 1;
            end else begin
                unit = AD_UNIT_ALU; op = {$random(seed)} % 19;
                if (op != 17 && op != 18 && $random(seed) % 3 == 0) op = op | 8'h80;
                u[AD_UOP_USE1] = op != 18; u[AD_UOP_USE2] = !op[7] && op != 18; u[AD_UOP_USE3] = op == 17;
            end
            u[AD_UOP_UNIT +: 4] = unit; u[AD_UOP_OP +: 8] = op; u[AD_UOP_IMM +: 32] = $random(seed);
            // dense dependences: sources often the last destination, destinations mostly r0-r3
            for (k = 0; k < 3; k = k + 1) u[AD_UOP_RS1 + 7*k +: 7] = ($random(seed) % 12 == 0) ? (($random(seed) & 1) ? 102 : 98) :
                                                                   ($random(seed) % 2 == 0) ? last_rd : {$random(seed)} % 8;
            u[AD_UOP_RD +: 7] = ($random(seed) % 4 == 0) ? {$random(seed)} % 8 : {$random(seed)} % 4; u[AD_UOP_WRD] = $random(seed) % 10 != 0;
            last_rd = u[AD_UOP_RD +: 7];
        end
    endtask
    function ready_to_issue(input [107:0] uu, input integer wv, input integer now);
        integer kk, s, sc; reg [6:0] nn; reg r;
        begin
            r = 1; sc = slots(uu);
            for (kk = 0; kk < 3; kk = kk + 1) begin
                nn = uu[AD_UOP_RS1 + 7*kk +: 7];
                if (uu[AD_UOP_USE1 + kk] && nn < 8) begin
                    s = wv * 8 + nn;
                    if (pid[s] >= 0) begin
                        if (phase == 1) begin
                            if (now < pa[s] + 5 + ((ps[s] > sc) ? (ps[s] - sc) * G : 0)) r = 0;
                        end else begin
                            if (pt[s] < 0 || now < pt[s] + ((4 - G > 0) ? 4 - G : 0)) r = 0;
                        end
                    end
                end
            end
            ready_to_issue = r;
        end
    endfunction
    initial begin
        seed = SEED; done = 0; err = 0; n_ex4 = 0; n_multi = 0; n_part = 0; n_b2b = 0; n_chk = 0;
        for (i = 0; i < 2 * 8 * 32; i = i + 1) m[i] = $random(seed);
        for (i = 0; i < 16; i = i + 1) begin pid[i] = -1; pt[i] = -1; end
        for (i = 0; i < 4; i = i + 1) qe[i] = $random(seed);
    end
    always @(posedge clk) if (rst_n && !done) begin
        // ---------------- coverage of the forwarding muxes (B stage loading x) ----------------
        if (opd.x_load) begin
            for (mo = 0; mo < 2; mo = mo + 1) begin
                mm = mo ? opd.m2 : opd.m1;
                if (mm[1:0] != 0) n_ex4 = n_ex4 + 1;
                if ((mm & (mm - 1)) != 0) n_multi = n_multi + 1;
                for (k = 0; k < 6; k = k + 1) if (mm[k] && opd.f_lanes[NPHYS*k +: NPHYS] != {NPHYS{1'b1}}) n_part = n_part + 1;
            end
        end
        // ---------------- the group taken on the bus ----------------
        if (x_take) begin
            w = x_warp;
            n[0] = x_uop[AD_UOP_RS1 +: 7]; n[1] = x_uop[AD_UOP_RS2 +: 7]; n[2] = x_uop[AD_UOP_RS3 +: 7];
            for (ln = 0; ln < NPHYS; ln = ln + 1) begin
                for (o = 0; o < 3; o = o + 1) if (x_uop[AD_UOP_USE1 + o]) begin
                    e = mv(n[o], w, x_grp * NPHYS + ln);
                    gv = (o == 0) ? x_a[32*ln +: 32] : (o == 1) ? x_b[32*ln +: 32] : x_c[32*ln +: 32];
                    if (n[o] < 8) n_chk = n_chk + 1;
                    if (gv !== e) begin err = err + 1;
                        if (err < 6) $display("ERROR fwd%0d cyc %0d warp %0d grp %0d lane %0d operand %0d (r%0d) got %h exp %h", NPHYS, cyc, w, x_grp, ln, o, n[o], gv, e); end
                end
            end
            // apply the group to the model
            if (x_uop[AD_UOP_WRD]) for (ln = 0; ln < NPHYS; ln = ln + 1) if (x_mask[ln]) begin
                res = (x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_ALU) ?
                    aref(x_uop[AD_UOP_OP +: 8], x_a[32*ln +: 32], x_b[32*ln +: 32], x_c[32*ln +: 32], x_uop[AD_UOP_IMM +: 32]) :
                    fref(x_uop[AD_UOP_OP +: 8], x_a[32*ln +: 32], x_b[32*ln +: 32]);
                m[(w * 8 + x_uop[AD_UOP_RD +: 3]) * 32 + x_grp * NPHYS + ln] = res;
            end
            if (x_last) begin   // the producer's last group: record its take cycle
                for (k = 0; k < 16; k = k + 1) if (pid[k] == acc_id[ntk % 64]) pt[k] = cyc;
                ntk = ntk + 1;
            end
        end
        // ---------------- acceptance ----------------
        if (i_valid && i_ready) begin
            if (i_uop[AD_UOP_WRD]) begin
                k = i_warp * 8 + i_uop[AD_UOP_RD +: 3];
                pid[k] = ins; pa[k] = cyc; ps[k] = slots(i_uop); pt[k] = -1;
            end
            if (cyc == last_acc + slots(i_uop) * G || cyc == last_acc + G) n_b2b = n_b2b + 1;
            last_acc = cyc;
            acc_id[nacc % 64] = ins; nacc = nacc + 1; ins = ins + 1;
        end
        // ---------------- next cycle ----------------
        in_we <= 0;
        if (phase == 0) begin
            if (fill < 2 * 8 * 32) begin
                in_we <= 1; in_warp <= fill / 256; in_reg <= (fill / 32) % 8; in_lane <= fill % 32; in_data <= m[fill];
                fill = fill + 1;
            end else if (fill < 2 * 8 * 32 + 40) fill = fill + 1;
            else phase = 1;
        end else if (!i_valid || i_ready) begin
            // nothing waits on i_* (or it was taken now): present the next instruction once its
            // producers are far enough
            i_valid <= 0;
            if (ins >= NINS / 2 && phase == 1) phase = 2;
            if (ins < NINS) begin
                if (!have_u) begin gen; uw = $random(seed) & 1; have_u = 1; end
                if (ready_to_issue(u, uw, cyc + 1)) begin i_valid <= 1; i_uop <= u; i_warp <= uw; have_u = 0; end
            end
        end
        for (i = 0; i < 4; i = i + 1) qe[i] = $random(seed) | (($random(seed) % 4 == 0) ? 32'hFFFFFFFF : 32'h0);
        ur <= (phase == 2 && $random(seed) % 3 == 0) ? $random(seed) : 16'hFFFF;
        cyc = cyc + 1;
        if ((ins >= NINS && !i_valid && ntk == nacc && cyc > 100) || cyc > 300000) begin
            if (cyc > 300000) begin err = err + 1; $display("ERROR fwd%0d timeout", NPHYS); end
            done <= 1;
        end
    end
endmodule

module ad_su_forwarding_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire [3:0] d; wire [31:0] er [0:3], n4 [0:3], nm [0:3], np [0:3], nb [0:3], nc [0:3];
    fwd_h #(.NPHYS(4),  .SEED(71)) h0 (clk, rst_n, d[0], er[0], n4[0], nm[0], np[0], nb[0], nc[0]);
    fwd_h #(.NPHYS(8),  .SEED(72)) h1 (clk, rst_n, d[1], er[1], n4[1], nm[1], np[1], nb[1], nc[1]);
    fwd_h #(.NPHYS(16), .SEED(73)) h2 (clk, rst_n, d[2], er[2], n4[2], nm[2], np[2], nb[2], nc[2]);
    fwd_h #(.NPHYS(32), .SEED(74)) h3 (clk, rst_n, d[3], er[3], n4[3], nm[3], np[3], nb[3], nc[3]);
    integer k, te, t4, tm, tp, tb;
    initial begin
        repeat (3) @(posedge clk); rst_n <= 1;
        wait (&d); @(posedge clk);
        te = 0; t4 = 0; tm = 0; tp = 0; tb = 0;
        for (k = 0; k < 4; k = k + 1) begin
            te = te + er[k]; t4 = t4 + n4[k]; tm = tm + nm[k]; tp = tp + np[k]; tb = tb + nb[k];
            $display("fwd NPHYS %0d: %0d GPR operand lanes checked, %0d EX4 forwards, %0d multi-match, %0d partial-lane, %0d back-to-back issues",
                     4 << k, nc[k], n4[k], nm[k], np[k], nb[k]);
        end
        if (te == 0 && t4 > 500 && nb[0] > 100) $display("PASS ad_su_forwarding.b2b"); else $display("FAIL ad_su_forwarding.b2b (%0d)", te);
        if (te == 0 && tm > 40) $display("PASS ad_su_forwarding.prio"); else $display("FAIL ad_su_forwarding.prio");
        if (te == 0 && tp > 200) $display("PASS ad_su_forwarding.lanes"); else $display("FAIL ad_su_forwarding.lanes");
        if (te == 0 && t4 > 500 && tm > 40 && tp > 200) $display("PASS ad_su_forwarding");
        $finish;
    end
endmodule
