// ad_fblend_h2f -- fp16 to fp32, exact.  fp16 subnormals become normal fp32,
// +-inf -> +-inf, NaN -> 0x7FC00000 (sign dropped), +-0 -> +-0.  Combinational.
module ad_fblend_h2f (
    input  wire [15:0] h,
    output wire [31:0] f
);
    wire       s = h[15];
    wire [4:0] e = h[14:10];
    wire [9:0] m = h[9:0];
    // leading zeros of the subnormal mantissa (m != 0)
    reg  [3:0] lz;
    integer i;
    always @(*) begin
        lz = 4'd0;
        for (i = 0; i < 10; i = i + 1)
            if (m[i]) lz = 4'd9 - i[3:0];
    end
    wire [10:0] mn  = {1'b0, m} << (lz + 4'd1);     // hidden one shifted out at bit 10
    wire [7:0]  esub = 8'd112 - {4'd0, lz};         // 2^(-15-lz) -> biased 127-15-lz
    assign f = (e == 5'd31) ? ((m != 10'd0) ? 32'h7FC0_0000 : {s, 8'hFF, 23'd0}) :
               (e == 5'd0)  ? ((m == 10'd0) ? {s, 31'd0} : {s, esub, mn[9:0], 13'd0}) :
                              {s, {3'd0, e} + 8'd112, m, 13'd0};
endmodule
