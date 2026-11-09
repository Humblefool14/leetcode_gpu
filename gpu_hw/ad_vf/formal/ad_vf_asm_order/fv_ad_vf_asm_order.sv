// fv_ad_vf_asm_order -- the provoking rotation against the vertex orders of spec section 4,
// written as vertex numbers: the inputs are the lanes of the primitive's vertices
//   strip: x = v_i, y = v_i+1, z = v_i+2 (par = i % 2); fan: x = v_i+1, y = v_i+2, z = v_0;
//   list: (A, B, V) = (x, y, z); line: (a, b) = (x, y); point: p = x.
// Spec: strip first (i, i+1+i%2, i+2-i%2), last (i+2, i+i%2, i+1-i%2); fan first (i+1, i+2, 0),
// last (i+2, 0, i+1); list (A,B,V) / (V,A,B); line (a,b,b) / (b,a,a); point (p,p,p).
// Also: for triangles, the last-vertex order is a rotation of the first-vertex order (winding kept).
module fv_ad_vf_asm_order (input wire clk);
    (* anyconst *) reg [2:0] cls;
    (* anyconst *) reg prov, par;
    (* anyconst *) reg [4:0] x, y, z;
    wire [4:0] l0, l1, l2;
    ad_vf_asm_order dut (.cls(cls), .prov(prov), .par(par), .x(x), .y(y), .z(z), .l0(l0), .l1(l1), .l2(l2));
    // second instance with the other provoking mode (rotation check)
    wire [4:0] f0, f1, f2;
    ad_vf_asm_order dut_f (.cls(cls), .prov(1'b0), .par(par), .x(x), .y(y), .z(z), .l0(f0), .l1(f1), .l2(f2));

    // vertex by offset from v_i for the strip (0 -> x, 1 -> y, 2 -> z)
    function [4:0] sv(input [1:0] o); sv = (o == 2'd0) ? x : (o == 2'd1) ? y : z; endfunction
    reg [4:0] e0, e1, e2;
    always @(*) begin
        case (cls)
            3'd1, 3'd2: begin e0 = prov ? y : x; e1 = prov ? x : y; e2 = e1; end
            3'd3:       begin e0 = prov ? z : x; e1 = prov ? x : y; e2 = prov ? y : z; end
            3'd4: begin
                if (!prov) begin e0 = sv(2'd0); e1 = sv(2'd1 + {1'b0, par}); e2 = sv(2'd2 - {1'b0, par}); end
                else       begin e0 = sv(2'd2); e1 = sv({1'b0, par});        e2 = sv(2'd1 - {1'b0, par}); end
            end
            3'd5:       begin e0 = prov ? y : x; e1 = prov ? z : y; e2 = prov ? x : z; end
            default:    begin e0 = x; e1 = x; e2 = x; end
        endcase
        a_slot0: assert (l0 == e0);
        a_slot1: assert (l1 == e1);
        a_slot2: assert (l2 == e2);
        if (cls >= 3'd3 && cls <= 3'd5 && prov)
            a_rot: assert ({l0, l1, l2} == {f2, f0, f1} || {l0, l1, l2} == {f1, f2, f0});
    end
endmodule
