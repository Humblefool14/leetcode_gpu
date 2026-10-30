// ============================================================================
// ad_rx_state -- the RX's copy of STATE, decoded once.
//
// NEW (fix): in atg_rx every child (clip, setup, scan, frag) snooped the
// STATE broadcast itself and kept its own copy; clip and setup each held a
// 16-entry viewport array.  Here one block keeps every RX register and the
// children take decoded fields.  A write to VIEWPORT (0x050-0x055) or SCISSOR
// (0x056-0x057) lands in entry VIEWPORT_IDX; the entry used for rasterizing is
// also VIEWPORT_IDX (per-draw select, see doc open items).  Contract kept from
// atg: the CP writes RX STATE only while RX_BUSY is low.
// ============================================================================
module ad_rx_state (
  input  logic                               clk,
  input  logic                               rst_n,
  input  logic                               st_we,
  input  logic [ad_rx_pkg::ST_IDXW-1:0]      st_idx,
  input  logic [ad_rx_pkg::ST_DATW-1:0]      st_wdata,
  output logic [6*32-1:0]                    o_vp,      // selected VIEWPORT: xs ys xo yo zmin zmax
  output logic [31:0]                        o_scmin,   // selected SCISSOR_MIN {y, x}
  output logic [31:0]                        o_scmax,
  output logic [2:0]                         o_cull,
  output logic [1:0]                         o_dclmp,
  output logic [31:0]                        o_rmode,
  output logic [6:0]                         o_varyc,   // 0-64 (larger reads as 64)
  output logic [4:0]                         o_msctl,
  output logic [3:0]                         o_skill,
  output logic [3*32-1:0]                    o_dbias,   // const, slope, clamp
  output logic [31:0]                        o_lwdth,
  output logic [31:0]                        o_psize,
  output logic [3:0]                         o_dfunc,   // [2:0] func, [3] Hi-Z enable
  output logic [31:0]                        o_rtsiz,
  output logic [9*32-1:0]                    o_rawv     // DRAW_RAW 3 x {x, y, z}
);
  localparam int NE = ad_rx_pkg::VP_ENTR;
  localparam int EW = ad_rx_pkg::VP_IDXW;

  logic [31:0]   vp_m [NE*6];
  logic [31:0]   sc_m [NE*2];
  logic [EW-1:0] vsel;
  logic [31:0]   rawv [9];
  logic [31:0]   varyc_w;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vsel <= '0; o_cull <= '0; o_dclmp <= '0; o_rmode <= '0; varyc_w <= '0; o_msctl <= '0;
      o_skill <= '0; o_dbias <= '0; o_lwdth <= ad_rx_pkg::FP_ONEV; o_psize <= ad_rx_pkg::FP_ONEV;
      o_dfunc <= '0; o_rtsiz <= '0;
      for (int i = 0; i < NE*2; i++) sc_m[i] <= '0;
    end else if (st_we) begin
      if (st_idx >= ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_VIEWP) && st_idx < ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_VIEWP + 6))
        vp_m[vsel * 6 + (st_idx - ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_VIEWP))] <= st_wdata;
      if (st_idx == ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_SCMIN)) sc_m[vsel * 2]     <= st_wdata;
      if (st_idx == ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_SCMAX)) sc_m[vsel * 2 + 1] <= st_wdata;
      case (st_idx)
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_VPIDX): vsel    <= st_wdata[EW-1:0];
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_CULLM): o_cull  <= st_wdata[2:0];
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_DCLMP): o_dclmp <= st_wdata[1:0];
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_RMODE): o_rmode <= st_wdata;
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_VARYC): varyc_w <= st_wdata;
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_MSCTL): o_msctl <= st_wdata[4:0];
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_SKILL): o_skill <= st_wdata[3:0];
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_DBCON): o_dbias[0 +: 32]  <= st_wdata;
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_DBSLP): o_dbias[32 +: 32] <= st_wdata;
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_DBCLP): o_dbias[64 +: 32] <= st_wdata;
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_LWDTH): o_lwdth <= st_wdata;
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_PSIZE): o_psize <= st_wdata;
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_DFUNC): o_dfunc <= st_wdata[3:0];
        ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_RTSIZ): o_rtsiz <= st_wdata;
        default: ;
      endcase
      if (st_idx >= ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_RAWV0) && st_idx < ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_RAWV0 + 9))
        rawv[st_idx - ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_RAWV0)] <= st_wdata;
    end
  end

  for (genvar i = 0; i < 6; i++) begin : g_vp
    assign o_vp[32*i +: 32] = vp_m[vsel * 6 + i];
  end
  for (genvar i = 0; i < 9; i++) begin : g_rw
    assign o_rawv[32*i +: 32] = rawv[i];
  end
  assign o_scmin = sc_m[vsel * 2];
  assign o_scmax = sc_m[vsel * 2 + 1];
  assign o_varyc = (varyc_w > 32'd64) ? 7'd64 : varyc_w[6:0];   // the whole word is compared

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  always @(*) if (f_vld) assert (o_varyc <= 7'd64);
  // a write to CULL lands and nothing else changes it
  always @(posedge clk) if (f_vld && rst_n && $past(rst_n)) begin
    if ($past(st_we) && $past(st_idx) == ad_rx_pkg::ST_IDXW'(ad_rx_pkg::S_CULLM)) assert (o_cull == $past(st_wdata[2:0]));
    else assert (o_cull == $past(o_cull));
    if (!$past(st_we)) assert (o_vp == $past(o_vp) && o_scmin == $past(o_scmin));
  end
`endif
endmodule
