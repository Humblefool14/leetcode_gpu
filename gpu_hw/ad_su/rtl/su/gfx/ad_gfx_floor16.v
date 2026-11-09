// ad_gfx_floor16 -- floor of a non-negative fp32 value as a 16-bit integer (the RX's r4/r5,
// x + 0.5 and y + 0.5, spec ad_su_exp.md §4: the quad's position).  Negative values, zeros,
// denormals, values below 1 give 0; the integer's low 16 bits otherwise (Inf/NaN: undefined).
module ad_gfx_floor16 (
    input  wire [31:0] f,
    output wire [15:0] i
);
    wire [7:0] e = f[30:23];
    wire [23:0] m = {1'b1, f[22:0]};
    wire [7:0] sh = e - 8'd127;           // integer bits above the leading one
    wire [63:0] wide = {40'd0, m} << sh[5:0];
    // floor = (m << (e - 127)) >> 23; for e - 127 above 38 its low 16 bits are 0.
    wire [15:0] lo = wide[38:23];
    assign i = (f[31] || e < 8'd127 || e > 8'd165) ? 16'd0 : lo;
endmodule
