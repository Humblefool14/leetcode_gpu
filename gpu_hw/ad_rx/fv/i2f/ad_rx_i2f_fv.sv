// FPV harness: ad_rx_i2f.  Round trip: the fp32 result times 2^F converted back
// equals the input (checked through f2fix-free arithmetic on the fields).
module ad_rx_i2f_fv (input logic [20:0] v);
  logic [31:0] f;
  ad_rx_i2f #(.W(21), .F(3)) u (.v(v), .f(f));
  // reconstruct |v| from f: significand >> (23 - (e - 127 + 3))
  logic [7:0] e; logic [23:0] m; logic [20:0] back; logic [7:0] sh;
  always_comb begin
    e = f[30:23]; m = {1'b1, f[22:0]};
    sh = 8'd147 - e;   // 23 - (e - 127 + 3)
    back = (f == 0) ? 21'd0 : 21'(m >> sh);
    if (f[31]) back = -back;
    assert (back == v);                                     // exact
  end
endmodule
