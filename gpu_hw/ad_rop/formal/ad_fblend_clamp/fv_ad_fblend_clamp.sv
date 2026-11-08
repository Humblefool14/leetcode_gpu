// ad_fblend_clamp: en = 0 passes x; en = 1 gives a non-NaN value in [+0, 1.0],
// equal to x when x is in [+0, 1.0], +0 for NaN/negatives, 1.0 above 1.0.
module fv_ad_fblend_clamp;
    (* anyconst *) reg [31:0] x;
    (* anyconst *) reg        en;
    wire [31:0] y;
    ad_fblend_clamp u (.en(en), .x(x), .y(y));
    wire nan = (x[30:23] == 8'hFF) && (x[22:0] != 0);
    always @(*) begin
        if (!en) a_pass: assert (y == x);
        if (en) a_range: assert (!y[31] && y <= 32'h3F80_0000);
        if (en && !x[31] && x <= 32'h3F80_0000) a_id: assert (y == x);
        if (en && (nan || x[31])) a_low: assert (y == 32'd0);
        if (en && !nan && !x[31] && x > 32'h3F80_0000) a_high: assert (y == 32'h3F80_0000);
    end
endmodule
