// fv_ad_vf_fmt_h2f -- ad_vf_fmt_h2f against an exact-value reference: for a finite non-zero
// fp16 h = M * 2^(E - 25) (M = 1024 + m for a normal, m for a denormal, E = max(e, 1)), the
// fp32 result must be normal, of the same sign, with {1, mantissa} == M << sh for the sh that
// makes the exponents agree (fp32 value {1,mant} * 2^(e32 - 150)); zeros keep the sign,
// infinities are kept, every NaN gives 0x7FC00000.  Input: anyconst h (all 65536 codes).
module fv_ad_vf_fmt_h2f (
    input wire clk
);
    (* anyconst *) reg [15:0] h;
    wire [31:0] f;
    ad_vf_fmt_h2f dut (.h(h), .f(f));

    wire [4:0]  he = h[14:10];
    wire [9:0]  hm = h[9:0];
    wire [23:0] M  = (he == 5'd0) ? {14'd0, hm} : {13'd0, 1'b1, hm};
    wire [8:0]  E  = (he == 5'd0) ? 9'd1 : {4'd0, he};
    wire [8:0]  e32 = {1'b0, f[30:23]};
    // value equality: {1,mant} * 2^(e32-150) == M * 2^(E-25)  <=>  {1,mant} == M << (E + 125 - e32)
    wire [8:0]  sh  = E + 9'd125 - e32;
    wire [47:0] Ms  = {24'd0, M} << sh;

    always @(*) begin
        if (he == 5'd31 && hm != 10'd0) a_nan: assert (f == 32'h7FC0_0000);
        else if (he == 5'd31)            a_inf: assert (f == {h[15], 8'hFF, 23'd0});
        else if (he == 5'd0 && hm == 10'd0) a_zero: assert (f == {h[15], 31'd0});
        else begin
            a_sign:  assert (f[31] == h[15]);
            a_norm:  assert (e32 != 9'd0 && e32 != 9'd255 && sh <= 9'd23);
            a_value: assert (Ms == {24'd0, 1'b1, f[22:0]});
        end
    end
endmodule
