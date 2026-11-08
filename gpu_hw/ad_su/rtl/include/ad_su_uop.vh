/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ad_su_uop.vh: the SU's decoded instruction ("uop") and warp-info word,
 * the fields that travel from ad_su_dec through ad_su_sb and ad_su_opd
 * to the execution units (spec/gpu/su/ad_su_dec.md).  Included inside a
 * module body; every name is a localparam.  A module's UOP_W parameter is
 * AD_UOP_W.
 */

/* verilator lint_off UNUSEDPARAM */

localparam AD_UOP_W = 108;

/* Field positions (LSB) and widths. */
localparam AD_UOP_UNIT = 0;	/* [3:0] the unit, below */
localparam AD_UOP_OP = 4;	/* [11:4] unit-specific operation */
localparam AD_UOP_RD = 12;	/* [18:12] destination operand number (0-63; 63 = rq) */
localparam AD_UOP_RS1 = 19;	/* [25:19] source operand numbers (0-127, design §3.2) */
localparam AD_UOP_RS2 = 26;	/* [32:26] */
localparam AD_UOP_RS3 = 33;	/* [39:33] */
localparam AD_UOP_IMM = 40;	/* [71:40] the immediate, sign-extended (22-bit offsets, movi) */
localparam AD_UOP_MOD = 72;	/* [78:72] {sat, a3, n3, a2, n2, a1, n1} float modifiers */
localparam AD_UOP_HSEL = 79;	/* [80:79] packed half select */
localparam AD_UOP_SUB = 81;	/* [85:81] sub field of word1 */
localparam AD_UOP_RM = 86;	/* [88:86] rounding mode / funct3 */
localparam AD_UOP_CLS = 89;	/* [91:89] latency class, below */
localparam AD_UOP_NDST = 92;	/* [94:92] destination registers written (0, 1 or 4) */
localparam AD_UOP_USE1 = 95;	/* rs1 is read */
localparam AD_UOP_USE2 = 96;	/* rs2 is read */
localparam AD_UOP_USE3 = 97;	/* rs3 is read */
localparam AD_UOP_WRD = 98;	/* rd is written */
localparam AD_UOP_PAIR = 99;	/* rs1 and rs1+1 are read (texl/texb/texf) */
localparam AD_UOP_ILL = 100;	/* ISA fault (FAULT kind 8) */
localparam AD_UOP_RQS = 101;	/* a source is rq (pop) */
localparam AD_UOP_RQD = 102;	/* rd is rq (push) */
localparam AD_UOP_SIDE = 103;	/* has side effects: use the side-effect lane mask */
localparam AD_UOP_SAMP_SLOT = 104; /* [107:104] sampler slot (w1[9:6]) for texture instructions (N62, N77) */

/* Units (AD_UOP_UNIT). */
localparam [3:0] AD_UNIT_NONE = 4'd0;	/* nop */
localparam [3:0] AD_UNIT_ALU = 4'd1;	/* integer, sel, lui/movi */
localparam [3:0] AD_UNIT_FPU = 4'd2;	/* fp32, mul, fract */
localparam [3:0] AD_UNIT_PK = 4'd3;	/* 16-bit packed */
localparam [3:0] AD_UNIT_XU = 4'd4;	/* rcp rsq exp2 log2 sin cos fsqrt */
localparam [3:0] AD_UNIT_DIV = 4'd5;	/* div divu rem remu */
localparam [3:0] AD_UNIT_LSU = 4'd6;	/* lw sw atom (global) fence (after ad_su_sb waits for cm = 0) */
localparam [3:0] AD_UNIT_LDS = 4'd7;	/* lds sts atom (shared, sub[4]) */
localparam [3:0] AD_UNIT_CBANK = 4'd8;	/* lwc */
localparam [3:0] AD_UNIT_TEX = 4'd9;	/* texl texb texf texsz */
localparam [3:0] AD_UNIT_EXP = 4'd10;	/* exp */
localparam [3:0] AD_UNIT_LDA = 4'd11;	/* lda */
localparam [3:0] AD_UNIT_LANE = 4'd12;	/* qd shfl vote ballot */
localparam [3:0] AD_UNIT_EXEC = 4'd13;	/* branches, exec.*, kill, end, bar */
localparam [3:0] AD_UNIT_CTL = 4'd14;	/* wait (held by ad_su_sb, then issued as a no-op) */
localparam [3:0] AD_UNIT_RQ = 4'd15;	/* sactl (reserved, design §3.9) */

/* Latency classes (AD_UOP_CLS, design §3.4.2). */
localparam [2:0] AD_CLS_A = 3'd0;	/* short, fixed pipeline */
localparam [2:0] AD_CLS_F = 3'd1;	/* short, fixed pipeline */
localparam [2:0] AD_CLS_M = 3'd2;	/* memory: scoreboard, counter cm for stores */
localparam [2:0] AD_CLS_T = 3'd3;	/* texture: scoreboard, counter ct */
localparam [2:0] AD_CLS_X = 3'd4;	/* transcendental, divide: scoreboard, counter cx */

