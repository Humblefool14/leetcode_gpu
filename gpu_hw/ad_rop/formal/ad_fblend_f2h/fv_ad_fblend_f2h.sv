// ad_fblend_f2h: h2f -> f2h is the identity for every non-NaN fp16 (so f2h rounds
// exactly-representable values to themselves, subnormals and -0 included); every
// NaN gives 0x7E00; the sign is kept for non-NaN inputs; f2h is monotonic on
// non-negative non-NaN fp32 (unsigned order of the bit patterns).
module fv_ad_fblend_f2h;
    (* anyconst *) reg [15:0] h;
    (* anyconst *) reg [31:0] a;
    (* anyconst *) reg [31:0] b;
    wire [31:0] f;  wire [15:0] hr, ha, hb;
    ad_fblend_h2f u_h2f (.h(h), .f(f));
    ad_fblend_f2h u_rt  (.f(f), .h(hr));
    ad_fblend_f2h u_a   (.f(a), .h(ha));
    ad_fblend_f2h u_b   (.f(b), .h(hb));
    wire h_nan = (h[14:10] == 5'h1F) && (h[9:0] != 0);
    wire a_nan = (a[30:23] == 8'hFF) && (a[22:0] != 0);
    wire b_nan = (b[30:23] == 8'hFF) && (b[22:0] != 0);
    always @(*) begin
        if (!h_nan) a_roundtrip: assert (hr == h);
        if (a_nan)  a_nan_out:   assert (ha == 16'h7E00);
        if (!a_nan) a_sign:      assert (ha[15] == a[31]);
        if (!a[31] && !b[31] && !a_nan && !b_nan && a <= b) a_mono: assert (ha <= hb);
    end
endmodule
