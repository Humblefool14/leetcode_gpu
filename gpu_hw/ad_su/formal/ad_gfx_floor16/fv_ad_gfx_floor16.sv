// fv_ad_gfx_floor16 -- ad_gfx_floor16 (combinational) against a second formulation: for a
// positive normal f with exponent e, floor(f) = m >> (150 - e) for e <= 150 and m << (e - 150)
// above (m the 24-bit significand); the low 16 bits; 0 for negative values and below 1.
module fv_ad_gfx_floor16;
    (* anyconst *) reg [31:0] f;
    wire [15:0] i;
    ad_gfx_floor16 dut (.f(f), .i(i));
    wire [7:0] e = f[30:23];
    wire [23:0] m = {1'b1, f[22:0]};
    wire [7:0] rs = 8'd150 - e;
    wire [7:0] ls = e - 8'd150;
    wire [23:0] down = m >> rs;
    wire [63:0] up = {40'd0, m} << ls;
    wire [15:0] ref_i = (f[31] || e < 8'd127) ? 16'd0 :
                        (e <= 8'd150) ? down[15:0] :
                        (ls >= 8'd16) ? 16'd0 : up[15:0];
    always @(*) begin
        if (e != 8'd255) assert (i == ref_i);
    end
endmodule
