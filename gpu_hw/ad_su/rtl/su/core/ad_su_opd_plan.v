// ad_su_opd_plan -- the operand plan of one lane-group pass (combinational leaf of
// ad_su_opd): the three operand numbers and their use, which of them are GPRs (0-62),
// and the RF reads: one read slot (port 1 = the first GPR operand, port 2 = the
// second) or, with three GPR operands, two slots (slot 0: a on port 1, b on port 2;
// slot 1: c on port 1).
// pass 0: a = rs1 (USE1), b = rs2 (USE2), c = PAIR ? rs1+1 : rs3 (PAIR || USE3).
// pass 1 (PAIR + USE3, the texture .c/.3 forms): a = rs3, b = rs2 (USE2), c = rs3+1.
module ad_su_opd_plan (
    input  wire [6:0] rs1,
    input  wire [6:0] rs2,
    input  wire [6:0] rs3,
    input  wire       use1,
    input  wire       use2,
    input  wire       use3,
    input  wire       pair,
    input  wire       pass,
    output wire [6:0] na,          // operand numbers
    output wire [6:0] nb,
    output wire [6:0] nc,
    output wire       ua,          // used
    output wire       ub,
    output wire       uc,
    output wire       ga,          // used GPR (0-62)
    output wire       gb,
    output wire       gc,
    output wire       two,         // three GPR operands: two read slots
    output wire [5:0] s0_r1,       // slot 0 registers
    output wire [5:0] s0_r2,
    output wire [5:0] s1_r1,       // slot 1 register (port 1)
    output wire       b_p2,        // single slot: b is on port 2 (else port 1)
    output wire       c_p2         // single slot: c is on port 2 (else port 1)
);
    assign na = pass ? rs3 : rs1;
    assign nb = rs2;
    assign nc = pass ? rs3 + 7'd1 : (pair ? rs1 + 7'd1 : rs3);
    assign ua = pass ? 1'b1 : use1;
    assign ub = use2;
    assign uc = pass ? 1'b1 : (pair || use3);
    assign ga = ua && na < 7'd63;
    assign gb = ub && nb < 7'd63;
    assign gc = uc && nc < 7'd63;
    assign two = ga && gb && gc;
    assign b_p2 = ga;
    assign c_p2 = ga || gb;
    // port 1: the first GPR operand; port 2: the second
    assign s0_r1 = ga ? na[5:0] : gb ? nb[5:0] : nc[5:0];
    assign s0_r2 = (ga && gb) ? nb[5:0] : nc[5:0];
    assign s1_r1 = nc[5:0];
endmodule