/* The warp-info word (ad_su_sched's q_info, AD_WI_W bits). */
localparam AD_WI_W = 160;
localparam AD_WI_WGX = 0;	/* [15:0] workgroup id x (y at 16, z at 32) */
localparam AD_WI_NWGX = 48;	/* [63:48] workgroups x (y at 64, z at 80) */
localparam AD_WI_LID = 96;	/* [103:96] local index of lane 0 (lidn = LID + lane) */
localparam AD_WI_KIND = 104;	/* [105:104] 0 vertex, 1 fragment, 2 compute */
localparam AD_WI_FRONT = 106;	/* front facing (fragment) */
localparam AD_WI_SEQ = 112;	/* [127:112] fragment warp sequence number (ROP order) */
localparam AD_WI_MASK = 128;	/* [159:128] coverage / sample mask (operand 119) */

/*
 * Operation codes (AD_UOP_OP, 8 bits) per unit; tools/gsi1asm.py has the
 * same table.
 */
localparam AD_ALU_IMMB = 7;	/* OP bit: operand b is the immediate (I forms) */
localparam [4:0] AD_ALU_ADD = 5'd0;
localparam [4:0] AD_ALU_SUB = 5'd1;
localparam [4:0] AD_ALU_SLL = 5'd2;
localparam [4:0] AD_ALU_SLT = 5'd3;	/* Boolean */
localparam [4:0] AD_ALU_SLTU = 5'd4;	/* Boolean */
localparam [4:0] AD_ALU_XOR = 5'd5;
localparam [4:0] AD_ALU_SRL = 5'd6;
localparam [4:0] AD_ALU_SRA = 5'd7;
localparam [4:0] AD_ALU_OR = 5'd8;
localparam [4:0] AD_ALU_AND = 5'd9;
localparam [4:0] AD_ALU_MIN = 5'd10;
localparam [4:0] AD_ALU_MAX = 5'd11;
localparam [4:0] AD_ALU_MINU = 5'd12;
localparam [4:0] AD_ALU_MAXU = 5'd13;
localparam [4:0] AD_ALU_ANDN = 5'd14;
localparam [4:0] AD_ALU_ORN = 5'd15;
localparam [4:0] AD_ALU_XNOR = 5'd16;
localparam [4:0] AD_ALU_SEL = 5'd17;	/* (a & b) | (~a & c) */
localparam [4:0] AD_ALU_MOVI = 5'd18;	/* lui/movi: the immediate */

localparam [7:0] AD_FPU_FADD = 8'd0;
localparam [7:0] AD_FPU_FSUB = 8'd1;
localparam [7:0] AD_FPU_FMUL = 8'd2;
localparam [7:0] AD_FPU_FMADD = 8'd3;
localparam [7:0] AD_FPU_FMSUB = 8'd4;
localparam [7:0] AD_FPU_FNMSUB = 8'd5;
localparam [7:0] AD_FPU_FNMADD = 8'd6;
localparam [7:0] AD_FPU_FSGNJ = 8'd7;
localparam [7:0] AD_FPU_FMIN = 8'd8;
localparam [7:0] AD_FPU_FMAX = 8'd9;
localparam [7:0] AD_FPU_FCVTWS = 8'd10;
localparam [7:0] AD_FPU_FCVTWUS = 8'd11;
localparam [7:0] AD_FPU_FCVTSW = 8'd12;
localparam [7:0] AD_FPU_FCVTSWU = 8'd13;
localparam [7:0] AD_FPU_FEQ = 8'd14;
localparam [7:0] AD_FPU_FLT = 8'd15;
localparam [7:0] AD_FPU_FLE = 8'd16;
localparam [7:0] AD_FPU_FNE = 8'd17;
localparam [7:0] AD_FPU_FROUND = 8'd18;
localparam [7:0] AD_FPU_FRACT = 8'd19;
localparam [7:0] AD_FPU_MUL = 8'd20;
localparam [7:0] AD_FPU_MULH = 8'd21;
localparam [7:0] AD_FPU_MULHSU = 8'd22;
localparam [7:0] AD_FPU_MULHU = 8'd23;

localparam [7:0] AD_XU_RCP = 8'd0;
localparam [7:0] AD_XU_RSQ = 8'd1;
localparam [7:0] AD_XU_EXP2 = 8'd2;
localparam [7:0] AD_XU_LOG2 = 8'd3;
localparam [7:0] AD_XU_SIN = 8'd4;
localparam [7:0] AD_XU_COS = 8'd5;
localparam [7:0] AD_XU_FSQRT = 8'd6;

