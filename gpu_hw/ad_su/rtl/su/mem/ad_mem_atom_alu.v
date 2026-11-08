// ad_mem_atom_alu -- the atomic operations (IR order, design §3.4.1;
// tools/gsi1model.py atom()): 0 and, 1 or, 2 xor, 3 xchg, 4 add, 5 sub,
// 6 smax, 7 smin, 8 umax, 9 umin, 10-15 cmpxchg (new = a when old == cmp).
// Combinational.  Used by ad_su_lds (atoms).
module ad_mem_atom_alu (
    input  wire [3:0]  op,
    input  wire [31:0] old,
    input  wire [31:0] a,
    input  wire [31:0] cmp,
    output reg  [31:0] nv
);
    wire sgt = $signed(old) > $signed(a);
    wire slt = $signed(old) < $signed(a);
    always @(*) begin
        case (op)
            4'd0: nv = old & a;
            4'd1: nv = old | a;
            4'd2: nv = old ^ a;
            4'd3: nv = a;
            4'd4: nv = old + a;
            4'd5: nv = old - a;
            4'd6: nv = sgt ? old : a;
            4'd7: nv = slt ? old : a;
            4'd8: nv = (old > a) ? old : a;
            4'd9: nv = (old < a) ? old : a;
            default: nv = (old == cmp) ? a : old;
        endcase
    end
endmodule
