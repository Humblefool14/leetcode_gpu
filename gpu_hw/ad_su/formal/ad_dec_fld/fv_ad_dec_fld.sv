// fv_ad_dec_fld: the operand-number builder: each 7-bit number is
// {word1 high bits, word0 low bits} at the positions of ad_su_dec.md §4
// (rd w1[1:0], rs1 w1[3:2], rs2 w1[5:4], rs3 w0[31:27] + w1[7:6]),
// written as bit-by-bit checks of the 64-bit instruction.
module fv_ad_dec_fld (input wire clk);
    (* anyconst *) reg [63:0] instr;
    wire [6:0] opc, f7, rd, rs1, rs2, rs3, mods;
    wire [2:0] f3;
    wire [4:0] rs2f, sub;
    wire [1:0] fmt2, hsel;
    wire [11:0] imm12;
    ad_su_dec_fld dut (.instr(instr), .opc(opc), .f3(f3), .f7(f7), .rs2f(rs2f), .fmt2(fmt2),
        .imm12(imm12), .rd(rd), .rs1(rs1), .rs2(rs2), .rs3(rs3), .mods(mods), .hsel(hsel),
        .sub(sub));
    integer i;
    always @(*) begin
        for (i = 0; i < 5; i = i + 1) begin
            assert(rd[i] == instr[7 + i] && rs1[i] == instr[15 + i] && rs2[i] == instr[20 + i] &&
                   rs3[i] == instr[27 + i]);
        end
        for (i = 0; i < 2; i = i + 1)
            assert(rd[5 + i] == instr[32 + i] && rs1[5 + i] == instr[34 + i] &&
                   rs2[5 + i] == instr[36 + i] && rs3[5 + i] == instr[38 + i]);
        assert({imm12, rs1[4:0], f3, rd[4:0], opc} == instr[31:0]);
        assert(f7 == imm12[11:5] && rs2f == imm12[4:0] && fmt2 == f7[1:0]);
        assert({sub, hsel, mods} == instr[53:40]);
    end
endmodule
