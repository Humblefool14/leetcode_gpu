// ad_ms_cov: the mask is a subset of sin & the lanes' bits; one sample never
// sets a bit other than 4 l; without alpha to coverage it is exactly
// sin & lanes (four) or sin[4l] & lanes[l] (one).
module fv_ad_ms_cov;
    (* anyconst *) reg four, a2c;
    (* anyconst *) reg [15:0] sin, a2c_m;
    (* anyconst *) reg [3:0] lanes, a2c_h;
    wire [15:0] sm;
    ad_ms_cov u (.four(four), .a2c(a2c), .sin(sin), .lanes(lanes), .a2c_m(a2c_m), .a2c_h(a2c_h), .smask(sm));
    wire [15:0] lb = {{4{lanes[3]}}, {4{lanes[2]}}, {4{lanes[1]}}, {4{lanes[0]}}};
    always @(*) begin
        a_sub: assert ((sm & ~(sin & lb)) == 16'd0);
        if (!four) a_one: assert ((sm & 16'hEEEE) == 16'd0);
        if (four && a2c) a_a2c: assert ((sm & ~a2c_m) == 16'd0);
        if (!four && a2c) a_h: assert ((sm & ~{3'd0, a2c_h[3], 3'd0, a2c_h[2], 3'd0, a2c_h[1], 3'd0, a2c_h[0]}) == 16'd0);
        if (!a2c) a_exact: assert (sm == (four ? (sin & lb) : (sin & lb & 16'h1111)));
    end
endmodule
