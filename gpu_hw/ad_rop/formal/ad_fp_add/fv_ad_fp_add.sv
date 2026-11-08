// Algebraic properties of ad_fp_add that hold for every pair of fp32 inputs.
module fv_ad_fp_add;
    (* anyconst *) reg [31:0] a;
    (* anyconst *) reg [31:0] b;
    wire [31:0] ab, ba, nab, aminus, apz, asub;
    ad_fp_add u_ab  (.a(a), .b(b), .sub(1'b0), .y(ab));
    ad_fp_add u_ba  (.a(b), .b(a), .sub(1'b0), .y(ba));
    ad_fp_add u_nab (.a(a ^ 32'h8000_0000), .b(b ^ 32'h8000_0000), .sub(1'b0), .y(nab));
    ad_fp_add u_am  (.a(a), .b(a), .sub(1'b1), .y(aminus));
    ad_fp_add u_apz (.a(a), .b(32'd0), .sub(1'b0), .y(apz));
    ad_fp_add u_sub (.a(a), .b(b), .sub(1'b1), .y(asub));
    wire [31:0] ab_neg; wire [31:0] bneg = b ^ 32'h8000_0000;
    ad_fp_add u_abn (.a(a), .b(bneg), .sub(1'b0), .y(ab_neg));
    function nan(input [31:0] x); nan = (x[30:23] == 8'hFF) && (x[22:0] != 0); endfunction
    function inf(input [31:0] x); inf = (x[30:23] == 8'hFF) && (x[22:0] == 0); endfunction
    function den(input [31:0] x); den = (x[30:23] == 8'h00) && (x[22:0] != 0); endfunction
    always @(*) begin
        a_comm:    assert (ab == ba);                                         // a+b = b+a
        a_sub:     assert (asub == ab_neg);                                   // a-b = a+(-b)
        if (!nan(ab) && !(a[30:0] == 0 && b[30:0] == 0))
            a_sym: assert (nab == (ab ^ 32'h8000_0000) || (ab[30:0] == 0 && nab[30:0] == 0)); // (-a)+(-b) = -(a+b)
        if (!nan(a) && !inf(a))
            a_self: assert (aminus == 32'd0);                                 // a-a = +0
        if (!nan(a) && !den(a) && a != 32'h8000_0000)
            a_zero: assert (apz == a);                                        // a+0 = a
        a_noden:   assert (!den(ab));                                         // never a denormal
        if (nan(ab)) a_qnan: assert (ab == 32'h7FC0_0000);                    // canonical NaN
        if (nan(a) || nan(b)) a_nanp: assert (nan(ab));
    end
endmodule
