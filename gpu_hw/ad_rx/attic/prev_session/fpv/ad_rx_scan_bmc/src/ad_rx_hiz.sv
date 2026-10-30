// ============================================================================
// ad_rx_hiz -- hierarchical early-Z: one conservative depth bound per
// 8 x 8 tile, generation-tagged so a clear costs one cycle.
//
// Folded in from early_z_unit's HiZ buffer, with three fixes:
//  1. Conservative update.  early_z_unit seeded a stale tile with the depth
//     of the first fragment written and then kept the max of written
//     fragments -- but pixels of the tile never written still hold the
//     clear depth, so a later primitive could be rejected over empty
//     pixels.  Here a stale tile reads as the clear depth, and an update is
//     only allowed for a tile whose 64 pixels were all written by the same
//     primitive (u_we from a fully covered, fully passing tile); the bound
//     then tightens monotonically: LESS family min(old, zfar), GREATER
//     family max(old, zfar).
//  2. Depth-function family is latched at clear.  A draw whose function is
//     of the other family (or EQUAL/NOTEQUAL/ALWAYS/NEVER) neither rejects
//     nor updates; switching family without a clear turns Hi-Z off until
//     the next clear (early_z_unit left this as a driver contract).
//  3. Generation wrap.  An HZ_GW-bit tag aliases after 2^GW clears.  A
//     background scrubber rewrites stale entries as {gen, clear depth}
//     (value-preserving) whenever the write port is free -- and every entry
//     while Hi-Z is off, which also wipes the unknown RAM after reset; if more than
//     2^GW - 1 clears land within two scrub passes Hi-Z turns itself off
//     until two clean passes complete.
//
// Query (combinational): q_rej = 1 only if every sample in [q_zlo, q_zhi]
// fails the depth test against every pixel of the tile.
// ============================================================================
module ad_rx_hiz #(
  parameter int AW = ad_rx_pkg::HZ_AW,      // tile address width
  parameter int ZW = ad_rx_pkg::HZ_ZW,      // stored depth (unorm)
  parameter int GW = ad_rx_pkg::HZ_GW       // generation tag width
) (
  input  logic          clk,
  input  logic          rst_n,
  // clear: new frame / depth clear
  input  logic          clr,
  input  logic [ZW-1:0] clr_z,              // the clear depth
  input  logic [2:0]    clr_fn,             // depth function for this frame
  // query from the coarse walker
  input  logic [AW-1:0] q_addr,
  input  logic [ZW-1:0] q_zlo,              // primitive depth range in the tile
  input  logic [ZW-1:0] q_zhi,
  input  logic [2:0]    q_fn,               // current depth function
  output logic          q_rej,
  // update from the ROP (fully covered, fully passing, depth-writing tile)
  input  logic          u_we,
  input  logic [AW-1:0] u_addr,
  input  logic [ZW-1:0] u_zfar,             // far bound of the depths written
  output logic          hz_on               // Hi-Z active (status)
);
  localparam int NT = 1 << AW;

  // tile RAM: {gen, z}
  logic [GW-1:0] ram_g [NT];
  logic [ZW-1:0] ram_z [NT];

  logic [GW-1:0] gen;
  logic [ZW-1:0] cz;
  logic          fam_lt, fam_gt;     // latched family: LESS/LEQ or GREATER/GEQ
  logic          off;                // Hi-Z disabled

  function automatic logic is_lt(input logic [2:0] f);
    is_lt = (f == ad_rx_pkg::DF_LESS) || (f == ad_rx_pkg::DF_LEQ);
  endfunction
  function automatic logic is_gt(input logic [2:0] f);
    is_gt = (f == ad_rx_pkg::DF_GRTR) || (f == ad_rx_pkg::DF_GEQ);
  endfunction

  // ---- effective tile value (stale -> clear depth) -------------------------
  logic [ZW-1:0] qz, uz;
  logic          fam_ok;
  assign qz     = (ram_g[q_addr] == gen) ? ram_z[q_addr] : cz;
  assign uz     = (ram_g[u_addr] == gen) ? ram_z[u_addr] : cz;
  assign fam_ok = !off && ((fam_lt && is_lt(q_fn)) || (fam_gt && is_gt(q_fn)));
  assign hz_on  = !off;

  always_comb begin
    q_rej = 1'b0;
    if (fam_ok) begin
      case (q_fn)
        ad_rx_pkg::DF_LESS: q_rej = q_zlo >= qz;
        ad_rx_pkg::DF_LEQ:  q_rej = q_zlo >  qz;
        ad_rx_pkg::DF_GRTR: q_rej = q_zhi <= qz;
        ad_rx_pkg::DF_GEQ:  q_rej = q_zhi <  qz;
        default:            q_rej = 1'b0;
      endcase
    end
  end

  // ---- update value ---------------------------------------------------------
  logic          upd;
  logic [ZW-1:0] unew;
  assign upd  = u_we && fam_ok;
  assign unew = fam_lt ? ((u_zfar < uz) ? u_zfar : uz)
                       : ((u_zfar > uz) ? u_zfar : uz);

  // ---- scrubber and wrap guard ----------------------------------------------
  // The pointer advances past an entry only once it is current (or was just
  // rewritten), so a pass really refreshes every entry.  c_cur / c_prv count
  // clears in this / the previous pass (saturating); an entry is never more
  // than c_cur + c_prv clears old, so the tag cannot alias while
  // c_cur + c_prv <= 2^GW - 2.
  localparam int CM = (1 << (GW + 1)) - 1;
  logic [AW-1:0] sp;                 // scrub pointer
  logic [GW:0]   c_cur, c_prv;       // clears in this / the previous pass
  logic [1:0]    clean;              // completed passes since turning off
  logic          stale_sp, scrub_we, sp_adv, wrap_ovf;
  assign stale_sp = (ram_g[sp] != gen);
  assign scrub_we = (stale_sp || off) && !upd && !clr;   // while off: rewrite all
  assign sp_adv   = !clr && ((!stale_sp && !off) || scrub_we);
  assign wrap_ovf = (GW+2)'(c_cur) + (GW+2)'(c_prv) + (GW+2)'(1) > (GW+2)'((1 << GW) - 2);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gen    <= '0;
      cz     <= '1;
      fam_lt <= 1'b0;
      fam_gt <= 1'b0;
      off    <= 1'b1;                // RAM content unknown until two passes
      sp     <= '0;
      c_cur  <= '0;
      c_prv  <= '0;
      clean  <= '0;
    end else begin
      if (sp_adv) sp <= sp + AW'(1);
      if (sp_adv && sp == '1) begin                 // a pass ends
        c_prv <= c_cur;
        c_cur <= '0;
        if (clean != 2'd2) clean <= clean + 2'd1;
      end else if (clr && c_cur != (GW+1)'(CM)) begin
        c_cur <= c_cur + (GW+1)'(1);
      end

      if (clr) begin
        gen    <= gen + GW'(1);
        cz     <= clr_z;
        fam_lt <= is_lt(clr_fn);
        fam_gt <= is_gt(clr_fn);
        if (wrap_ovf) begin
          off   <= 1'b1;
          clean <= '0;
        end else if (clean == 2'd2 || !off) begin
          off   <= 1'b0;
        end
      end else if ((fam_lt || fam_gt) && (is_lt(q_fn) || is_gt(q_fn)) &&
                   (fam_lt != is_lt(q_fn))) begin
        off   <= 1'b1;               // family switched without a clear
        clean <= '0;
      end
    end
  end

  // single write port: update has priority over the scrubber
  always_ff @(posedge clk) begin
    if (upd) begin
      ram_g[u_addr] <= gen;
      ram_z[u_addr] <= unew;
    end else if (scrub_we) begin
      ram_g[sp] <= gen;
      ram_z[sp] <= cz;
    end
  end

`ifdef FORMAL
  // ---------------------------------------------------------------- FPV ----
  // Shadow model of what each tile truly holds this frame (f_val, f_z,
  // f_cz) and ghost ages (f_cnt: clears since the entry was last written,
  // saturating; CM = unknown, e.g. after reset).
  logic f_past = 1'b0;
  always_ff @(posedge clk) f_past <= 1'b1;
  initial assume (!rst_n);

  // the ROP drains before a clear: no update in the clear's cycle
  always_comb assume (!(clr && u_we));

  logic          f_val [NT];
  logic [ZW-1:0] f_z   [NT];
  logic [GW:0]   f_cnt [NT];
  logic [ZW-1:0] f_cz;
  logic          f_pass;             // a full pass completed since reset

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < NT; i++) begin f_val[i] <= 1'b0; f_cnt[i] <= (GW+1)'(CM); end
      f_cz   <= '1;
      f_pass <= 1'b0;
    end else begin
      if (sp_adv && sp == '1) f_pass <= 1'b1;
      for (int i = 0; i < NT; i++) begin
        if (clr) begin
          f_val[i] <= 1'b0;
          if (f_cnt[i] != (GW+1)'(CM)) f_cnt[i] <= f_cnt[i] + (GW+1)'(1);
        end else if (upd && u_addr == AW'(i)) begin
          f_val[i] <= 1'b1;  f_z[i] <= unew;  f_cnt[i] <= '0;
        end else if (scrub_we && sp == AW'(i)) begin
          f_cnt[i] <= '0;
        end
      end
      if (clr) f_cz <= clr_z;
    end
  end

  logic [ZW-1:0] f_true;
  assign f_true = f_val[q_addr] ? f_z[q_addr] : f_cz;

  always_comb if (f_past && rst_n) begin
    assert (cz == f_cz);
    // wrap guard: while on, no entry can be 2^GW clears old
    if (!off) assert ((GW+2)'(c_cur) + (GW+2)'(c_prv) <= (GW+2)'((1 << GW) - 2));
    if (!off) assert (f_pass);
    if (clean != 2'd0) assert (f_pass);
    for (int i = 0; i < NT; i++) begin
      // positional age bound left by the scrubber
      if (AW'(i) < sp)            assert ((GW+2)'(f_cnt[i]) <= (GW+2)'(c_cur));
      if (f_pass && AW'(i) >= sp) assert ((GW+2)'(f_cnt[i]) <= (GW+2)'(c_cur) + (GW+2)'(c_prv));
      // the tag tracks the age modulo 2^GW
      if (f_cnt[i] != (GW+1)'(CM)) assert (GW'(gen - ram_g[i]) == GW'(f_cnt[i]));
      // an entry is written this frame iff its age is 0
      if (f_val[i]) assert (f_cnt[i] == '0 && ram_z[i] == f_z[i]);
      if (f_cnt[i] == '0 && !f_val[i]) assert (ram_z[i] == f_cz);
    end
    // SOUNDNESS: while on, the effective value is the true bound
    if (!off) assert (qz == f_true);
    if (q_rej && q_fn == ad_rx_pkg::DF_LESS) assert (q_zlo >= f_true);
    if (q_rej && q_fn == ad_rx_pkg::DF_LEQ)  assert (q_zlo >  f_true);
    if (q_rej && q_fn == ad_rx_pkg::DF_GRTR) assert (q_zhi <= f_true);
    if (q_rej && q_fn == ad_rx_pkg::DF_GEQ)  assert (q_zhi <  f_true);
    if (off || !(is_lt(q_fn) || is_gt(q_fn))) assert (!q_rej);
  end

  always_ff @(posedge clk) if (rst_n) begin
    cover (q_rej && ram_g[q_addr] == gen && f_val[q_addr]);
    cover (q_rej && !f_val[q_addr]);
    cover (f_past && $past(off) && !off && f_pass);
  end
`endif
endmodule
