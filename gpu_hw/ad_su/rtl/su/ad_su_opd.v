// ad_su_opd -- operand collection (spec/gpu/su/ad_su_opd.md).  For each lane group of
// an issued instruction: reads the GPRs (2-port RF: r_reg1/r_reg2, data the next
// cycle), the constants c0-c31 (cr_*), rq, the special operands; forwards the short
// units' results; applies the float modifiers and the lane masks; drives x_*.
//
// Pipeline (one slot a cycle):
//   A  a read slot of the pending instruction (the instruction register, or i_* when it
//      is empty: i_ready = the slot issues now) addresses the RF, cbank and rq;
//   B  the read data arrives: forwarding per RF port (ad_su_fwd_sel), operand values
//      (ad_su_opd_src), modifiers (ad_su_fmod), masks -> the x_* registers.
// So x_valid comes 2 cycles after i_valid.  A group with three GPR operands takes two
// read slots (a and b first, held in ab_*, then c).  A PAIR + USE3 uop sends each group
// twice (pass 0, pass 1 with AD_TEX_PASS2), ad_su_opd_plan has the operand numbers.
// Back-pressure: x_* hold while their unit is not ready (unit_ready[unit]); a slot in B
// that cannot move to x is read again (replayed) the next cycle, so its RF data and
// forwarding stay current (rq is popped once, on the slot's first read, and held).
// Forwarding per lane: ALU/FPU EX4 > ALU/FPU EX5 > WB (this cycle's RF write) > the
// registered RF-write bypass (last cycle's write, which a read issued then did not see)
// > the RF word; matching warp, group and register (rd < 63).  A consumer's group sees
// a producer's group from its EX4 cycle on: x_valid of the consumer's group at least 5
// cycles after the producer's (ad_su_sb's interlock decides when to issue).
// LW (default 32) narrows the lane words for formal harnesses only.
module ad_su_opd #(
    parameter NPHYS     = 8,
    parameter WARP_W    = 2,
    parameter GRP_W     = 2,
    parameter SBE_W     = 2,
    parameter UOP_W     = 108,
    parameter WARP_BASE = 0,
    parameter LW        = 32
) (
    input  wire                  clk,
    input  wire                  rst_n,
    // from ad_su_sb
    input  wire                  i_valid,
    output wire                  i_ready,
    input  wire [WARP_W-1:0]     i_warp,
    input  wire [15:0]           i_pc,
    input  wire [UOP_W-1:0]      i_uop,
    input  wire [SBE_W:0]        i_sbe,
    // register file (2 read ports)
    output wire                  r_en,
    output wire [WARP_W-1:0]     r_warp,
    output wire [GRP_W-1:0]      r_grp,
    output wire [5:0]            r_reg1,
    output wire [5:0]            r_reg2,
    input  wire [NPHYS*LW-1:0]   r_data1,
    input  wire [NPHYS*LW-1:0]   r_data2,
    // constant bank
    output wire                  cr_en,
    output wire [14:0]           cr_idx,
    input  wire [95:0]           cr_data,
    // warp state (combinational answers)
    output wire [WARP_W-1:0]     q_warp,
    input  wire [159:0]          q_info,
    input  wire [31:0]           q_exec,
    input  wire [31:0]           q_killed,
    // rq
    output wire                  rq_pop,
    input  wire [NPHYS*LW-1:0]   rq_data,
    // execution bus
    output reg                   x_valid,
    output reg  [WARP_W-1:0]     x_warp,
    output reg  [GRP_W-1:0]      x_grp,
    output reg                   x_last,
    output reg  [SBE_W:0]        x_sbe,
    output reg  [15:0]           x_pc,
    output reg  [UOP_W-1:0]      x_uop,
    output reg  [NPHYS*LW-1:0]   x_a,
    output reg  [NPHYS*LW-1:0]   x_b,
    output reg  [NPHYS*LW-1:0]   x_c,
    output reg  [2*NPHYS-1:0]    x_mask,
    output reg  [31:0]           x_info,
    input  wire [15:0]           unit_ready,
    // forwarding
    input  wire                  fwd_alu_ex4_valid,
    input  wire [WARP_W-1:0]     fwd_alu_ex4_warp,
    input  wire [GRP_W-1:0]      fwd_alu_ex4_grp,
    input  wire [6:0]            fwd_alu_ex4_rd,
    input  wire [NPHYS*LW-1:0]   fwd_alu_ex4_data,
    input  wire [NPHYS-1:0]      fwd_alu_ex4_lanes,
    input  wire                  fwd_alu_ex5_valid,
    input  wire [WARP_W-1:0]     fwd_alu_ex5_warp,
    input  wire [GRP_W-1:0]      fwd_alu_ex5_grp,
    input  wire [6:0]            fwd_alu_ex5_rd,
    input  wire [NPHYS*LW-1:0]   fwd_alu_ex5_data,
    input  wire [NPHYS-1:0]      fwd_alu_ex5_lanes,
    input  wire                  fwd_fpu_ex4_valid,
    input  wire [WARP_W-1:0]     fwd_fpu_ex4_warp,
    input  wire [GRP_W-1:0]      fwd_fpu_ex4_grp,
    input  wire [6:0]            fwd_fpu_ex4_rd,
    input  wire [NPHYS*LW-1:0]   fwd_fpu_ex4_data,
    input  wire [NPHYS-1:0]      fwd_fpu_ex4_lanes,
    input  wire                  fwd_fpu_ex5_valid,
    input  wire [WARP_W-1:0]     fwd_fpu_ex5_warp,
    input  wire [GRP_W-1:0]      fwd_fpu_ex5_grp,
    input  wire [6:0]            fwd_fpu_ex5_rd,
    input  wire [NPHYS*LW-1:0]   fwd_fpu_ex5_data,
    input  wire [NPHYS-1:0]      fwd_fpu_ex5_lanes,
    input  wire                  fwd_wb_valid,
    input  wire [WARP_W-1:0]     fwd_wb_warp,
    input  wire [GRP_W-1:0]      fwd_wb_grp,
    input  wire [6:0]            fwd_wb_rd,
    input  wire [NPHYS*LW-1:0]   fwd_wb_data,
    input  wire [NPHYS-1:0]      fwd_wb_lanes
);
`include "ad_su_uop.vh"
    localparam G  = 32 / NPHYS;
    localparam DW = NPHYS * LW;
    localparam [GRP_W-1:0] GLAST = G - 1;

    // ------------------------------------------------------------------ x stage
    wire x_take = x_valid && unit_ready[x_uop[AD_UOP_UNIT +: 4]];
    wire x_free = !x_valid || x_take;

    // ------------------------------------------------------------------ instruction register
    reg               ins_v;
    reg [UOP_W-1:0]   ins_uop;
    reg [WARP_W-1:0]  ins_warp;
    reg [15:0]        ins_pc;
    reg [SBE_W:0]     ins_sbe;
    reg [GRP_W-1:0]   ins_grp;
    reg               ins_pass, ins_sub;

    // ------------------------------------------------------------------ B slot
    reg               b_v, b_final, b_last, b_first, b_pass, b_sub;
    reg [UOP_W-1:0]   b_uop;
    reg [WARP_W-1:0]  b_warp;
    reg [15:0]        b_pc;
    reg [SBE_W:0]     b_sbe;
    reg [GRP_W-1:0]   b_grp;
    reg [5:0]         b_r1, b_r2;
`ifdef MUT_OPD_HOLD
    wire b_go    = b_v;                                // mutation: ignores back-pressure
