// ============================================================================
// ad_rx_coarse -- coarse 8x8 tile walk of one triangle's bounding box.
//
// Units: E is an edge value in subpixel^2 at a pixel centre (top-left bias
// folded in: inside <=> E >= 0).  One pixel step in x adds A << FIX_FRC.
//
// Per tile (screen-aligned: tile_x = multiple of 8), for every edge:
//   Emax = Et + 7*max(A8,0) + 7*max(B8,0) + lowm    (lowm: MSAA sample reach)
//   Emin = Et + 7*min(A8,0) + 7*min(B8,0) - lowm
// Emax < 0 for some edge  -> the tile is skipped in one cycle (no output).
// Emin >= 0 for all edges and the tile lies inside the bbox -> tile_trivial.
//
// Fixes vs atg_rx_coarse:
//  * tiles are aligned to the screen's 8-pixel grid (atg aligned to the bbox
//    origin while claiming "aligned to 8 pixels"; Hi-Z needs screen tiles);
//  * walk_done pulses when the walk ends; atg's tile_last could not be raised
//    when the last tiles of the box were skipped;
//  * edge inputs are the 24-bit A, B (not 48-bit "A<<8" ports) and E is 48 bits;
//    the shifts are internal; internal sums are EDG_ACC + 4 bits wide;
//  * synchronous reset, valid/ready on both sides, data held while valid.
// ============================================================================
module ad_rx_coarse #(
  // widths default to the package; FPV runs the same RTL at reduced widths
  parameter int CW = ad_rx_pkg::CRD_WID,           // pixel coordinate
  parameter int AW = ad_rx_pkg::EDG_COF,           // edge A, B
  parameter int EW = ad_rx_pkg::EDG_ACC,           // edge value E
  parameter int FR = ad_rx_pkg::FIX_FRC            // subpixel bits
) (
  input  logic                               clk,
  input  logic                               rst_n,
  // triangle
  input  logic                               tri_valid,
  output logic                               tri_ready,
  input  logic [4*CW-1:0]                    bbox,      // {ymax, xmax, ymin, xmin}, max exclusive
  input  logic [3*(EW+2*AW)-1:0]             edges,     // 3 x {E, B, A}; E at the bbox origin's centre
  input  logic [3*EW-1:0]                    lowm,      // per edge sample reach (0: one sample)
  // tiles
  output logic                               tile_valid,
  input  logic                               tile_ready,
  output logic [CW-1:0]                      tile_x,
  output logic [CW-1:0]                      tile_y,
  output logic [3*EW-1:0]                    tile_e,    // E at the tile origin's centre
  output logic                               tile_trivial,
  output logic                               walk_done, // one cycle: no more tiles
  output logic                               busy
);
  localparam int PW = EW + 2*AW;
  localparam int XW = EW + 4;                      // internal headroom
  localparam int TS = ad_rx_pkg::TILE_SH;

  typedef enum logic [1:0] {C_IDLE, C_INIT, C_WALK} st_t;
  st_t st;

  logic [CW-1:0] bx0, by0, bx1, by1;               // held bbox
  logic [CW-1:0] tx, ty, tx0;
  logic signed [AW-1:0] ea [3];
  logic signed [AW-1:0] eb [3];
  logic signed [XW-1:0] e0 [3];                    // E at the bbox origin
  logic signed [XW-1:0] erow [3];                  // E at the current row's first tile
  logic signed [XW-1:0] ecur [3];                  // E at the current tile
  logic        [XW-1:0] lm [3];

  // ---------------------------------------------------------------- tile test
  logic signed [XW-1:0] a8 [3], b8 [3], emax [3], emin [3];
  logic [2:0] out_e, in_e;
  logic       inbox, skip, triv;
  for (genvar e = 0; e < 3; e++) begin : g_t
    assign a8[e] = XW'(ea[e]) <<< FR;
    assign b8[e] = XW'(eb[e]) <<< FR;
    // 7 * v = (v << 3) - v
    logic signed [XW-1:0] ap, an, bp, bn;
    assign ap = a8[e][XW-1] ? '0 : ((a8[e] <<< 3) - a8[e]);
    assign an = a8[e][XW-1] ? ((a8[e] <<< 3) - a8[e]) : '0;
    assign bp = b8[e][XW-1] ? '0 : ((b8[e] <<< 3) - b8[e]);
    assign bn = b8[e][XW-1] ? ((b8[e] <<< 3) - b8[e]) : '0;
    assign emax[e] = ecur[e] + ap + bp + $signed(lm[e]);
    assign emin[e] = ecur[e] + an + bn - $signed(lm[e]);
    assign out_e[e] = emax[e][XW-1];
    assign in_e[e]  = !emin[e][XW-1];
  end
  assign inbox = (tx >= bx0) && (ty >= by0) &&
                 ({1'b0, tx} + (CW+1)'(ad_rx_pkg::TILE_PX) <= {1'b0, bx1}) &&
                 ({1'b0, ty} + (CW+1)'(ad_rx_pkg::TILE_PX) <= {1'b0, by1});
  assign skip  = (ad_rx_pkg::EN_CRSE != 0) && (out_e != 3'b000);
  assign triv  = (in_e == 3'b111) && inbox;

  // ---------------------------------------------------------------- walk
  logic [CW:0] nx, ny;
  logic        last_col, last_row, adv;
  assign nx = {1'b0, tx} + (CW+1)'(ad_rx_pkg::TILE_PX);
  assign ny = {1'b0, ty} + (CW+1)'(ad_rx_pkg::TILE_PX);
  assign last_col = (nx >= {1'b0, bx1});
  assign last_row = (ny >= {1'b0, by1});
  assign adv = (st == C_WALK) && (skip || tile_ready);
  // a tile is offered combinationally in the cycle it is evaluated: one tile
  // per cycle when the scan is ready, one cycle per skipped tile
  assign tile_valid   = (st == C_WALK) && !skip;
  assign tile_trivial = triv;

  assign tri_ready = (st == C_IDLE);
  assign busy      = (st != C_IDLE);

  // E at the screen-aligned first tile: e0 - (bx0 mod 8) * A8 - (by0 mod 8) * B8
  // (shift-and-add over the 3 offset bits; no multiplier)
  logic signed [XW-1:0] einit [3];
  for (genvar e = 0; e < 3; e++) begin : g_i
    logic signed [XW-1:0] ox, oy;
    assign ox = (bx0[2] ? (a8[e] <<< 2) : '0) + (bx0[1] ? (a8[e] <<< 1) : '0) + (bx0[0] ? a8[e] : '0);
    assign oy = (by0[2] ? (b8[e] <<< 2) : '0) + (by0[1] ? (b8[e] <<< 1) : '0) + (by0[0] ? b8[e] : '0);
    assign einit[e] = e0[e] - ox - oy;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= C_IDLE; walk_done <= 1'b0;
      tx <= '0; ty <= '0; tx0 <= '0; bx0 <= '0; by0 <= '0; bx1 <= '0; by1 <= '0;
      for (int e = 0; e < 3; e++) begin
        ea[e] <= '0; eb[e] <= '0; e0[e] <= '0; erow[e] <= '0; ecur[e] <= '0; lm[e] <= '0;
      end
    end else begin
      walk_done <= 1'b0;
      case (st)
        C_IDLE: if (tri_valid) begin
          bx0 <= bbox[0 +: CW]; by0 <= bbox[CW +: CW];
          bx1 <= bbox[2*CW +: CW]; by1 <= bbox[3*CW +: CW];
          for (int e = 0; e < 3; e++) begin
            ea[e] <= edges[PW*e +: AW];
            eb[e] <= edges[PW*e + AW +: AW];
            e0[e] <= XW'($signed(edges[PW*e + 2*AW +: EW]));
            lm[e] <= XW'(lowm[EW*e +: EW]);
          end
          if (bbox[0 +: CW] >= bbox[2*CW +: CW] || bbox[CW +: CW] >= bbox[3*CW +: CW]) begin
            walk_done <= 1'b1;                     // empty box: nothing to walk
          end else
            st <= C_INIT;
        end
        C_INIT: begin                              // first tile: screen-aligned
          tx  <= {bx0[CW-1:TS], {TS{1'b0}}};
          tx0 <= {bx0[CW-1:TS], {TS{1'b0}}};
          ty  <= {by0[CW-1:TS], {TS{1'b0}}};
          for (int e = 0; e < 3; e++) begin
            erow[e] <= einit[e];
            ecur[e] <= einit[e];
          end
          st <= C_WALK;
        end
        C_WALK: begin
          if (adv) begin
            if (!last_col) begin
              tx <= nx[CW-1:0];
              for (int e = 0; e < 3; e++) ecur[e] <= ecur[e] + (a8[e] <<< TS);
            end else if (!last_row) begin
              tx <= tx0; ty <= ny[CW-1:0];
              for (int e = 0; e < 3; e++) begin
                erow[e] <= erow[e] + (b8[e] <<< TS);
                ecur[e] <= erow[e] + (b8[e] <<< TS);
              end
            end else begin
              st <= C_IDLE; walk_done <= 1'b1;
            end
          end
        end
        default: st <= C_IDLE;
      endcase
    end
  end

  assign tile_x = tx;
  assign tile_y = ty;
  for (genvar e = 0; e < 3; e++) begin : g_o
    assign tile_e[EW*e +: EW] = ecur[e][EW-1:0];
  end

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  // skip soundness: for any pixel centre (px, py) of the tile and any sample
  // delta within lowm, some edge is negative.  Trivial soundness likewise.
  (* anyconst *) logic [2:0] f_px, f_py;
  (* anyconst *) logic signed [XW-1:0] f_d0, f_d1, f_d2;
  logic signed [XW-1:0] f_ep [3];
  logic signed [XW-1:0] f_dd [3];
  assign f_dd[0] = f_d0; assign f_dd[1] = f_d1; assign f_dd[2] = f_d2;
  for (genvar e = 0; e < 3; e++) begin : g_f
    logic signed [XW-1:0] mx, my;
    assign mx = (f_px[2] ? (a8[e] <<< 2) : '0) + (f_px[1] ? (a8[e] <<< 1) : '0) + (f_px[0] ? a8[e] : '0);
    assign my = (f_py[2] ? (b8[e] <<< 2) : '0) + (f_py[1] ? (b8[e] <<< 1) : '0) + (f_py[0] ? b8[e] : '0);
    assign f_ep[e] = ecur[e] + mx + my + f_dd[e];
  end
  logic f_dok;
  assign f_dok = (f_d0 <= $signed(lm[0])) && (f_d0 >= -$signed(lm[0])) &&
                 (f_d1 <= $signed(lm[1])) && (f_d1 >= -$signed(lm[1])) &&
                 (f_d2 <= $signed(lm[2])) && (f_d2 >= -$signed(lm[2]));
  always @(posedge clk) if (f_vld && rst_n) begin
    if (st == C_WALK && skip && f_dok)
      assert (f_ep[0][XW-1] || f_ep[1][XW-1] || f_ep[2][XW-1]);
    if (st == C_WALK && triv && f_dok)
      assert (!f_ep[0][XW-1] && !f_ep[1][XW-1] && !f_ep[2][XW-1]);
    if (st == C_WALK) assert (tx[TS-1:0] == '0 && ty[TS-1:0] == '0);
    if (tile_valid) assert (st == C_WALK);
  end
  // a presented tile holds until taken
  always @(posedge clk) if (f_vld && rst_n && $past(rst_n) && $past(tile_valid && !tile_ready)) begin
    assert (tile_valid);
    assert (tile_x == $past(tile_x) && tile_y == $past(tile_y) && tile_trivial == $past(tile_trivial));
  end
`endif
endmodule
