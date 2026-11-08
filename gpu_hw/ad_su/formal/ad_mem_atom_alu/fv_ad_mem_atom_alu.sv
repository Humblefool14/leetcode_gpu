// fv_ad_mem_atom_alu -- formal harness of the atomic-operation leaf against
// a reference written differently (signed compares by the sign bits).
module fv_ad_mem_atom_alu;
    (* anyconst *) reg [3:0]  op;
    (* anyconst *) reg [31:0] old, a, cmp;
    wire [31:0] nv;
    ad_mem_atom_alu dut (.op(op), .old(old), .a(a), .cmp(cmp), .nv(nv));
    wire o_gt_a_s = (old[31] != a[31]) ? a[31] : (old[30:0] > a[30:0]);
    wire o_lt_a_s = (old[31] != a[31]) ? old[31] : (old[30:0] < a[30:0]);
    reg [31:0] r;
    always @(*) begin
        case (op)
            0: r = ~(~old | ~a);
            1: r = ~(~old & ~a);
            2: r = (old | a) & ~(old & a);
            3: r = a;
            4: r = old - (~a + 32'd1);
            5: r = old + (~a + 32'd1);
            6: r = o_gt_a_s ? old : a;
            7: r = o_lt_a_s ? old : a;
            8: r = (a < old) ? old : a;
            9: r = (a > old) ? old : a;
            default: r = (old ^ cmp) == 32'd0 ? a : old;
        endcase
        assert (nv == r);
    end
endmodule