`else
    wire b_go    = b_v && (!b_final || x_free);
`endif
    wire a_adv   = !b_v || b_go;
    wire replay  = b_v && !b_go;

    // ------------------------------------------------------------------ A: the pending slot
    wire              p_v    = ins_v || i_valid;
    wire [UOP_W-1:0]  p_uop  = ins_v ? ins_uop  : i_uop;
    wire [WARP_W-1:0] p_warp = ins_v ? ins_warp : i_warp;
    wire [15:0]       p_pc   = ins_v ? ins_pc   : i_pc;
    wire [SBE_W:0]    p_sbe  = ins_v ? ins_sbe  : i_sbe;
    wire [GRP_W-1:0]  p_grp  = ins_v ? ins_grp  : {GRP_W{1'b0}};
    wire              p_pass = ins_v && ins_pass;
    wire              p_sub  = ins_v && ins_sub;
    wire [6:0] pa_n, pb_n, pc_n; wire pa_u, pb_u, pc_u, pa_g, pb_g, pc_g, p_two, p_bp2, p_cp2;
    wire [5:0] p_s0r1, p_s0r2, p_s1r1;
    ad_su_opd_plan pplan (
        .rs1(p_uop[AD_UOP_RS1 +: 7]), .rs2(p_uop[AD_UOP_RS2 +: 7]), .rs3(p_uop[AD_UOP_RS3 +: 7]),
        .use1(p_uop[AD_UOP_USE1]), .use2(p_uop[AD_UOP_USE2]), .use3(p_uop[AD_UOP_USE3]),
        .pair(p_uop[AD_UOP_PAIR]), .pass(p_pass), .na(pa_n), .nb(pb_n), .nc(pc_n),
        .ua(pa_u), .ub(pb_u), .uc(pc_u), .ga(pa_g), .gb(pb_g), .gc(pc_g), .two(p_two),
        .s0_r1(p_s0r1), .s0_r2(p_s0r2), .s1_r1(p_s1r1), .b_p2(p_bp2), .c_p2(p_cp2));
    wire p_2pass = p_uop[AD_UOP_PAIR] && p_uop[AD_UOP_USE3];
    wire p_final = !p_two || p_sub;
    wire p_lastp = !p_2pass || p_pass;
    wire p_last  = p_final && p_lastp && p_grp == GLAST;
    wire p_rq    = !p_pass && ((pa_u && pa_n == 7'd63) || (pb_u && pb_n == 7'd63) || (pc_u && pc_n == 7'd63));
    wire a_new   = a_adv && p_v;
    assign i_ready = !ins_v && a_adv;

    // next counters of the pending instruction
    wire [GRP_W-1:0] n_grp  = (p_final && p_lastp) ? p_grp + 1'b1 : p_grp;
    wire             n_pass = p_final ? (p_2pass && !p_pass) : p_pass;
    wire             n_sub  = !p_final;

    // B's plan (for operand selection and a replayed read)
    wire [6:0] ba_n, bb_n, bc_n; wire ba_u, bb_u, bc_u, ba_g, bb_g, bc_g, b_two, b_bp2, b_cp2;
    wire [5:0] b_s0r1, b_s0r2, b_s1r1;
    ad_su_opd_plan bplan (
        .rs1(b_uop[AD_UOP_RS1 +: 7]), .rs2(b_uop[AD_UOP_RS2 +: 7]), .rs3(b_uop[AD_UOP_RS3 +: 7]),
        .use1(b_uop[AD_UOP_USE1]), .use2(b_uop[AD_UOP_USE2]), .use3(b_uop[AD_UOP_USE3]),
        .pair(b_uop[AD_UOP_PAIR]), .pass(b_pass), .na(ba_n), .nb(bb_n), .nc(bc_n),
        .ua(ba_u), .ub(bb_u), .uc(bc_u), .ga(ba_g), .gb(bb_g), .gc(bc_g), .two(b_two),
        .s0_r1(b_s0r1), .s0_r2(b_s0r2), .s1_r1(b_s1r1), .b_p2(b_bp2), .c_p2(b_cp2));

    // ------------------------------------------------------------------ reads
    assign r_en   = a_new || replay;
    assign r_warp = replay ? b_warp : p_warp;
    assign r_grp  = replay ? b_grp  : p_grp;
    assign r_reg1 = replay ? b_r1 : (p_sub ? p_s1r1 : p_s0r1);
    assign r_reg2 = replay ? b_r2 : p_s0r2;
    assign cr_en  = r_en;
    assign cr_idx = replay ? {bc_n[4:0], bb_n[4:0], ba_n[4:0]} : {pc_n[4:0], pb_n[4:0], pa_n[4:0]};
    assign rq_pop = a_new && p_rq;
    assign q_warp = b_warp;

    always @(posedge clk) begin
        if (!rst_n) begin
            ins_v <= 1'b0;
            b_v   <= 1'b0;
        end else begin
            if (a_new) begin
                ins_v <= !p_last;
                b_v   <= 1'b1;
            end else if (b_go) begin
                b_v   <= 1'b0;
            end
        end
        if (a_new) begin
            ins_uop <= p_uop; ins_warp <= p_warp; ins_pc <= p_pc; ins_sbe <= p_sbe;
            ins_grp <= n_grp; ins_pass <= n_pass; ins_sub <= n_sub;
            b_uop <= p_uop; b_warp <= p_warp; b_pc <= p_pc; b_sbe <= p_sbe; b_grp <= p_grp;
            b_pass <= p_pass; b_sub <= p_sub; b_final <= p_final; b_last <= p_last; b_first <= 1'b1;
            b_r1 <= p_sub ? p_s1r1 : p_s0r1; b_r2 <= p_s0r2;
        end else if (replay) begin
            b_first <= 1'b0;
        end
    end

    // ------------------------------------------------------------------ B: forwarding
    reg               rfb_v;
    reg [WARP_W-1:0]  rfb_warp;
    reg [GRP_W-1:0]   rfb_grp;
    reg [6:0]         rfb_rd;
    reg [DW-1:0]      rfb_data;
    reg [NPHYS-1:0]   rfb_lanes;
    always @(posedge clk) begin
        if (!rst_n) rfb_v <= 1'b0;
        else        rfb_v <= fwd_wb_valid;
        rfb_warp <= fwd_wb_warp; rfb_grp <= fwd_wb_grp; rfb_rd <= fwd_wb_rd;
        rfb_data <= fwd_wb_data; rfb_lanes <= fwd_wb_lanes;
    end
    wire [5:0]          f_valid = {rfb_v, fwd_wb_valid, fwd_fpu_ex5_valid, fwd_alu_ex5_valid,
                                   fwd_fpu_ex4_valid, fwd_alu_ex4_valid};
    wire [6*WARP_W-1:0] f_warp  = {rfb_warp, fwd_wb_warp, fwd_fpu_ex5_warp, fwd_alu_ex5_warp,
                                   fwd_fpu_ex4_warp, fwd_alu_ex4_warp};
    wire [6*GRP_W-1:0]  f_grp   = {rfb_grp, fwd_wb_grp, fwd_fpu_ex5_grp, fwd_alu_ex5_grp,
                                   fwd_fpu_ex4_grp, fwd_alu_ex4_grp};
    wire [6*7-1:0]      f_rd    = {rfb_rd, fwd_wb_rd, fwd_fpu_ex5_rd, fwd_alu_ex5_rd,
                                   fwd_fpu_ex4_rd, fwd_alu_ex4_rd};
    wire [6*DW-1:0]     f_data  = {rfb_data, fwd_wb_data, fwd_fpu_ex5_data, fwd_alu_ex5_data,
                                   fwd_fpu_ex4_data, fwd_alu_ex4_data};
    wire [6*NPHYS-1:0]  f_lanes = {rfb_lanes, fwd_wb_lanes, fwd_fpu_ex5_lanes, fwd_alu_ex5_lanes,
                                   fwd_fpu_ex4_lanes, fwd_alu_ex4_lanes};
    wire [DW-1:0] port1, port2;
    wire [5:0]    m1, m2;
    ad_su_fwd_sel #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .LW(LW)) fw1 (
        .en(1'b1), .warp(b_warp), .grp(b_grp), .reg_n(b_r1), .base(r_data1), .f_valid(f_valid),
        .f_warp(f_warp), .f_grp(f_grp), .f_rd(f_rd), .f_data(f_data), .f_lanes(f_lanes),
        .out(port1), .match(m1));
    ad_su_fwd_sel #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .LW(LW)) fw2 (
        .en(1'b1), .warp(b_warp), .grp(b_grp), .reg_n(b_r2), .base(r_data2), .f_valid(f_valid),
        .f_warp(f_warp), .f_grp(f_grp), .f_rd(f_rd), .f_data(f_data), .f_lanes(f_lanes),
        .out(port2), .match(m2));

    // ------------------------------------------------------------------ B: operands
    reg [DW-1:0] ab_a, ab_b, rq_q;
    always @(posedge clk) begin
        if (b_v && !b_final) begin ab_a <= port1; ab_b <= port2; end
        if (b_v && b_first) rq_q <= rq_data;
    end
    wire [DW-1:0] rqv  = b_first ? rq_data : rq_q;
    wire [DW-1:0] ga_v = b_two ? ab_a : port1;
    wire [DW-1:0] gb_v = b_two ? ab_b : (b_bp2 ? port2 : port1);
    wire [DW-1:0] gc_v = b_two ? port1 : (b_cp2 ? port2 : port1);
    wire [DW-1:0] va, vb, vc, ma, mb, mc;
    ad_su_opd_src #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .LW(LW), .WARP_BASE(WARP_BASE)) sa (
        .n(ba_n), .gpr(ga_v), .rq(rqv), .cw(cr_data[31:0]), .warp(b_warp), .grp(b_grp),
        .q_info(q_info), .q_exec(q_exec), .q_killed(q_killed), .v(va));
    ad_su_opd_src #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .LW(LW), .WARP_BASE(WARP_BASE)) sb (
        .n(bb_n), .gpr(gb_v), .rq(rqv), .cw(cr_data[63:32]), .warp(b_warp), .grp(b_grp),
        .q_info(q_info), .q_exec(q_exec), .q_killed(q_killed), .v(vb));
    ad_su_opd_src #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .LW(LW), .WARP_BASE(WARP_BASE)) sc (
        .n(bc_n), .gpr(gc_v), .rq(rqv), .cw(cr_data[95:64]), .warp(b_warp), .grp(b_grp),
        .q_info(q_info), .q_exec(q_exec), .q_killed(q_killed), .v(vc));
    wire [3:0] b_unit = b_uop[AD_UOP_UNIT +: 4];
    wire [6:0] b_mod  = b_uop[AD_UOP_MOD +: 7];
`ifdef MUT_OPD_MOD
    wire [3:0] m_unit = AD_UNIT_FPU;                   // mutation: modifiers on every unit
`else
    wire [3:0] m_unit = b_unit;
`endif
    ad_su_fmod #(.NPHYS(NPHYS), .LW(LW)) fa (.unit(m_unit), .neg(b_mod[0]), .abs_(b_mod[1]), .din(va), .dout(ma));
    ad_su_fmod #(.NPHYS(NPHYS), .LW(LW)) fb (.unit(m_unit), .neg(b_mod[2]), .abs_(b_mod[3]), .din(vb), .dout(mb));
    ad_su_fmod #(.NPHYS(NPHYS), .LW(LW)) fc (.unit(m_unit), .neg(b_mod[4]), .abs_(b_mod[5]), .din(vc), .dout(mc));

    // masks of the group (bit grp*NPHYS + i of the 32-lane words)
    wire [31:0]      sh_exec = q_exec >> (b_grp * NPHYS);
    wire [31:0]      sh_cov  = q_info[AD_WI_MASK +: 32] >> (b_grp * NPHYS);
    wire [31:0]      sh_kil  = q_killed >> (b_grp * NPHYS);
    wire [NPHYS-1:0] m_exec  = sh_exec[NPHYS-1:0];
    wire [NPHYS-1:0] m_side  = m_exec & sh_cov[NPHYS-1:0] & ~sh_kil[NPHYS-1:0];

    // ------------------------------------------------------------------ x registers
`ifdef MUT_OPD_HOLD
    wire x_load = b_v && b_final;
`else
    wire x_load = b_v && b_final && x_free;
`endif
    always @(posedge clk) begin
        if (!rst_n)      x_valid <= 1'b0;
        else if (x_load) x_valid <= 1'b1;
        else if (x_take) x_valid <= 1'b0;
        if (x_load) begin
            x_warp <= b_warp; x_grp <= b_grp; x_last <= b_last; x_sbe <= b_sbe; x_pc <= b_pc;
            x_uop  <= b_uop | ({{(UOP_W-1){1'b0}}, b_pass} << (AD_UOP_OP + AD_TEX_PASS2));
            x_a    <= ba_u ? ma : {DW{1'b0}};
            x_b    <= bb_u ? mb : {DW{1'b0}};
            x_c    <= bc_u ? mc : {DW{1'b0}};
            x_mask <= {m_side, m_exec};
            x_info <= {13'd0, q_info[AD_WI_FRONT], q_info[AD_WI_KIND +: 2], q_info[AD_WI_SEQ +: 16]};
        end
    end
    // unused: the plan's GPR flags of the operands (the ports carry them), m1/m2 (TB coverage)
    wire unused = &{1'b0, pa_g, pb_g, pc_g, p_bp2, p_cp2, ba_g, bb_g, bc_g, b_s0r1, b_s0r2, b_s1r1,
                    b_sub, m1, m2};
endmodule
