// ad_rop_f2u8 (spec algorithm) equals the generic ad_f2unorm #(8) for every
// fp32 input, saturates at 0 and 255 as the spec says, and is monotonic.
module fv_ad_rop_f2u8;
    (* anyconst *) reg [31:0] f;
    (* anyconst *) reg [31:0] g;
    wire [7:0] u, ur, v;
    ad_rop_f2u8         dut  (.f(f), .u(u));
    ad_f2unorm #(.N(8)) ref0 (.f(f), .u(ur));
    ad_rop_f2u8         dut2 (.f(g), .u(v));
    wire f_nan = (f[30:23] == 8'hFF) && (f[22:0] != 0);
    wire g_nan = (g[30:23] == 8'hFF) && (g[22:0] != 0);
    always @(*) begin
        a_equiv: assert (u == ur);
        if (f_nan || f[31])               a_zero: assert (u == 8'd0);
        if (!f_nan && !f[31] && f[30:23] >= 8'd127) a_sat: assert (u == 8'd255);
        if (!f[31] && !g[31] && !f_nan && !g_nan && f[30:0] <= g[30:0]) a_mono: assert (u <= v);
    end
endmodule
