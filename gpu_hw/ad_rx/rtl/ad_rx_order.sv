// ============================================================================
// ad_rx_order -- fragment sequence numbers in primitive order.
// sq_seq is the current counter (combinational); each sq_req takes it and
// increments; ord_* echo the issue one cycle later for the ROP's scoreboard.
// Fix vs atg: the atg spec listed this block as an all-zero stub although
// every other block depends on it; implemented here.
// ============================================================================
module ad_rx_order (
  input  logic                           clk,
  input  logic                           rst_n,
  input  logic                           sq_req,
  output logic [ad_rx_pkg::SEQ_WID-1:0]  sq_seq,
  output logic                           ord_valid,
  output logic [ad_rx_pkg::SEQ_WID-1:0]  ord_seq
);
  localparam int SW = ad_rx_pkg::SEQ_WID;
  logic [SW-1:0] cnt;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cnt <= '0; ord_valid <= 1'b0; ord_seq <= '0;
    end else begin
      ord_valid <= sq_req;
      if (sq_req) begin
        ord_seq <= cnt;
        cnt     <= cnt + 1'b1;                     // wraps; the ROP compares modulo 2^SW
      end
    end
  end
  assign sq_seq = cnt;

`ifdef FORMAL
  logic f_init = 1'b1;
  always @(posedge clk) begin
    f_init <= 1'b0;
    if (!f_init && $past(rst_n)) begin
      assert (cnt == $past(cnt) + ($past(sq_req) ? 1'b1 : 1'b0));
      assert (ord_valid == $past(sq_req));
      if (ord_valid) assert (ord_seq == $past(cnt));
      if (ord_valid) assert (ord_seq + 1'b1 == cnt);
    end
  end
`endif
endmodule
