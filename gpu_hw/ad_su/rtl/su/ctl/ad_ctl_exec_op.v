// ad_ctl_exec_op -- the warp-control operation of one EXEC-unit instruction
// over the whole warp (ad_su_exec), as tools/gsi1model.py: bt is the Boolean
// of rs1 per lane (rs1 != 0).  Branches (op 0-5): bany bt&EXEC != 0, bnone
// bt&EXEC == 0, ball ~bt&EXEC == 0, j, bexnz EXEC != 0, bexz EXEC == 0;
// exec.set (8) EXEC = bt, exec.and (9) EXEC &= bt, exec.or (10) EXEC |= bt,
// kill (12) KILLED |= bt & EXEC.  wc: the instruction is a branch (wc_op 0),
// end (13, wc_op 1) or bar (14, wc_op 2).  Combinational.
module ad_ctl_exec_op (
    input  wire [7:0]  op,
    input  wire [31:0] bt,
    input  wire [31:0] exec_i,
    input  wire [31:0] killed_i,
    output reg  [31:0] exec_o,
    output reg  [31:0] killed_o,
    output reg         taken,
    output reg         wc,
    output reg  [1:0]  wc_op
);
    always @(*) begin
        exec_o   = exec_i;
        killed_o = killed_i;
        taken    = 1'b0;
        wc       = 1'b0;
        wc_op    = 2'd0;
        case (op)
        8'd0: begin wc = 1'b1; taken = (bt & exec_i) != 32'd0; end
        8'd1: begin wc = 1'b1; taken = (bt & exec_i) == 32'd0; end
`ifdef MUT_EXEC_BALL
        8'd2: begin wc = 1'b1; taken = (bt & exec_i) == exec_i && exec_i != 0; end   // mutation
`else
        8'd2: begin wc = 1'b1; taken = (~bt & exec_i) == 32'd0; end
`endif
        8'd3: begin wc = 1'b1; taken = 1'b1; end
        8'd4: begin wc = 1'b1; taken = exec_i != 32'd0; end
        8'd5: begin wc = 1'b1; taken = exec_i == 32'd0; end
        8'd8:  exec_o = bt;
        8'd9:  exec_o = exec_i & bt;
        8'd10: exec_o = exec_i | bt;
        8'd12: killed_o = killed_i | (bt & exec_i);
        8'd13: begin wc = 1'b1; wc_op = 2'd1; end
        8'd14: begin wc = 1'b1; wc_op = 2'd2; end
        default: ;
        endcase
    end
endmodule
