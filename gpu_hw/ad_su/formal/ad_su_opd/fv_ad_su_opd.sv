// fv_ad_su_opd -- ad_su_opd reduced (NPHYS 16 so two groups, 1-bit lane words, one warp
// bit, uops with only UNIT, RS1-3, USE1-3 and PAIR set; every other input free each
// cycle: RF / cbank / rq data, warp state, unit_ready, the forwarding writers).
// Asserts: (1) x_* stay stable while x_valid and the unit is not ready; (2) the taken
// groups follow the accepted instructions in order, each with groups 0..G-1 (and for
// PAIR + USE3 passes 0, 1 per group, AD_TEX_PASS2 on pass 1), x_warp / x_pc of the
// instruction, x_last exactly on its last group; (3) at most 3 instructions in flight
// (harness queue never overflows).  Forwarding priority is the leaf proof
// (formal/ad_core_fwd_sel).
module fv_ad_su_opd (
    input wire clk,
    input wire i_valid, input wire i_warp, input wire [15:0] i_pc, input wire [107:0] i_uop, input wire [1:0] i_sbe,
    input wire [15:0] r_data1, input wire [15:0] r_data2, input wire [95:0] cr_data,
    input wire [159:0] q_info, input wire [31:0] q_exec, input wire [31:0] q_killed, input wire [15:0] rq_data,
    input wire [15:0] unit_ready,
    input wire [4:0] fv, input wire [4:0] fw, input wire [4:0] fg, input wire [34:0] fr, input wire [79:0] fd, input wire [79:0] fl
);
`include "ad_su_uop.vh"
    localparam N = 16, G = 2;
    reg init = 1; always @(posedge clk) init <= 0;
    wire i_ready, r_en, cr_en, rq_pop, q_warp, x_valid, x_warp, x_grp, x_last; wire [1:0] x_sbe; wire r_warp, r_grp;
    wire [5:0] r_reg1, r_reg2; wire [14:0] cr_idx; wire [15:0] x_pc; wire [107:0] x_uop; wire [15:0] x_a, x_b, x_c;
    wire [31:0] x_mask; wire [31:0] x_info;
    ad_su_opd #(.NPHYS(N), .WARP_W(1), .GRP_W(1), .SBE_W(1), .LW(1)) dut (
        .clk(clk), .rst_n(!init), .i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp), .i_pc(i_pc), .i_uop(i_uop), .i_sbe(i_sbe),
        .r_en(r_en), .r_warp(r_warp), .r_grp(r_grp), .r_reg1(r_reg1), .r_reg2(r_reg2), .r_data1(r_data1), .r_data2(r_data2),
        .cr_en(cr_en), .cr_idx(cr_idx), .cr_data(cr_data), .q_warp(q_warp), .q_info(q_info), .q_exec(q_exec), .q_killed(q_killed),
        .rq_pop(rq_pop), .rq_data(rq_data), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
        .x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask), .x_info(x_info), .unit_ready(unit_ready),
        .fwd_alu_ex4_valid(fv[0]), .fwd_alu_ex4_warp(fw[0]), .fwd_alu_ex4_grp(fg[0]), .fwd_alu_ex4_rd(fr[6:0]), .fwd_alu_ex4_data(fd[15:0]), .fwd_alu_ex4_lanes(fl[15:0]),
        .fwd_fpu_ex4_valid(fv[1]), .fwd_fpu_ex4_warp(fw[1]), .fwd_fpu_ex4_grp(fg[1]), .fwd_fpu_ex4_rd(fr[13:7]), .fwd_fpu_ex4_data(fd[31:16]), .fwd_fpu_ex4_lanes(fl[31:16]),
        .fwd_alu_ex5_valid(fv[2]), .fwd_alu_ex5_warp(fw[2]), .fwd_alu_ex5_grp(fg[2]), .fwd_alu_ex5_rd(fr[20:14]), .fwd_alu_ex5_data(fd[47:32]), .fwd_alu_ex5_lanes(fl[47:32]),
        .fwd_fpu_ex5_valid(fv[3]), .fwd_fpu_ex5_warp(fw[3]), .fwd_fpu_ex5_grp(fg[3]), .fwd_fpu_ex5_rd(fr[27:21]), .fwd_fpu_ex5_data(fd[63:48]), .fwd_fpu_ex5_lanes(fl[63:48]),
        .fwd_wb_valid(fv[4]), .fwd_wb_warp(fw[4]), .fwd_wb_grp(fg[4]), .fwd_wb_rd(fr[34:28]), .fwd_wb_data(fd[79:64]), .fwd_wb_lanes(fl[79:64]));
    // reduced uop: only the fields the sequencing looks at
    always @(*) begin
        assume (i_uop[AD_UOP_OP +: 8] == 0 && i_uop[AD_UOP_RD +: 7] == 0 && i_uop[AD_UOP_IMM +: 32] == 0);
        assume (i_uop[AD_UOP_MOD +: 7] == 0 && i_uop[AD_UOP_HSEL +: 2] == 0 && i_uop[AD_UOP_SUB +: 5] == 0);
        assume (i_uop[AD_UOP_RM +: 3] == 0 && i_uop[AD_UOP_CLS +: 3] == 0 && i_uop[AD_UOP_NDST +: 3] == 0);
        assume (i_uop[107:AD_UOP_WRD] == 0 && i_pc[15:2] == 0);
    end
    wire x_take = x_valid && unit_ready[x_uop[AD_UOP_UNIT +: 4]];
    // (1) stability
    reg p_hold = 0; reg [1+1+1+2+16+108+48+32+32-1:0] p_x;
    always @(posedge clk) begin
        p_hold <= !init && x_valid && !x_take;
        p_x <= {x_warp, x_grp, x_last, x_sbe, x_pc, x_uop, x_a, x_b, x_c, x_mask, x_info};
    end
    // (2) order: a queue of the accepted instructions {two passes, warp, pc[1:0]}
    reg [3:0] q [0:3]; reg [2:0] qn = 0; reg hg = 0, hp = 0;
    wire acc = i_valid && i_ready;
    wire [3:0] ent = {i_uop[AD_UOP_PAIR] && i_uop[AD_UOP_USE3], i_warp, i_pc[1:0]};
    wire       two = q[0][3];
    wire       lastg = hg == G - 1 && hp == two;
    wire       popq = x_take && lastg;
    integer k;
    always @(posedge clk)
        if (init) begin qn <= 0; hg <= 0; hp <= 0; end
        else begin
            for (k = 0; k < 3; k = k + 1) if (popq) q[k] <= q[k+1];
            if (acc) q[popq ? qn - 1 : qn] <= ent;
            qn <= qn + acc - popq;
            if (x_take) begin
                if (lastg) begin hg <= 0; hp <= 0; end
                else if (two && !hp) hp <= 1;
                else begin hp <= 0; hg <= hg + 1; end
            end
        end
    always @(*) if (!init) begin
        if (p_hold) assert (x_valid && {x_warp, x_grp, x_last, x_sbe, x_pc, x_uop, x_a, x_b, x_c, x_mask, x_info} == p_x);
        assert (qn <= 3);
        if (x_valid) begin
            assert (qn != 0);
            assert (x_warp == q[0][2] && x_pc[1:0] == q[0][1:0] && x_grp == hg && x_last == lastg);
            assert (x_uop[AD_UOP_OP + AD_TEX_PASS2] == hp);
        end
    end
endmodule
