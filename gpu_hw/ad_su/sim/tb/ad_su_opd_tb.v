// ad_su_opd_tb -- ad_su_opd for NPHYS 4, 8, 16 and 32 against an in-TB reference: a
// model RF (static random contents, 1-cycle reads that hold), constant bank, rq (pop k
// gives a known word per lane), warp state q_info/q_exec/q_killed per warp (changed
// between epochs while the stage is empty), random unit_ready back-pressure.  Random
// uops: every unit, operand numbers 0-31 (GPR), 63 (rq), 64-95 (c0-c31), 96-127
// (specials), random USE/MOD bits, PAIR forms, PAIR + USE3 (texture .c/.3: two passes).
// At acceptance the reference computes every group (and pass) the bus must carry; each
// taken group is compared field by field.  Also: x_* stable while the unit is not
// ready; 2 cycles from i_valid to x_valid on an idle stage; the modifier leaf against
// sim/vec/core_fmod.hex (tools/gsi1model.py fmod).
`timescale 1ns/1ps
module opd_h #(parameter NPHYS = 8, parameter SEED = 1, parameter NINS = 1500) (
    input wire clk, input wire rst_n, output reg done,
    output reg [31:0] e_gpr, output reg [31:0] e_spec, output reg [31:0] e_mod, output reg [31:0] e_mask,
    output reg [31:0] e_p2, output reg [31:0] n_gpr, output reg [127:96] spec_seen, output reg [31:0] n_mod,
    output reg [31:0] n_stall, output reg [31:0] n_p2, output reg [31:0] n_lat2
);
`include "ad_su_uop.vh"
    localparam G = 32 / NPHYS, GRP_W = (G > 1) ? $clog2(G) : 1, WARP_W = 2, SBE_W = 2, DW = NPHYS * 32;
    // ---------------- DUT ----------------
    reg i_valid = 0; wire i_ready; reg [WARP_W-1:0] i_warp = 0; reg [15:0] i_pc = 0; reg [107:0] i_uop = 0; reg [SBE_W:0] i_sbe = 0;
    wire r_en, cr_en, rq_pop; wire [WARP_W-1:0] r_warp, q_warp; wire [GRP_W-1:0] r_grp; wire [5:0] r_reg1, r_reg2;
    reg [DW-1:0] r_data1 = 0, r_data2 = 0, rq_data = 0; wire [14:0] cr_idx; reg [95:0] cr_data = 0;
    wire x_valid, x_last; wire [WARP_W-1:0] x_warp; wire [GRP_W-1:0] x_grp; wire [SBE_W:0] x_sbe; wire [15:0] x_pc;
    wire [107:0] x_uop; wire [DW-1:0] x_a, x_b, x_c; wire [2*NPHYS-1:0] x_mask; wire [31:0] x_info;
    reg [15:0] unit_ready = 16'hFFFF;
    reg [159:0] qi [0:3]; reg [31:0] qe [0:3]; reg [31:0] qk [0:3];
    wire [DW-1:0] z = 0;
    ad_su_opd #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .WARP_BASE(8)) dut (
        .clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp), .i_pc(i_pc), .i_uop(i_uop),
        .i_sbe(i_sbe), .r_en(r_en), .r_warp(r_warp), .r_grp(r_grp), .r_reg1(r_reg1), .r_reg2(r_reg2),
        .r_data1(r_data1), .r_data2(r_data2), .cr_en(cr_en), .cr_idx(cr_idx), .cr_data(cr_data),
        .q_warp(q_warp), .q_info(qi[q_warp]), .q_exec(qe[q_warp]), .q_killed(qk[q_warp]),
        .rq_pop(rq_pop), .rq_data(rq_data), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(x_sbe), .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(x_info), .unit_ready(unit_ready),
        .fwd_alu_ex4_valid(1'b0), .fwd_alu_ex4_warp(2'd0), .fwd_alu_ex4_grp({GRP_W{1'b0}}), .fwd_alu_ex4_rd(7'd0), .fwd_alu_ex4_data(z), .fwd_alu_ex4_lanes({NPHYS{1'b0}}),
        .fwd_alu_ex5_valid(1'b0), .fwd_alu_ex5_warp(2'd0), .fwd_alu_ex5_grp({GRP_W{1'b0}}), .fwd_alu_ex5_rd(7'd0), .fwd_alu_ex5_data(z), .fwd_alu_ex5_lanes({NPHYS{1'b0}}),
        .fwd_fpu_ex4_valid(1'b0), .fwd_fpu_ex4_warp(2'd0), .fwd_fpu_ex4_grp({GRP_W{1'b0}}), .fwd_fpu_ex4_rd(7'd0), .fwd_fpu_ex4_data(z), .fwd_fpu_ex4_lanes({NPHYS{1'b0}}),
        .fwd_fpu_ex5_valid(1'b0), .fwd_fpu_ex5_warp(2'd0), .fwd_fpu_ex5_grp({GRP_W{1'b0}}), .fwd_fpu_ex5_rd(7'd0), .fwd_fpu_ex5_data(z), .fwd_fpu_ex5_lanes({NPHYS{1'b0}}),
        .fwd_wb_valid(1'b0), .fwd_wb_warp(2'd0), .fwd_wb_grp({GRP_W{1'b0}}), .fwd_wb_rd(7'd0), .fwd_wb_data(z), .fwd_wb_lanes({NPHYS{1'b0}}));
    // ---------------- models ----------------
    reg [31:0] rf [0:4*32*32-1];     // [warp][reg][lane]
    reg [31:0] cb [0:31];
    integer rq_cnt = 0;
    function [31:0] rqw(input integer k, input integer lane); rqw = 32'h5A000000 ^ (k << 8) ^ lane; endfunction
    integer i, k, seed;
    always @(posedge clk) begin
        if (r_en) for (i = 0; i < NPHYS; i = i + 1) begin
            r_data1[32*i +: 32] <= rf[(r_warp * 32 + r_reg1[4:0]) * 32 + r_grp * NPHYS + i];
            r_data2[32*i +: 32] <= rf[(r_warp * 32 + r_reg2[4:0]) * 32 + r_grp * NPHYS + i];
        end
        if (cr_en) cr_data <= {cb[cr_idx[14:10]], cb[cr_idx[9:5]], cb[cr_idx[4:0]]};
        if (rq_pop) begin for (i = 0; i < NPHYS; i = i + 1) rq_data[32*i +: 32] <= rqw(rq_cnt, i); rq_cnt = rq_cnt + 1; end
    end
    // ---------------- reference ----------------
    function [31:0] fmod1(input [3:0] unit, input ng, input ab, input [31:0] v);
        reg [31:0] m;
        begin
            m = (unit == AD_UNIT_FPU || unit == AD_UNIT_XU) ? 32'h80000000 : (unit == AD_UNIT_PK) ? 32'h80008000 : 0;
            if (ab) v = v & ~m;
            if (ng) v = v ^ m;
            fmod1 = v;
        end
    endfunction
    function [31:0] opv(input [6:0] n, input integer w, input integer lane, input integer rqk);
        reg [159:0] q;
        begin
            q = qi[w];
            if (n < 63) opv = rf[(w * 32 + n) * 32 + lane];
            else if (n == 63) opv = rqw(rqk, lane % NPHYS);
            else if (n < 96) opv = cb[n - 64];
            else case (n)
                96: opv = 0; 97: opv = 32'h3F800000; 98: opv = 1; 99: opv = 32'h3F000000; 100: opv = 32'h40000000;
                101: opv = 32'hBF800000; 102: opv = lane; 103: opv = 8 + w; 104: opv = qe[w];
                105: opv = qk[w][lane] ? 32'hFFFFFFFF : 0;
                106: opv = q[15:0]; 107: opv = q[31:16]; 108: opv = q[47:32];
                109, 112: opv = q[103:96] + lane; 110, 111, 113: opv = 0;
                114: opv = q[106] ? 32'hFFFFFFFF : 0; 115: opv = q[63:48]; 116: opv = q[79:64]; 117: opv = q[95:80];
                118: opv = 32'h3C003C00; 119: opv = q[159:128]; default: opv = 0;
            endcase
        end
    endfunction
    // expected groups
    localparam NE = 1024;
    reg [107:0] ex_uop [0:NE-1]; reg [WARP_W-1:0] ex_w [0:NE-1]; reg [GRP_W-1:0] ex_g [0:NE-1]; reg ex_l [0:NE-1];
    reg [SBE_W:0] ex_s [0:NE-1]; reg [15:0] ex_pc [0:NE-1]; reg [DW-1:0] ex_a [0:NE-1], ex_b [0:NE-1], ex_c [0:NE-1];
    reg [2*NPHYS-1:0] ex_m [0:NE-1]; reg [31:0] ex_i [0:NE-1]; reg [6:0] ex_n [0:NE-1][0:2]; reg ex_p [0:NE-1];
    integer eh = 0, et = 0, erq = 0;
    task exp_ins(input [107:0] u, input [WARP_W-1:0] w, input [15:0] pc, input [SBE_W:0] sbe);
        integer g, p, np, ln, o, rqk;
        reg [6:0] n [0:2]; reg us [0:2]; reg [3:0] unit; reg [6:0] md; reg rqu; reg [31:0] v;
        begin
            unit = u[AD_UOP_UNIT +: 4]; md = u[AD_UOP_MOD +: 7];
            np = (u[AD_UOP_PAIR] && u[AD_UOP_USE3]) ? 2 : 1;
            for (g = 0; g < G; g = g + 1)
                for (p = 0; p < np; p = p + 1) begin
                    n[0] = p ? u[AD_UOP_RS3 +: 7] : u[AD_UOP_RS1 +: 7];
                    n[1] = u[AD_UOP_RS2 +: 7];
                    n[2] = p ? u[AD_UOP_RS3 +: 7] + 1 : u[AD_UOP_PAIR] ? u[AD_UOP_RS1 +: 7] + 1 : u[AD_UOP_RS3 +: 7];
                    us[0] = p ? 1 : u[AD_UOP_USE1]; us[1] = u[AD_UOP_USE2]; us[2] = p ? 1 : (u[AD_UOP_PAIR] || u[AD_UOP_USE3]);
                    rqu = (p == 0) && ((us[0] && n[0] == 63) || (us[1] && n[1] == 63) || (us[2] && n[2] == 63));
                    rqk = erq; if (rqu) erq = erq + 1;
                    for (o = 0; o < 3; o = o + 1) ex_n[et % NE][o] = us[o] ? n[o] : 7'h7F;
                    for (ln = 0; ln < NPHYS; ln = ln + 1) begin
                        for (o = 0; o < 3; o = o + 1) begin
                            v = us[o] ? fmod1(unit, md[2*o], md[2*o+1], opv(n[o], w, g * NPHYS + ln, rqk)) : 0;
                            if (o == 0) ex_a[et % NE][32*ln +: 32] = v; else if (o == 1) ex_b[et % NE][32*ln +: 32] = v; else ex_c[et % NE][32*ln +: 32] = v;
                        end
                        ex_m[et % NE][ln] = qe[w][g * NPHYS + ln];
                        ex_m[et % NE][NPHYS + ln] = qe[w][g * NPHYS + ln] & qi[w][128 + g * NPHYS + ln] & ~qk[w][g * NPHYS + ln];
                    end
                    ex_uop[et % NE] = u | ((p ? 108'd1 : 108'd0) << (AD_UOP_OP + 7));
                    ex_w[et % NE] = w; ex_g[et % NE] = g; ex_l[et % NE] = (g == G - 1) && (p == np - 1);
                    ex_s[et % NE] = sbe; ex_pc[et % NE] = pc; ex_p[et % NE] = (np == 2);
                    ex_i[et % NE] = {13'd0, qi[w][106], qi[w][105:104], qi[w][127:112]};
                    et = et + 1;
                end
        end
    endtask
    // ---------------- stimulus and checks ----------------
    integer ins = 0, cyc = 0, idle = 0, t_acc = -10, first_pend = 0, epoch_wait = 0;
    reg [107:0] u; reg [3:0] unit; reg [6:0] r1, r3;
    reg p_xv; reg [WARP_W+GRP_W+1+SBE_W+1+16+108+3*DW+2*NPHYS+32-1:0] p_x;
    task new_ins;
        begin
            u = 0;
            unit = {$random(seed)} % 16;
            u[AD_UOP_UNIT +: 4] = unit; u[AD_UOP_OP +: 8] = $random(seed) & 8'h7F; u[AD_UOP_MOD +: 7] = $random(seed);
            u[AD_UOP_IMM +: 32] = $random(seed); u[AD_UOP_RD +: 7] = $random(seed); u[AD_UOP_WRD] = $random(seed);
            u[AD_UOP_USE1] = $random(seed); u[AD_UOP_USE2] = $random(seed); u[AD_UOP_USE3] = $random(seed);
            for (k = 0; k < 3; k = k + 1) begin
                i = {$random(seed)} % 100;
                r1 = (i < 45) ? {$random(seed)} % 32 : (i < 50) ? 63 : (i < 70) ? 64 + {$random(seed)} % 32 : 96 + {$random(seed)} % 32;
                u[AD_UOP_RS1 + 7 * k +: 7] = r1;
            end
            i = {$random(seed)} % 10;
            if (i == 0 || i == 1) begin            // PAIR: rs1+1 inside its class
                u[AD_UOP_PAIR] = 1; u[AD_UOP_USE3] = 0;
                r1 = u[AD_UOP_RS1 +: 7];
                if (r1 == 63 || r1 == 31) r1 = 30; if (r1 == 95) r1 = 94; if (r1 == 127) r1 = 126;
                u[AD_UOP_RS1 +: 7] = r1; u[AD_UOP_USE1] = 1;
                if (u[AD_UOP_RS2 +: 7] == 63) u[AD_UOP_RS2 +: 7] = 5;
            end else if (i == 2 || i == 3) begin   // PAIR + USE3: texture .c/.3, rs3 = rs1 + 2, rs1 + 3 read too
                unit = AD_UNIT_TEX; u[AD_UOP_UNIT +: 4] = unit; u[AD_UOP_OP +: 8] = {$random(seed)} % 4 | 8'h04;
                u[AD_UOP_PAIR] = 1; u[AD_UOP_USE3] = 1; u[AD_UOP_USE1] = 1;
                r1 = u[AD_UOP_RS1 +: 7];
                if (r1 >= 28 && r1 < 64) r1 = {$random(seed)} % 28; if (r1 >= 92 && r1 < 96) r1 = 80; if (r1 >= 124) r1 = 100;
                u[AD_UOP_RS1 +: 7] = r1; u[AD_UOP_RS3 +: 7] = r1 + 2;
                if (u[AD_UOP_RS2 +: 7] == 63) u[AD_UOP_RS2 +: 7] = 7;
            end
            i_uop <= u; i_warp <= $random(seed); i_pc <= $random(seed); i_sbe <= $random(seed);
        end
    endtask
    initial begin
        seed = SEED; done = 0; e_gpr = 0; e_spec = 0; e_mod = 0; e_mask = 0; e_p2 = 0; n_gpr = 0; spec_seen = 0;
        n_mod = 0; n_stall = 0; n_p2 = 0; n_lat2 = 0; p_xv = 0;
        for (i = 0; i < 4 * 32 * 32; i = i + 1) rf[i] = $random(seed);
        for (i = 0; i < 32; i = i + 1) cb[i] = $random(seed);
        for (i = 0; i < 4; i = i + 1) begin
            qi[i] = {$random(seed), $random(seed), $random(seed), $random(seed), $random(seed)};
            qe[i] = $random(seed); qk[i] = $random(seed) & $random(seed);
        end
    end
    reg [6:0] on; integer ln, o; reg [31:0] gotv, expv; reg [3:0] xu; reg nomatch;
    always @(posedge clk) if (rst_n && !done) begin
        // ---- check a taken group ----
        if (x_valid && unit_ready[x_uop[AD_UOP_UNIT +: 4]]) begin
            if (eh == et) begin e_mask = e_mask + 1; $display("ERROR opd%0d unexpected group", NPHYS); end
            else begin
                k = eh % NE; xu = x_uop[AD_UOP_UNIT +: 4];
                if (x_uop !== ex_uop[k] || x_warp !== ex_w[k] || x_grp !== ex_g[k] || x_last !== ex_l[k] || x_sbe !== ex_s[k] || x_pc !== ex_pc[k]) begin
                    if (ex_p[k]) e_p2 = e_p2 + 1; else e_mask = e_mask + 1;
                    if (e_p2 + e_mask < 5) $display("ERROR opd%0d group %0d tag: uop %h/%h grp %0d/%0d last %b/%b", NPHYS, eh, x_uop, ex_uop[k], x_grp, ex_g[k], x_last, ex_l[k]);
                end
                if (x_mask !== ex_m[k] || x_info !== ex_i[k]) begin e_mask = e_mask + 1; if (e_mask < 5) $display("ERROR opd%0d mask %h/%h info %h/%h", NPHYS, x_mask, ex_m[k], x_info, ex_i[k]); end
                for (o = 0; o < 3; o = o + 1) begin
                    on = ex_n[k][o]; nomatch = 0;
                    for (ln = 0; ln < NPHYS; ln = ln + 1) begin
                        gotv = (o == 0) ? x_a[32*ln +: 32] : (o == 1) ? x_b[32*ln +: 32] : x_c[32*ln +: 32];
                        expv = (o == 0) ? ex_a[k][32*ln +: 32] : (o == 1) ? ex_b[k][32*ln +: 32] : ex_c[k][32*ln +: 32];
                        if (gotv !== expv) nomatch = 1;
                    end
                    if (on != 7'h7F) begin
                        if (on < 63) n_gpr = n_gpr + 1;
                        if (on >= 96) spec_seen[on] = 1;
                        if ((xu == AD_UNIT_FPU || xu == AD_UNIT_XU || xu == AD_UNIT_PK) && x_uop[AD_UOP_MOD + 2*o +: 2] != 0) n_mod = n_mod + 1;
                    end
                    if (nomatch) begin
                        if (x_uop[AD_UOP_MOD + 2*o +: 2] != 0) e_mod = e_mod + 1;
                        else if (on >= 96 && on != 7'h7F) e_spec = e_spec + 1;
                        else if (ex_p[k]) e_p2 = e_p2 + 1;
                        else e_gpr = e_gpr + 1;
                        if (e_mod + e_spec + e_gpr + e_p2 < 8) $display("ERROR opd%0d group %0d operand %0d (n %0d unit %0d mod %b): got %h exp %h", NPHYS, eh, o, on, xu, x_uop[AD_UOP_MOD +: 7],
                            (o == 0) ? x_a : (o == 1) ? x_b : x_c, (o == 0) ? ex_a[k] : (o == 1) ? ex_b[k] : ex_c[k]);
                    end
                end
                if (ex_p[k] && x_uop[AD_UOP_OP + 7]) n_p2 = n_p2 + 1;
                eh = eh + 1;
            end
        end
        // ---- stability while not taken ----
        if (p_xv && (!x_valid || p_x !== {x_warp, x_grp, x_last, x_sbe, x_pc, x_uop, x_a, x_b, x_c, x_mask, x_info})) begin
            e_mask = e_mask + 1; $display("ERROR opd%0d x_* changed while not ready", NPHYS); end
        p_xv = x_valid && !unit_ready[x_uop[AD_UOP_UNIT +: 4]];
        if (p_xv) n_stall = n_stall + 1;
        p_x = {x_warp, x_grp, x_last, x_sbe, x_pc, x_uop, x_a, x_b, x_c, x_mask, x_info};
        // ---- latency: idle stage, i accepted at t, x_valid at t + 2 ----
        if (x_valid && cyc == t_acc + 2) n_lat2 = n_lat2 + 1;
        if (cyc == t_acc + 2 && !x_valid) begin e_mask = e_mask + 1; $display("ERROR opd%0d x_valid not 2 cycles after i_valid", NPHYS); end
        // ---- issue ----
        if (i_valid && i_ready) begin
            exp_ins(i_uop, i_warp, i_pc, i_sbe);
            // an idle stage and one read slot (not three GPR operands): x_valid 2 cycles later
            if (!x_valid && !dut.b_v && !dut.ins_v &&
                !(i_uop[AD_UOP_USE1] && i_uop[AD_UOP_RS1 +: 7] < 63 && i_uop[AD_UOP_USE2] && i_uop[AD_UOP_RS2 +: 7] < 63 &&
                  (i_uop[AD_UOP_PAIR] ? i_uop[AD_UOP_RS1 +: 7] + 7'd1 < 63 : (i_uop[AD_UOP_USE3] && i_uop[AD_UOP_RS3 +: 7] < 63))))
                t_acc = cyc;
            else t_acc = -10;
            ins = ins + 1; i_valid <= 0;
        end
        if (!i_valid || i_ready) begin
            if (epoch_wait > 0) begin
                // epoch change: wait until the stage is empty, then new warp state
                if (!x_valid && !dut.b_v && !dut.ins_v && eh == et) begin
                    for (i = 0; i < 4; i = i + 1) begin
                        qi[i] = {$random(seed), $random(seed), $random(seed), $random(seed), $random(seed)};
                        qe[i] = $random(seed); qk[i] = $random(seed) & $random(seed);
                    end
                    epoch_wait = 0;
                end
            end else if (ins < NINS && $random(seed) % 4 != 0) begin
                new_ins; i_valid <= 1;
                if ($random(seed) % 100 == 0) epoch_wait = 1;
            end
        end
        // ---- back-pressure ----
        unit_ready <= ($random(seed) % 3 == 0) ? 16'hFFFF : ($random(seed) | $random(seed));
        cyc = cyc + 1;
        if ((ins >= NINS && eh == et && !i_valid) || cyc > 200000) done <= 1;
    end
endmodule

module ad_su_opd_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    wire [3:0] d; wire [31:0] eg [0:3], es [0:3], em [0:3], ek [0:3], ep [0:3], ng [0:3], nm [0:3], ns [0:3], np [0:3], nl [0:3];
    wire [127:96] ss [0:3];
    opd_h #(.NPHYS(4),  .SEED(41)) h0 (clk, rst_n, d[0], eg[0], es[0], em[0], ek[0], ep[0], ng[0], ss[0], nm[0], ns[0], np[0], nl[0]);
    opd_h #(.NPHYS(8),  .SEED(42)) h1 (clk, rst_n, d[1], eg[1], es[1], em[1], ek[1], ep[1], ng[1], ss[1], nm[1], ns[1], np[1], nl[1]);
    opd_h #(.NPHYS(16), .SEED(43)) h2 (clk, rst_n, d[2], eg[2], es[2], em[2], ek[2], ep[2], ng[2], ss[2], nm[2], ns[2], np[2], nl[2]);
    opd_h #(.NPHYS(32), .SEED(44)) h3 (clk, rst_n, d[3], eg[3], es[3], em[3], ek[3], ep[3], ng[3], ss[3], nm[3], ns[3], np[3], nl[3]);
    // the modifier leaf against tools/gsi1model.py fmod (sim/vec/core_fmod.hex)
    reg [75:0] fv [0:511]; reg [3:0] fu; reg fn, fa; reg [31:0] fin; wire [31:0] fout; integer fe = 0, j;
    ad_su_fmod #(.NPHYS(1)) fm (.unit(fu), .neg(fn), .abs_(fa), .din(fin), .dout(fout));
    integer k, tg, ts, tm, tk, tp, tng, tnm, tns, tnp, tnl; reg [127:96] sall;
    initial begin
        $readmemh("sim/vec/core_fmod.hex", fv);
        for (j = 0; j < 512; j = j + 1) begin
            {fu, fn, fa, fin} = {fv[j][75:72], fv[j][68], fv[j][64], fv[j][63:32]}; #1;
            if (fout !== fv[j][31:0]) fe = fe + 1;
        end
        repeat (3) @(posedge clk); rst_n <= 1;
        wait (&d); @(posedge clk);
        tg = 0; ts = 0; tm = 0; tk = 0; tp = 0; tng = 0; tnm = 0; tns = 0; tnp = 0; tnl = 0; sall = 0;
        for (k = 0; k < 4; k = k + 1) begin
            tg = tg + eg[k]; ts = ts + es[k]; tm = tm + em[k]; tk = tk + ek[k]; tp = tp + ep[k];
            tng = tng + ng[k]; tnm = tnm + nm[k]; tns = tns + ns[k]; tnp = tnp + np[k]; tnl = tnl + nl[k]; sall = sall | ss[k];
            $display("opd NPHYS %0d: %0d GPR operands, %0d modified, %0d stall cycles, %0d second passes, %0d 2-cycle starts",
                     4 << k, ng[k], nm[k], ns[k], np[k], nl[k]);
        end
        if (tg == 0 && ng[0] > 1000 && ng[3] > 1000) $display("PASS ad_su_opd.gpr"); else $display("FAIL ad_su_opd.gpr (%0d)", tg);
        if (ts == 0 && sall[122:96] == {27{1'b1}}) $display("PASS ad_su_opd.special"); else $display("FAIL ad_su_opd.special (%0d, seen %b)", ts, sall);
        if (tm == 0 && fe == 0 && tnm > 500) $display("PASS ad_su_opd.mods"); else $display("FAIL ad_su_opd.mods (%0d %0d)", tm, fe);
        if (tk == 0 && tns > 1000 && tnl > 50) $display("PASS ad_su_opd.mask"); else $display("FAIL ad_su_opd.mask (%0d)", tk);
        if (tp == 0 && tnp > 200) $display("PASS ad_su_opd.pass2"); else $display("FAIL ad_su_opd.pass2 (%0d)", tp);
        if (tg + ts + tm + tk + tp + fe == 0) $display("PASS ad_su_opd");
        $finish;
    end
endmodule
