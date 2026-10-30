// ============================================================================
// ad_rx_coarse -- coarse tile walker (8 x 8 pixel tiles = 4 x 4 quads).
//
// Walks the triangle's bounding box tile by tile, one tile per cycle:
//   * empty tile  : some edge is negative at every pixel centre and every
//                   sample of the tile (E_max + lowm < 0), or Hi-Z rejects
//                   it -> skipped, no handshake (1 cycle)
//   * trivial tile: every edge >= 0 at every centre and sample
//                   (E_min - lowm >= 0) and the tile lies inside the bbox
//                   -> tile_trivial = 1, the fine walk can skip edge tests
//   * otherwise   : emitted with the edge values at the tile origin
// The extremes are taken over the pixel centres 0..7 of the tile (not the
// corners 0..8: exact for centres, still conservative), widened by the MSAA
// reach lowm from ad_rx_cov.
//
// Every triangle ends with exactly one tile_last handshake.  If the last
// tile is empty (or the bbox is empty) it is still sent, with tile_none = 1
// (no coverage), so ad_rx_scan always learns where a triangle ends.
//
// Edge values: subpixel^2 units, E at the pixel centre, top-left bias
// already folded in (inside <=> E >= 0).  a8 = A << 8, b8 = B << 8 are the
// changes per one-pixel step.  bbox max is exclusive.
// ============================================================================
module ad_rx_coarse #(
  parameter int CW = ad_rx_pkg::CRD_W,      // pixel coordinate width
  parameter int EW = ad_rx_pkg::EDGE_W,     // edge value width
  parameter bit SKIP = 1'b1                 // 0: emit every tile, no trivial accept
) (
  input  logic               clk,
  input  logic               rst_n,
  // triangle
  input  logic               tri_valid,
  output logic               tri_ready,
  input  logic [4*CW-1:0]    bbox,          // {ymax, xmax, ymin, xmin}
  input  logic [3*EW-1:0]    e_a8,          // per edge: A << 8
  input  logic [3*EW-1:0]    e_b8,          // per edge: B << 8
  input  logic [3*EW-1:0]    e_er,          // per edge: E at bbox origin centre
  input  logic [3*EW-1:0]    lowm,          // per edge: MSAA reach (0: 1 sample)
  // Hi-Z (combinational lookup of the tile under the walker)
  output logic [CW-1:0]      hz_tx,         // tile index x (pixel x >> 3)
  output logic [CW-1:0]      hz_ty,
  input  logic               hz_rej,
  // tiles to the fine walk
  output logic               tile_valid,
  input  logic               tile_ready,
  output logic [CW-1:0]      tile_x,        // pixel x of the tile origin (8-aligned)
  output logic [CW-1:0]      tile_y,
  output logic [3*EW-1:0]    tile_e,        // per edge: E at the tile origin centre
  output logic               tile_trivial,
  output logic               tile_last,
  output logic               tile_none,
  output logic               busy
);
  localparam int NE = ad_rx_pkg::NEDGE;
  localparam int TL = ad_rx_pkg::TILE_L2;
  localparam int XW = EW + 4;                     // headroom for E + 7*a8 + lowm

  typedef enum logic [1:0] {C_IDLE, C_INIT, C_WALK} cst_e;
  cst_e st;

  logic [CW-1:0] xmin, ymin, xmax, ymax, tx0;
  logic [CW-1:0] tx, ty;
  logic signed [EW-1:0] a8 [NE];
  logic signed [EW-1:0] b8 [NE];
  logic signed [EW-1:0] lm [NE];
  logic signed [EW-1:0] er [NE];
  logic signed [EW-1:0] ecur [NE];
  logic signed [EW-1:0] erow [NE];
  logic held;                                     // tile on the bus, kept
  logic held_skip;                                // its skip decision, frozen

  assign tri_ready = (st == C_IDLE);
  assign busy      = (st != C_IDLE);
  assign hz_tx     = tx >> TL;
  assign hz_ty     = ty >> TL;

  // ---- per-tile evaluation -------------------------------------------------
  logic        bb_empty;
  logic        last_x, last_y, is_last;
  logic [NE-1:0] e_neg, e_pos;
  logic signed [XW-1:0] dmax [NE];
  logic signed [XW-1:0] dmin [NE];
  logic signed [XW-1:0] s7a [NE];
  logic signed [XW-1:0] s7b [NE];
  logic        inside_bb, geo_empty, skip, trivial;

  always_comb begin
    bb_empty = (xmin >= xmax) || (ymin >= ymax);
    last_x   = (CW+1)'(tx) + (CW+1)'(ad_rx_pkg::TILE) >= (CW+1)'(xmax);
    last_y   = (CW+1)'(ty) + (CW+1)'(ad_rx_pkg::TILE) >= (CW+1)'(ymax);
    is_last  = bb_empty || (last_x && last_y);
    inside_bb = (tx >= xmin) && (ty >= ymin) &&
                ((CW+1)'(tx) + (CW+1)'(ad_rx_pkg::TILE) <= (CW+1)'(xmax)) &&
                ((CW+1)'(ty) + (CW+1)'(ad_rx_pkg::TILE) <= (CW+1)'(ymax));
    for (int e = 0; e < NE; e++) begin
      s7a[e]  = (XW'(a8[e]) <<< TL) - XW'(a8[e]);       // 7 * a8
      s7b[e]  = (XW'(b8[e]) <<< TL) - XW'(b8[e]);
      dmax[e] = (a8[e] > 0 ? s7a[e] : XW'(0)) + (b8[e] > 0 ? s7b[e] : XW'(0));
      dmin[e] = (a8[e] < 0 ? s7a[e] : XW'(0)) + (b8[e] < 0 ? s7b[e] : XW'(0));
      e_neg[e] = (XW'(ecur[e]) + dmax[e] + XW'(lm[e])) < 0;
      e_pos[e] = (XW'(ecur[e]) + dmin[e] - XW'(lm[e])) >= 0;
    end
    geo_empty = bb_empty || (SKIP && (|e_neg));
    skip      = held ? held_skip : (geo_empty || hz_rej);
    trivial   = SKIP && (&e_pos) && inside_bb;
  end

  // ---- outputs: the walker's current tile -------------------------------
  always_comb begin
    tile_valid   = (st == C_WALK) && (!skip || is_last);
    tile_x       = tx;
    tile_y       = ty;
    tile_last    = is_last;
    tile_none    = skip;               // only reachable on the last tile
    tile_trivial = trivial && !tile_none;
    for (int e = 0; e < NE; e++) tile_e[EW*e +: EW] = ecur[e];
  end

  // ---- walker -------------------------------------------------------------
  logic advance;
  assign advance = (st == C_WALK) && !is_last && (skip || tile_ready);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st   <= C_IDLE;
      held <= 1'b0;
      held_skip <= 1'b0;
      xmin <= '0; ymin <= '0; xmax <= '0; ymax <= '0; tx0 <= '0;
      tx   <= '0; ty <= '0;
      for (int e = 0; e < NE; e++) begin
        a8[e] <= '0; b8[e] <= '0; lm[e] <= '0; er[e] <= '0;
        ecur[e] <= '0; erow[e] <= '0;
      end
    end else begin
      case (st)
        C_IDLE: if (tri_valid) begin
          xmin <= bbox[0*CW +: CW];
          ymin <= bbox[1*CW +: CW];
          xmax <= bbox[2*CW +: CW];
          ymax <= bbox[3*CW +: CW];
          for (int e = 0; e < NE; e++) begin
            a8[e] <= e_a8[EW*e +: EW];
            b8[e] <= e_b8[EW*e +: EW];
            lm[e] <= lowm[EW*e +: EW];
            er[e] <= e_er[EW*e +: EW];
          end
          st <= C_INIT;
        end
        C_INIT: begin
          // move from the bbox origin to the enclosing tile's origin:
          // E -= (xmin & 7) * a8 + (ymin & 7) * b8   (3-bit constant multiply)
          tx0 <= {xmin[CW-1:TL], {TL{1'b0}}};
          tx  <= {xmin[CW-1:TL], {TL{1'b0}}};
          ty  <= {ymin[CW-1:TL], {TL{1'b0}}};
          for (int e = 0; e < NE; e++) begin
            ecur[e] <= er[e] - EW'($signed({1'b0, xmin[TL-1:0]}) * a8[e])
                             - EW'($signed({1'b0, ymin[TL-1:0]}) * b8[e]);
            erow[e] <= er[e] - EW'($signed({1'b0, xmin[TL-1:0]}) * a8[e])
                             - EW'($signed({1'b0, ymin[TL-1:0]}) * b8[e]);
          end
          held <= 1'b0;
          st   <= C_WALK;
        end
        C_WALK: begin
          if (tile_valid && !tile_ready && !held) begin
            held      <= 1'b1;
            held_skip <= skip;
          end
          if (tile_valid && tile_ready && is_last) begin
            held <= 1'b0;
            st   <= C_IDLE;
          end else if (advance) begin
            held <= 1'b0;
            if (last_x) begin
              tx <= tx0;
              ty <= ty + CW'(ad_rx_pkg::TILE);
              for (int e = 0; e < NE; e++) begin
                erow[e] <= erow[e] + (b8[e] <<< TL);
                ecur[e] <= erow[e] + (b8[e] <<< TL);
              end
            end else begin
              tx <= tx + CW'(ad_rx_pkg::TILE);
              for (int e = 0; e < NE; e++) ecur[e] <= ecur[e] + (a8[e] <<< TL);
            end
          end
        end
        default: st <= C_IDLE;
      endcase
    end
  end

`ifdef FORMAL
  // ---------------------------------------------------------------- FPV ----
  logic f_past = 1'b0;
  always_ff @(posedge clk) f_past <= 1'b1;
  initial assume (!rst_n);

  // environment: bbox inside a small render target so the walk is short
  // and edge arithmetic cannot wrap (the RTL widths are the real ones)
  // (bounds scale with EW so the proof can run at a reduced width)
  always_comb begin
    assume (bbox[2*CW +: CW] <= CW'(40) && bbox[3*CW +: CW] <= CW'(40));
    for (int e = 0; e < NE; e++) begin
      assume ($signed(e_a8[EW*e +: EW]) < $signed(EW'(1) <<< (EW-17)) && $signed(e_a8[EW*e +: EW]) > -$signed(EW'(1) <<< (EW-17)));
      assume ($signed(e_b8[EW*e +: EW]) < $signed(EW'(1) <<< (EW-17)) && $signed(e_b8[EW*e +: EW]) > -$signed(EW'(1) <<< (EW-17)));
      assume ($signed(e_er[EW*e +: EW]) < $signed(EW'(1) <<< (EW-8))  && $signed(e_er[EW*e +: EW]) > -$signed(EW'(1) <<< (EW-8)));
      assume ($signed(lowm[EW*e +: EW]) < $signed(EW'(1) <<< (EW-18)) && $signed(lowm[EW*e +: EW]) >= 0);
    end
  end

  // a free pixel (dx, dy) of the current tile and a free sample offset
  logic [2:0] f_dx, f_dy;
  logic signed [EW-1:0] f_off [NE];
  always_comb for (int e = 0; e < NE; e++)
    assume (f_off[e] <= lm[e] && f_off[e] >= -lm[e]);

  // reference edge value at the free pixel, computed from the bbox origin
  // (8-bit signed offsets: the environment keeps the bbox within 40 px)
  logic signed [7:0] f_ox, f_oy;
  logic signed [XW-1:0] f_eref [NE];
  logic signed [XW-1:0] f_ehere [NE];
  always_comb begin
    f_ox = 8'($signed({1'b0, tx}) - $signed({1'b0, xmin}));
    f_oy = 8'($signed({1'b0, ty}) - $signed({1'b0, ymin}));
    for (int e = 0; e < NE; e++) begin
      f_eref[e]  = XW'(er[e]) + f_ox * a8[e] + f_oy * b8[e];
      f_ehere[e] = XW'(ecur[e]) + $signed({1'b0, f_dx}) * a8[e]
                                + $signed({1'b0, f_dy}) * b8[e] + XW'(f_off[e]);
    end
  end

  always_ff @(posedge clk) if (f_past && rst_n && st == C_WALK) begin
    // incremental stepping equals the direct evaluation (row start too);
    // multiplier-heavy, so checked by bounded model checking (task bmc)
  `ifdef FPV_BMC
    for (int e = 0; e < NE; e++) begin
      assert (XW'(ecur[e]) == f_eref[e]);
      assert (XW'(erow[e]) == XW'(er[e]) + 8'($signed({1'b0, tx0}) - $signed({1'b0, xmin})) * a8[e]
                                         + f_oy * b8[e]);
    end
  `endif
    for (int e = 0; e < NE; e++) begin
      assert (a8[e] < $signed(EW'(1) <<< (EW-17)) && a8[e] > -$signed(EW'(1) <<< (EW-17)));
      assert (b8[e] < $signed(EW'(1) <<< (EW-17)) && b8[e] > -$signed(EW'(1) <<< (EW-17)));
      assert (er[e] < $signed(EW'(1) <<< (EW-8)) && er[e] > -$signed(EW'(1) <<< (EW-8)));
      assert (lm[e] < $signed(EW'(1) <<< (EW-18)) && lm[e] >= 0);
    end
    assert (tx0 == {xmin[CW-1:TL], {TL{1'b0}}});
    assert (tx >= tx0 && xmax <= CW'(40) && ymax <= CW'(40));
    // tiles are 8-aligned and overlap the bbox
    assert (tx[TL-1:0] == '0 && ty[TL-1:0] == '0);
    if (!bb_empty) begin
      assert ((CW+1)'(tx) + (CW+1)'(ad_rx_pkg::TILE) > (CW+1)'(xmin) && tx < xmax);
      assert ((CW+1)'(ty) + (CW+1)'(ad_rx_pkg::TILE) > (CW+1)'(ymin) && ty < ymax);
    end
    // SAFETY: a skipped edge is negative at every centre and sample of the tile
    for (int e = 0; e < NE; e++)
      if (SKIP && e_neg[e]) assert (f_ehere[e] < 0);
    // SAFETY: a trivial tile is covered at every centre and sample
    if (tile_valid && tile_trivial)
      for (int e = 0; e < NE; e++) assert (f_ehere[e] >= 0);
  end

  always_ff @(posedge clk) if (f_past && rst_n && $past(rst_n)) begin
    // valid/ready: a presented tile stays, unchanged, until taken
    if ($past(tile_valid && !tile_ready)) begin
      assert (tile_valid);
      assert (tile_x == $past(tile_x) && tile_y == $past(tile_y));
      assert (tile_last == $past(tile_last) && tile_e == $past(tile_e));
      assert (tile_trivial == $past(tile_trivial));
    end
    if (held) assert (st == C_WALK);
    // a triangle ends only through its tile_last handshake
    if ($past(st) == C_WALK && st == C_IDLE) assert ($past(tile_valid && tile_ready && tile_last));
    // tile_none only on the last tile
    if (tile_valid && tile_none) assert (tile_last);
  end

  // reachability
  always_ff @(posedge clk) if (rst_n) begin
    cover (tile_valid && tile_ready && tile_trivial);
    cover (tile_valid && tile_ready && tile_last && !tile_none && ty != '0);
    cover (st == C_WALK && skip && !is_last);
    cover (tile_valid && tile_last && tile_none);
  end
`endif
endmodule
