// ad_blend_logicop: VkLogicOp truth-table identities; op k and op 15-k are bitwise complements.
module fv_ad_blend_logicop;
    (* anyconst *) reg [31:0] s, d;
    (* anyconst *) reg [3:0]  k;
    wire [31:0] y [0:15];
    wire [31:0] yk, yc;
    genvar i;
    generate for (i = 0; i < 16; i = i + 1) begin : g
        ad_blend_logicop u (.s(s), .d(d), .op(i[3:0]), .y(y[i]));
    end endgenerate
    ad_blend_logicop uk (.s(s), .d(d), .op(k),        .y(yk));
    ad_blend_logicop uc (.s(s), .d(d), .op(4'd15 - k), .y(yc));
    always @(*) begin
        a_compl: assert (yk == ~yc);
        a_clear: assert (y[0] == 32'd0);
        a_and:   assert (y[1] == (s & d));
        a_andr:  assert (y[2] == (s & ~d));
        a_copy:  assert (y[3] == s);
        a_andi:  assert (y[4] == (~s & d));
        a_noop:  assert (y[5] == d);
        a_xor:   assert (y[6] == (s ^ d));
        a_or:    assert (y[7] == (s | d));
        a_nor:   assert (y[8] == (~s & ~d));
        a_equiv: assert (y[9] == (s ^ ~d));
        a_inv:   assert (y[10] == ~d);
        a_orr:   assert (y[11] == ~(~s & d));
        a_copyi: assert (y[12] == ~s);
        a_ori:   assert (y[13] == ~(s & ~d));
        a_nand:  assert (y[14] == ~y[1]);
        a_set:   assert (y[15] == 32'hFFFFFFFF);
        // truth table: bit of op k at (s,d) = k[{s,d}] order: (1,1)->k[0]... VkLogicOp encodes
        // AND=1 -> only (1,1); i.e. bit = k[3 - {s,d}] read as k = {f(0,0), f(0,1), f(1,0), f(1,1)}
        a_tt: assert ((yk & ~s & ~d) == ({32{k[3]}} & ~s & ~d) && (yk & ~s & d) == ({32{k[2]}} & ~s & d) &&
                      (yk & s & ~d) == ({32{k[1]}} & s & ~d)   && (yk & s & d) == ({32{k[0]}} & s & d));
    end
endmodule
