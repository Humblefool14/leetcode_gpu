// fv_ad_dec_imm: the immediate builder against a signed-arithmetic
// transcription of ad_su_dec.md §4 (sext(imm12) + (sext(imm_hi) << 12)),
// plus: the low 12 bits of an I/S/B immediate are the encoded imm12, and
// the U, texture and none cases.
module fv_ad_dec_imm (input wire clk);
    (* anyconst *) reg [63:0] instr;
    (* anyconst *) reg [2:0] fmt;
    (* anyconst *) reg tex;
    wire [31:0] imm;
    ad_su_dec_imm dut (.instr(instr), .fmt(fmt), .tex(tex), .imm(imm));
    wire [31:0] w0 = instr[31:0], w1 = instr[63:32];
    wire signed [31:0] hi = $signed(w1[31:22]) * 4096;
    wire signed [11:0] li = w0[31:20], ls = {w0[31:25], w0[11:7]},
                       lb = {w0[31], w0[7], w0[30:25], w0[11:8]};
    always @(*) begin
        case (fmt)
        3'd1: assert($signed(imm) == li + hi && imm[11:0] == w0[31:20]);
        3'd2: assert($signed(imm) == ls + hi && imm[11:0] == {w0[31:25], w0[11:7]});
        3'd3: assert($signed(imm) == lb + hi && imm[11:0] == lb);
        3'd4: assert(imm[31:12] == w0[31:12] && imm[11:0] == w1[13:2]);
        default: assert(imm == (tex ? (w1[25:22] | w1[29:26] << 4 | w1[13:10] << 8) : 0));
        endcase
    end
endmodule
