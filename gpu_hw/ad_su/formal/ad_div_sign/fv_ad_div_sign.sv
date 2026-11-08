// fv_ad_div_sign: sign handling.
//  - full width (32): the RISC-V special cases whatever the core returns:
//    x / 0 = all ones (div, divu), x % 0 = x (rem, remu), INT_MIN / -1 =
//    INT_MIN, INT_MIN % -1 = 0; and the magnitudes ua = |a|, ub = |b|.
//  - reduced width (8): with the core's result uq = ua / ub, ur = ua % ub,
//    every op equals the RISC-V result (Verilog signed / and % truncate as
//    RISC-V does).
module fv_ad_div_sign;
    (* anyconst *) reg [1:0] op;
    (* anyconst *) reg [31:0] a, b, uq, ur;
    wire [31:0] ua, ub, res;
    ad_div_sign #(.W(32)) d32 (.op(op), .a(a), .b(b), .ua(ua), .ub(ub), .uq(uq), .ur(ur), .res(res));
    wire sgn = ~op[1] & ~op[0] | op[1] & ~op[0];
    always @(*) begin
        if (b == 32'd0)
            assert (res == (op[1] ? a : 32'hFFFFFFFF));
        if (!op[0] && a == 32'h80000000 && b == 32'hFFFFFFFF)
            assert (res == (op[1] ? 32'd0 : 32'h80000000));
        assert (ua == ((!op[0] && a[31]) ? -a : a));
        assert (ub == ((!op[0] && b[31]) ? -b : b));
    end

    (* anyconst *) reg [1:0] op8;
    (* anyconst *) reg [7:0] a8, b8;
    wire [7:0] ua8, ub8, res8;
    wire [7:0] uq8 = (ub8 == 0) ? 8'hFF : ua8 / ub8;
    wire [7:0] ur8 = (ub8 == 0) ? ua8 : ua8 % ub8;
    ad_div_sign #(.W(8)) d8 (.op(op8), .a(a8), .b(b8), .ua(ua8), .ub(ub8), .uq(uq8), .ur(ur8), .res(res8));
    reg [7:0] ref8;
    always @(*) begin
        if (b8 == 0)
            ref8 = op8[1] ? a8 : 8'hFF;
        else if (!op8[0] && a8 == 8'h80 && b8 == 8'hFF)
            ref8 = op8[1] ? 8'h00 : 8'h80;
        else case (op8)
            2'd0: ref8 = $signed(a8) / $signed(b8);
            2'd1: ref8 = a8 / b8;
            2'd2: ref8 = $signed(a8) % $signed(b8);
            default: ref8 = a8 % b8;
        endcase
        assert (res8 == ref8);
    end
endmodule
