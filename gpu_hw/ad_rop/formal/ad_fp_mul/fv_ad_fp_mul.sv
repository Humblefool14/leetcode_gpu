// Properties of ad_fp_mul that hold for every fp32 input pair.
module fv_ad_fp_mul;
    (* anyconst *) reg [31:0] a;
    (* anyconst *) reg [31:0] b;
    wire [31:0] ab, a1, an1, a2;
    ad_fp_mul u_ab  (.a(a), .b(b), .y(ab));
    ad_fp_mul u_a1  (.a(a), .b(32'h3F80_0000), .y(a1));    // x * 1
    ad_fp_mul u_an1 (.a(a), .b(32'hBF80_0000), .y(an1));   // x * -1
    ad_fp_mul u_a2  (.a(a), .b(32'h4000_0000), .y(a2));    // x * 2
    function nan(input [31:0] x); nan = (x[30:23] == 8'hFF) && (x[22:0] != 0); endfunction
    function inf(input [31:0] x); inf = (x[30:23] == 8'hFF) && (x[22:0] == 0); endfunction
    function den(input [31:0] x); den = (x[30:23] == 8'h00) && (x[22:0] != 0); endfunction
    function zro(input [31:0] x); zro = (x[30:23] == 8'h00); endfunction  // zero or flushed denormal
    always @(*) begin
        if (!nan(a) && !den(a)) a_one:  assert (a1 == a);
        if (!nan(a) && !den(a)) a_neg:  assert (an1 == (a ^ 32'h8000_0000));
        if (!nan(a) && !den(a) && !inf(a) && a[30:23] < 8'hFE && !zro(a))
            a_two: assert (a2 == {a[31], a[30:23] + 8'd1, a[22:0]});
        if (!nan(ab)) a_sign: assert (ab[31] == (a[31] ^ b[31]));
        if ((inf(a) && zro(b)) || (zro(a) && inf(b))) a_0inf: assert (ab == 32'h7FC0_0000);
        a_noden: assert (!den(ab));
        if (nan(ab)) a_qnan: assert (ab == 32'h7FC0_0000);
    end
endmodule
