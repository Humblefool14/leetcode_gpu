// ============================================================================
// ad_rx_hiz -- hierarchical early-Z: one entry per 8x8 screen tile.
//
// Entry = {gen, mask[63:0], z}.  An entry is valid when gen == cur_gen.
//   z    : LESS family   -> the largest depth written to the tile this generation
//          GREATER family -> the smallest
//   mask : the tile's pixels written this generation
// Update (from the ROP's depth write, depth as unorm rounded away from the
// test direction): mask |= pixel; z = max (or min) of z and the new depth.
// Query (from the scan, one tile per cycle, answer the next cycle):
//   LESS/LEQUAL:      reject when en && valid && mask full && tri_zmin > z
//   GREATER/GEQUAL:   reject when en && valid && mask full && tri_zmax < z
//
// Fixes vs atg_rx_hiz (a stub with hiz_cull = 0) and vs early_z_unit:
//  * a tile only rejects once EVERY pixel of it was written this generation
//    (early_z_unit seeded the tile max from the first write and could reject
//    fragments over pixels still holding the clear depth);
//  * the generation counter skips 0 (= never valid) and, when it wraps, every
//    entry is scrubbed to gen 0 (early_z_unit aliased entries 2^GEN_W clears old);
//  * a change of depth-function family invalidates every entry (a new
//    generation) instead of relying on a driver contract;
//  * one writer per register (early_z_unit drove occ_tile_reject from two
//    always_ff blocks); synchronous reset.
// ============================================================================
module ad_rx_hiz #(
  parameter int AW  = ad_rx_pkg::HZ_ADRW,          // tile address bits
  parameter int TXW = ad_rx_pkg::HZ_TLXW,          // tile-x bits (tiles per row = 2^TXW)
  parameter int GW  = ad_rx_pkg::HZ_GENW,          // generation bits
  parameter int DW  = ad_rx_pkg::HZ_DEPW           // depth bits
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         i_en,      // Hi-Z culling enabled (DEPTH_FUNC[3])
  input  logic [2:0]                   i_func,    // DEPTH_FUNC: 1 LESS 3 LEQUAL 4 GREATER 6 GEQUAL
  input  logic                         i_clear,   // depth buffer cleared (one cycle)
  // query
  input  logic                         q_valid,
  input  logic [ad_rx_pkg::CRD_WID-1:0] q_tx,     // tile coordinates (pixels >> 3)
  input  logic [ad_rx_pkg::CRD_WID-1:0] q_ty,
  input  logic [DW-1:0]                q_zmin,    // triangle's nearest depth, rounded down
  input  logic [DW-1:0]                q_zmax,    // triangle's farthest depth, rounded up
  output logic                         r_valid,   // the cycle after q_valid
  output logic                         r_reject,
  // update from the ROP
  input  logic                         u_valid,
  input  logic [ad_rx_pkg::CRD_WID-1:0] u_x,      // pixel
  input  logic [ad_rx_pkg::CRD_WID-1:0] u_y,
  input  logic [DW-1:0]                u_z,
  output logic                         busy       // scrubbing (queries answer "keep")
);
  localparam int TYW = AW - TXW;
  localparam int NT  = 1 << AW;
  localparam int MW  = ad_rx_pkg::HZ_MSKW;
  localparam int TS  = ad_rx_pkg::TILE_SH;
  localparam int CW  = ad_rx_pkg::CRD_WID;

  logic [GW-1:0] gen_m [NT];
  logic [MW-1:0] msk_m [NT];
  logic [DW-1:0] z_m   [NT];

  // ---------------------------------------------------------------- family
  logic less_f, grtr_f, fam_ok, fam_q, fam_v;      // fam_q: latched family (1 greater)
  assign less_f = (i_func == 3'd1) || (i_func == 3'd3);
  assign grtr_f = (i_func == 3'd4) || (i_func == 3'd6);
  assign fam_ok = less_f || grtr_f;

  // ---------------------------------------------------------------- generations
  logic [GW-1:0] cur_gen;
  logic [AW-1:0] scr;
  logic          scrub;
  logic          bump;
  assign bump = i_clear || (fam_ok && fam_v && (grtr_f != fam_q)) || (fam_ok && !fam_v);
  assign busy = scrub;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cur_gen <= GW'(1); scrub <= 1'b1; scr <= '0;  // scrub once after reset (no RAM init assumed)
      fam_q <= 1'b0; fam_v <= 1'b0;
    end else begin
      if (fam_ok) begin fam_q <= grtr_f; fam_v <= 1'b1; end
      if (scrub) begin
        scr <= scr + 1'b1;
        if (scr == AW'(NT - 1)) scrub <= 1'b0;
      end
      if (bump) begin
        if (cur_gen == {GW{1'b1}}) begin           // wrap: 1 again, scrub every entry
          cur_gen <= GW'(1); scrub <= 1'b1; scr <= '0;
        end else
          cur_gen <= cur_gen + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------- update (RMW, one cycle)
  logic          u_in;
  logic [AW-1:0] u_a;
  logic [5:0]    u_bit;
  assign u_in  = (u_x[CW-1:TS] < (CW-TS)'(1 << TXW)) && (u_y[CW-1:TS] < (CW-TS)'(1 << TYW));
  assign u_a   = {u_y[TS +: TYW], u_x[TS +: TXW]};
  assign u_bit = {u_y[TS-1:0], u_x[TS-1:0]};

  logic          u_old;
  logic [MW-1:0] u_msk;
  logic [DW-1:0] u_zn;
  assign u_old = (gen_m[u_a] == cur_gen);
  assign u_msk = (u_old ? msk_m[u_a] : '0) | (MW'(1) << u_bit);
  always_comb begin
    if (!u_old)                       u_zn = u_z;
    else if (fam_q)                   u_zn = (u_z < z_m[u_a]) ? u_z : z_m[u_a];
    else                              u_zn = (u_z > z_m[u_a]) ? u_z : z_m[u_a];
  end

  always_ff @(posedge clk) begin
    if (scrub)
      gen_m[scr] <= '0;
    else if (u_valid && u_in && !bump) begin       // an update in a bump cycle is dropped (safe)
      gen_m[u_a] <= cur_gen;
      msk_m[u_a] <= u_msk;
      z_m[u_a]   <= u_zn;
    end
  end

  // ---------------------------------------------------------------- query (registered answer)
  logic          q_in;
  logic [AW-1:0] q_a;
  logic          rej_c;
  assign q_in = (q_tx < CW'(1 << TXW)) && (q_ty < CW'(1 << TYW));
  assign q_a  = {q_ty[TYW-1:0], q_tx[TXW-1:0]};
  always_comb begin
    rej_c = 1'b0;
    if (i_en && fam_ok && fam_v && (grtr_f == fam_q) && !scrub && !bump && q_in &&
        gen_m[q_a] == cur_gen && msk_m[q_a] == {MW{1'b1}})
      rej_c = grtr_f ? (q_zmax < z_m[q_a]) : (q_zmin > z_m[q_a]);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin r_valid <= 1'b0; r_reject <= 1'b0; end
    else begin
      r_valid  <= q_valid;
      r_reject <= q_valid && rej_c;
    end
  end

`ifdef FORMAL
  // Soundness against a shadow pixel: (f_px, f_py) is an arbitrary pixel.  The
  // shadow holds its last depth written since the last bump (the ROP's depth
  // buffer content for that pixel, under the family's write rule) and whether
  // it was written.  A reject for its tile must be correct for that pixel.
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  (* anyconst *) logic [CW-1:0] f_px, f_py;
  logic          f_w;                              // written since the last bump
  logic [DW-1:0] f_z;                              // its current depth
  logic          f_ptile;
  assign f_ptile = (f_px[CW-1:TS] == q_tx) && (f_py[CW-1:TS] == q_ty);
  always_ff @(posedge clk) begin
    if (!rst_n || bump || scrub) f_w <= 1'b0;
    else if (u_valid && u_x == f_px && u_y == f_py) begin f_w <= 1'b1; f_z <= u_z; end
  end
  always @(posedge clk) if (f_vld && rst_n && $past(rst_n) && f_vld) begin
    // checked one cycle later against the shadow as it stood at the query
    if (r_reject && $past(f_ptile) && $past(q_valid)) begin
      assert ($past(f_w));
      if ($past(fam_q)) assert ($past(q_zmax) < $past(f_z));
      else              assert ($past(q_zmin) > $past(f_z));
    end
  end
  always @(*) if (f_vld && rst_n) assert (cur_gen != '0);
`endif
endmodule
