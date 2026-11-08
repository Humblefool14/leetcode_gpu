// fv_ad_dec_core: the combinational decode (ad_su_dec_core) for any 64-bit
// instruction: the two table halves never both claim it; an ILL uop has
// only the ILL bit; every operand of a decoded uop is in range per
// ad_su_dec.md §4/§10 (sources < NREGS or rq with HAS_SA or 64-127; rd <
// NREGS (+ NDST) or rq for one class-a destination with HAS_SA; PAIR and
// .c/.3 extents inside their bank); features off fault; and a few rows of
// tools/gsi1asm.py transcribed by hand (add, lw, sw, texl.c, atom.cmpxchg,
// lui, texsz.s).
module fv_ad_dec_core #(
    parameter NREGS = 32, parameter PACKED = 0, parameter SUBGROUP = 0,
    parameter HAS_SA = 0, parameter MS4 = 0
) (input wire clk);
`include "ad_su_uop.vh"
    (* anyconst *) reg [63:0] instr;
    wire [AD_UOP_W-1:0] u;
    ad_su_dec_core #(.UOP_W(AD_UOP_W), .NREGS(NREGS), .PACKED(PACKED), .SUBGROUP(SUBGROUP),
        .HAS_SA(HAS_SA), .MS4(MS4)) dut (.instr(instr), .uop(u));

    // the two halves, as ad_su_dec_core wires them
    wire a_def, b_def;
    /* verilator lint_off PINCONNECTEMPTY */
    ad_su_dec_tab ta (.opc(instr[6:0]), .f3(instr[14:12]), .f7(instr[31:25]), .rs2f(instr[24:20]),
        .sub(instr[53:49]), .fmt2(instr[26:25]), .def(a_def), .fmt(), .unit(), .op(), .cls(),
        .use1(), .use2(), .use3(), .wrd(), .pair(), .side(), .need_pk(), .need_sg(), .need_sa(),
        .tex());
    ad_su_dec_tabc tc (.opc(instr[6:0]), .f3(instr[14:12]), .f7(instr[31:25]), .rs2f(instr[24:20]),
        .sub(instr[53:49]), .fmt2(instr[26:25]), .def(b_def), .fmt(), .unit(), .op(), .cls(),
        .use1(), .use2(), .use3(), .wrd(), .pair(), .side(), .need_pk(), .need_sg(), .need_sa(),
        .tex());
    wire [31:0] w0 = instr[31:0], w1 = instr[63:32];
    wire [3:0] unit = u[AD_UOP_UNIT +: 4];
    wire [7:0] op = u[AD_UOP_OP +: 8];
    wire [6:0] rd = u[AD_UOP_RD +: 7], rs1 = u[AD_UOP_RS1 +: 7], rs2 = u[AD_UOP_RS2 +: 7],
               rs3 = u[AD_UOP_RS3 +: 7];
    wire [2:0] ndst = u[AD_UOP_NDST +: 3], cls = u[AD_UOP_CLS +: 3];
    wire [31:0] imm = u[AD_UOP_IMM +: 32];
    wire ill = u[AD_UOP_ILL];
    wire u1 = u[AD_UOP_USE1], u2 = u[AD_UOP_USE2], u3 = u[AD_UOP_USE3], wrd = u[AD_UOP_WRD];
    localparam integer LIM = NREGS < 63 ? NREGS : 63;

    function src_ok;
        input [6:0] r;
        src_ok = r[6] || (r == 7'd63 ? HAS_SA != 0 : r < NREGS);
    endfunction

    wire [6:0] rd5 = {2'b0, w0[11:7]};
    wire [6:0] rdn = {w1[1:0], w0[11:7]}, rs1n = {w1[3:2], w0[19:15]}, rs2n = {w1[5:4], w0[24:20]};
    wire low = w1[7:0] == 8'd0;	// operand high bits 0: GPRs 0-31

    always @(*) begin
        assert(!(a_def && b_def));
        if (ill) assert(u == ({{(AD_UOP_W-1){1'b0}}, 1'b1} << AD_UOP_ILL));
        if (w0[1:0] != 2'b11) assert(ill);
        if (!ill) begin
            if (u1) assert(src_ok(rs1));
            if (u2) assert(src_ok(rs2));
            if (u3) assert(src_ok(rs3));
            if (wrd) assert(rd == 7'd63 ? (HAS_SA != 0 && cls == AD_CLS_A && ndst == 3'd1)
                                        : ({1'b0, rd} + ndst <= LIM));
            if (!wrd) assert(ndst == 0);
            assert(u[AD_UOP_RQS] == ((u1 && rs1 == 63) || (u2 && rs2 == 63) || (u3 && rs3 == 63)));
            if (u[AD_UOP_PAIR]) assert(rs1[6] ? rs1[4:0] != 5'd31 : rs1 + 1 < LIM);
            if (unit == AD_UNIT_PK && op != AD_PK_PACKH && op != AD_PK_UNPACKH) assert(PACKED != 0);
            if (unit == AD_UNIT_LANE && op != AD_LANE_QD) assert(SUBGROUP != 0);
            if (unit == AD_UNIT_RQ || rd == 7'd63 && wrd) assert(HAS_SA != 0);
            if (unit == AD_UNIT_TEX && op == 8'h4B) assert(MS4 != 0);
            if (unit != AD_UNIT_TEX) assert(u[AD_UOP_SAMP_SLOT +: 4] == 0);
        end
        // add rd, rs1, rs2
        if (w0[6:0] == 7'h33 && w0[14:12] == 0 && w0[31:25] == 0 && low) begin
            assert(!ill && unit == AD_UNIT_ALU && op == 0 && rd == rd5 && u1 && u2 && !u3 && wrd);
            assert(rs1 == {2'b0, w0[19:15]} && rs2 == {2'b0, w0[24:20]} && imm == 0);
            assert(u[AD_UOP_RM +: 3] == 0 && cls == AD_CLS_A && ndst == 1 && !u[AD_UOP_SIDE]);
        end
        // lw rd, imm(rs1): imm = sext(imm12) + (sext(w1[31:22]) << 12)
        if (w0[6:0] == 7'h03 && w0[14:12] == 3'd2 && low)
            assert(!ill && unit == AD_UNIT_LSU && op == AD_LSU_LW && cls == AD_CLS_M && u1 && !u2 &&
                   wrd && $signed(imm) == $signed(w0[31:20]) + $signed({w1[31:22], 12'd0}));
        // sw rs2, imm(rs1), sub 0
        if (w0[6:0] == 7'h23 && w0[14:12] == 3'd2 && low && w1[21:17] == 0)
            assert(!ill && unit == AD_UNIT_LSU && op == AD_LSU_SW && u1 && u2 && !wrd &&
                   u[AD_UOP_SIDE] && ndst == 0 &&
                   $signed(imm) == $signed({w0[31:25], w0[11:7]}) + $signed({w1[31:22], 12'd0}));
        // texl.c rd, rs1, rs2: Dref rs1+2 as rs3, four destinations
        if (w0[6:0] == 7'h2B && w0[14:12] == 0 && w0[31:25] == 7'd1 && w1[21] == 0 && low &&
            w0[19:15] < 28 && w0[11:7] < 28 && w0[11:7] < NREGS - 4)
            assert(!ill && unit == AD_UNIT_TEX && op == 8'd4 && u3 && rs3 == rs1 + 2 &&
                   u[AD_UOP_PAIR] && ndst == 3'd4 && imm == {20'd0, w1[13:10], w1[29:26], w1[25:22]} &&
                   u[AD_UOP_SAMP_SLOT +: 4] == w1[9:6] && cls == AD_CLS_T);
        // atom.cmpxchg (global): rs3 read
        if (w0[6:0] == 7'h0B && w0[14:12] == 3'd2 && w1[21:17] == 5'd10 && low)
            assert(!ill && unit == AD_UNIT_LSU && op == AD_LSU_ATOM && u1 && u2 && u3 && wrd &&
                   rs3 == {2'b0, w0[31:27]} && u[AD_UOP_SUB +: 5] == 5'd10);
        // lui: imm {w0[31:12], w1[13:2]}, no sources
        if (w0[6:0] == 7'h37 && w1[1:0] == 0)
            assert(!ill && unit == AD_UNIT_ALU && op == AD_ALU_MOVI && imm == {w0[31:12], w1[13:2]} &&
                   rs1 == 0 && rs2 == 0 && rs3 == 0 && u[AD_UOP_SUB +: 5] == 0 && !u1 && wrd);
        // texsz.s
        if (w0[6:0] == 7'h2B && w0[14:12] == 3'd3 && w0[31:20] == 12'd3 && w1[21] == 0 && low)
            assert(ill == (MS4 == 0) && (ill || (op == 8'h4B && !u1)));
    end
endmodule
