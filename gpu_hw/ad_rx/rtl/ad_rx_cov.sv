// ============================================================================
// ad_rx_cov -- MSAA sample offsets of the three edges, all 4 samples at once.
//
// Standard 4x locations (Vulkan) relative to the pixel centre, in subpixels:
//   s0 (-32,-96)  s1 (96,-32)  s2 (-96,32)  s3 (32,96)
// With P = 32A + 96B and Q = 96A - 32B the edge deltas are -P, +Q, -Q, +P.
//
// Fix vs atg: the atg block had a sequential i_start/i_step/i_sc interface
// (the old 4-cycle S_SAMP loop) while atg_rx_scan claimed 16 samples in one
// cycle; here the four per-edge deltas are registered at the triangle's load
// and the scan adds them in parallel.  Also: it now has a reset (atg had none).
// ============================================================================
module ad_rx_cov #(
  parameter int CW = ad_rx_pkg::EDG_COF,          // edge A, B width
  parameter int EW = ad_rx_pkg::EDG_ACC           // edge value width
) (
  input  logic                                clk,
  input  logic                                rst_n,
  input  logic                                i_load,   // the triangle's load: take A, B
  input  logic [3*2*CW-1:0]                   i_ab,     // edge e: {B, A} at bits 2CW e
  output logic [4*3*EW-1:0]                   o_dlt,    // delta of sample s, edge e at EW(3s + e)
  output logic [3*EW-1:0]                     o_lowm    // per edge, a power-of-two bound >= every |delta|
);

  logic signed [EW-1:0] p [3];
  logic signed [EW-1:0] q [3];
  logic        [EW-1:0] bnd [3];
`ifdef FORMAL
  logic f_vld = 1'b0;                              // a reset has been seen
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
`endif

  for (genvar e = 0; e < 3; e++) begin : g_e
    logic signed [CW-1:0] a, b;
    logic signed [EW-1:0] ax, bx;
    assign a  = i_ab[2*CW*e +: CW];
    assign b  = i_ab[2*CW*e + CW +: CW];
    assign ax = EW'(a);
    assign bx = EW'(b);
    // shifts and adds only: 32A + 96B = 32A + 64B + 32B, 96A - 32B
    logic signed [EW-1:0] pv, qv;
`ifdef MUT_COV_SKIP
    assign pv = (ax <<< 4) + (bx <<< 6);           // deliberately too small
`else
    assign pv = (ax <<< 5) + (bx <<< 6) + (bx <<< 5);
`endif
    assign qv = (ax <<< 6) + (ax <<< 5) - (bx <<< 5);

    // bound: next power of two above |P| | |Q|
    logic [EW-1:0] ap, aq, orv, sm;
    assign ap  = pv[EW-1] ? -pv : pv;
    assign aq  = qv[EW-1] ? -qv : qv;
    assign orv = ap | aq;
    always_comb begin
      sm = orv;
      for (int k = 1; k < EW; k = k * 2) sm = sm | (sm >> k);
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        p[e] <= '0; q[e] <= '0; bnd[e] <= '0;
      end else if (i_load) begin
        p[e] <= pv; q[e] <= qv; bnd[e] <= sm;     // all bits below the top bit of |P|||Q|, set
      end
    end

`ifdef MUT_SAMPLE_SWAP
    assign o_dlt[EW*(3*0+e) +: EW] = -p[e];
    assign o_dlt[EW*(3*1+e) +: EW] = -q[e];
    assign o_dlt[EW*(3*2+e) +: EW] =  q[e];
    assign o_dlt[EW*(3*3+e) +: EW] =  p[e];
`else
    assign o_dlt[EW*(3*0+e) +: EW] = -p[e];
    assign o_dlt[EW*(3*1+e) +: EW] =  q[e];
    assign o_dlt[EW*(3*2+e) +: EW] = -q[e];
    assign o_dlt[EW*(3*3+e) +: EW] =  p[e];
`endif
    assign o_lowm[EW*e +: EW] = bnd[e];

`ifdef FORMAL
    // every delta is within the bound (what the scan's skip test relies on)
    logic [EW-1:0] fp, fq;
    assign fp = p[e][EW-1] ? -p[e] : p[e];
    assign fq = q[e][EW-1] ? -q[e] : q[e];
    always_comb if (f_vld) begin
      assert (fp <= bnd[e]);
      assert (fq <= bnd[e]);
    end
`endif
  end
endmodule
