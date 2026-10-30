// FPV harness: ad_rx_order (assertions are in the module).
module ad_rx_order_fv (input logic clk, input logic rst_n, input logic sq_req);
  logic [15:0] sq_seq, ord_seq; logic ord_valid;
  ad_rx_order u (.clk, .rst_n, .sq_req, .sq_seq, .ord_valid, .ord_seq);
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(*) if (f_init) assume (!rst_n);
endmodule