localparam [7:0] AD_DIV_DIV = 8'd0;
localparam [7:0] AD_DIV_DIVU = 8'd1;
localparam [7:0] AD_DIV_REM = 8'd2;
localparam [7:0] AD_DIV_REMU = 8'd3;

localparam [7:0] AD_PK_FADD2 = 8'd0;
localparam [7:0] AD_PK_FSUB2 = 8'd1;
localparam [7:0] AD_PK_FMUL2 = 8'd2;
localparam [7:0] AD_PK_FFMA2 = 8'd3;
localparam [7:0] AD_PK_FMIN2 = 8'd4;
localparam [7:0] AD_PK_FMAX2 = 8'd5;
localparam [7:0] AD_PK_IADD2 = 8'd6;
localparam [7:0] AD_PK_ISUB2 = 8'd7;
localparam [7:0] AD_PK_IMUL2 = 8'd8;
localparam [7:0] AD_PK_FCMPLT2 = 8'd9;
localparam [7:0] AD_PK_FCMPGE2 = 8'd10;
localparam [7:0] AD_PK_FCMPEQ2 = 8'd11;
localparam [7:0] AD_PK_FCMPNE2 = 8'd12;
localparam [7:0] AD_PK_PACKH = 8'd13;
localparam [7:0] AD_PK_UNPACKH = 8'd14;
localparam [7:0] AD_PK_SWAPH = 8'd15;

localparam [7:0] AD_LSU_LW = 8'd0;
localparam [7:0] AD_LSU_SW = 8'd1;
localparam [7:0] AD_LSU_ATOM = 8'd2;
localparam [7:0] AD_LSU_FENCE = 8'd3;	/* imm[2:0]; class a, ad_su_sb waits for cm = 0 */
localparam [7:0] AD_LDS_LDS = 8'd0;
localparam [7:0] AD_LDS_STS = 8'd1;
localparam [7:0] AD_LDS_ATOM = 8'd2;	/* atom with sub[4] (shared memory); sub[3:0] the operation */
localparam [7:0] AD_CBANK_LWC = 8'd0;
localparam [7:0] AD_TEX_TEXL = 8'd0;
localparam [7:0] AD_TEX_TEXB = 8'd1;
localparam [7:0] AD_TEX_TEXF = 8'd2;
localparam [7:0] AD_TEX_TEXSZ = 8'd3;
/* The TEX op's modifier bits (docs/ghci.md section 12.9): [2] .c (Dref in
 * rs1+2, the uop's rs3), [3] gather (texl), [5:4] its component, [6] query
 * (texb: the LOD, texsz: the level count), [7] set by ad_su_opd on the
 * second operand pass of a .c instruction (rs3 on x_a). */
localparam AD_TEX_CFORM = 2;
localparam AD_TEX_GATHER = 3;
localparam AD_TEX_COMP = 4;
localparam AD_TEX_QUERY = 6;
localparam AD_TEX_PASS2 = 7;
localparam [7:0] AD_EXP_EXP = 8'd0;
localparam [7:0] AD_LDA_LDA = 8'd0;
localparam [7:0] AD_LANE_QD = 8'd0;	/* sub 0-5 */
localparam [7:0] AD_LANE_SHFL = 8'd1;	/* sub 0-4 */
localparam [7:0] AD_LANE_VOTE = 8'd2;	/* sub 0 any, 1 all */
localparam [7:0] AD_LANE_BALLOT = 8'd3;
localparam [7:0] AD_EXEC_BANY = 8'd0;	/* branches 0-5: OP = BRANCH funct3 */
localparam [7:0] AD_EXEC_BNONE = 8'd1;
localparam [7:0] AD_EXEC_BALL = 8'd2;
localparam [7:0] AD_EXEC_J = 8'd3;
localparam [7:0] AD_EXEC_BEXNZ = 8'd4;
localparam [7:0] AD_EXEC_BEXZ = 8'd5;
localparam [7:0] AD_EXEC_SET = 8'd8;
localparam [7:0] AD_EXEC_AND = 8'd9;
localparam [7:0] AD_EXEC_OR = 8'd10;
localparam [7:0] AD_EXEC_SAVE = 8'd11;	/* rd = Boolean of the lane's EXEC bit, all lanes */
localparam [7:0] AD_EXEC_KILL = 8'd12;
localparam [7:0] AD_EXEC_END = 8'd13;
localparam [7:0] AD_EXEC_BAR = 8'd14;
localparam [7:0] AD_CTL_WAIT = 8'd0;	/* imm[3:0] cm, [7:4] ct, [11:8] cx */
localparam [7:0] AD_RQ_SACTL = 8'd0;

/* verilator lint_on UNUSEDPARAM */
