// fv_ad_vf_asm_carry -- carried vertices against spec section 4 ("the last two of a strip, the
// fan's first and last; the started vertices of a list primitive or a line strip's last"),
// in terms of the run slots (strip r0 older / r1 newer; fan r0 first / r1 last; line strip r1
// last; list r0 A / r1 B; a run with one vertex keeps it in r1 for strips, r0 otherwise).
module fv_ad_vf_asm_carry (input wire clk);
    (* anyconst *) reg [2:0] cls;
    (* anyconst *) reg [1:0] n;
    wire [1:0] cnt; wire c0_r1, r0_mv, r1_mv, r1_l;
    ad_vf_asm_carry dut (.cls(cls), .n(n), .cnt(cnt), .c0_r1(c0_r1), .r0_mv(r0_mv), .r1_mv(r1_mv), .r1_l(r1_l));
    reg [1:0] ecnt; reg ec0;   // expected number; lane 0 from r1
    always @(*) begin
        assume (n != 2'd3);
        if (cls == 3'd1) assume (n <= 2'd1);           // line list position 0..1
        if (cls == 3'd2) assume (n <= 2'd1);           // line strip keeps one
        if (cls == 3'd0 || cls >= 3'd6) assume (n == 2'd0);
        ecnt = 2'd0; ec0 = 1'b0;
        case (cls)
            3'd1: ecnt = n;                                       // started list vertex
            3'd2: begin ecnt = n; ec0 = 1'b1; end                 // line strip's last (r1)
            3'd3: ecnt = n;                                       // started triangle: A (, B)
            3'd4: begin ecnt = n; ec0 = (n == 2'd1); end          // strip: last two (or the one)
            3'd5: ecnt = n;                                       // fan: first (, last)
            default: ecnt = 2'd0;
        endcase
        a_cnt: assert (cnt == ecnt);
        if (cnt != 2'd0) a_c0: assert (c0_r1 == ec0);
        // lane 0 gets the first carried slot, lane 1 (when two) r1
        a_r0mv: assert (r0_mv == ((cnt == 2'd2) || (cnt == 2'd1 && !c0_r1)));
        a_r1mv: assert (r1_mv == ((cnt == 2'd2) || (cnt == 2'd1 && c0_r1)));
        if (r1_mv) a_r1l: assert (r1_l == (cnt == 2'd2));
        if (cnt == 2'd2) a_two: assert (!c0_r1);
    end
endmodule
