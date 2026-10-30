// ============================================================================
// ad_rx_scan -- quad traversal and coverage.
//
// Per set-up triangle: ad_rx_coarse walks the bbox in screen-aligned 8x8
// tiles (empty tiles skipped in one cycle); each surviving tile may be
// rejected by the Hi-Z (ad_rx_hiz, one query per tile); the tile's 16 quads
// are then evaluated one per cycle:
//   lane (dx, dy) of quad (qx, qy):  E = Et + (2qx + dx) A8 + (2qy + dy) B8
//   centre covered  <=> E_e >= 0 for e = 0..2 (top-left bias already in E)
//   sample s (4x)   <=> E_e + delta_{s,e} >= 0 (ad_rx_cov), 48 adders in parallel
// Lanes outside the bbox (scissor, RT, viewport rectangle) are masked; the
// sample mask (SAMPLE_KILL) is applied.  A quad with no sample goes nowhere.
//   warp path (HAS_SU, not raw): covered quads on fq_*, then the end marker;
//   direct path (raw or no SU): one sequence number per non-empty triangle,
//     dx_* quads with z per lane, closed by a mask-0 quad with dx_last.
// After the triangle the PT entries flagged last-use are freed (warp path:
// once ad_rx_frag is no longer busy).
//
// Fixes vs atg_rx_scan: the Hi-Z child is real and its query is in the walk;
// MS_SMAX limited to 1 or 4 (atg listed 2 without sample locations); the
// direct path always closes with a mask-0 dx_last quad (atg said both "only
// FREE" and "one dummy quad" for an empty triangle); a trivial tile still
// applies the bbox and the sample mask; decoded state from ad_rx_state.
// ============================================================================
module ad_rx_scan #(
  parameter int HAS_SU  = ad_rx_pkg::HAS_SU_,
  parameter int ENMSAA  = ad_rx_pkg::EN_MSAA,
  parameter int ENEZHZ  = ad_rx_pkg::EN_EZHZ,
  // datapath widths default to the package; FPV runs the same RTL at reduced widths
  // (the fields keep their sp_tri positions; only their widths shrink)
  parameter int CW      = ad_rx_pkg::CRD_WID,
  parameter int AW      = ad_rx_pkg::EDG_COF,
  parameter int EW      = ad_rx_pkg::EDG_ACC,
  parameter int FR      = ad_rx_pkg::FIX_FRC
) (
  input  logic                               clk,
  input  logic                               rst_n,
  // decoded state
  input  logic [4:0]                         i_msctl,
  input  logic [3:0]                         i_skill,
  input  logic [3:0]                         i_dfunc,
  // from setup
  input  logic                               sp_valid,
  output logic                               sp_ready,
  input  logic [ad_rx_pkg::SPT_WID-1:0]      sp_tri,
  input  logic                               sp_last,
  // PT frees
  output logic                               pt_free,
  output logic [ad_rx_pkg::PT_IDXW-1:0]      pt_free_idx,
  // covered quads to frag
  output logic                               fq_valid,
  input  logic                               fq_ready,
  output logic [ad_rx_pkg::QXY_WID-1:0]      fq_xy,
  output logic [ad_rx_pkg::MS_COVW-1:0]      fq_scov,
  output logic [3:0]                         fq_ccov,
  output logic                               fq_end,
  input  logic                               f_busy,
  // direct quads to the ROP
  output logic                               dx_valid,
  input  logic                               dx_ready,
  output logic [ad_rx_pkg::SEQ_WID-1:0]      dx_seq,
  output logic [ad_rx_pkg::QXY_WID-1:0]      dx_xy,
  output logic [3:0]                         dx_mask,
  output logic [4*32-1:0]                    dx_depth,
  output logic                               dx_last,
  // sequence numbers
  output logic                               sq_req,
  input  logic [ad_rx_pkg::SEQ_WID-1:0]      sq_seq,
  // Hi-Z: clear and the ROP's depth writes
  input  logic                               hz_clear,
  input  logic                               hz_upd,
  input  logic [ad_rx_pkg::CRD_WID-1:0]      hz_ux,
  input  logic [ad_rx_pkg::CRD_WID-1:0]      hz_uy,
  input  logic [ad_rx_pkg::HZ_DEPW-1:0]      hz_uz,
  output logic                               busy
);
  localparam int PW = EW + 2*AW;
  localparam int XW = EW + 4;
  localparam int PI = ad_rx_pkg::PT_IDXW;

  typedef enum logic [3:0] {S_IDLE, S_SEQ, S_TILE, S_HZ, S_WALK, S_FQ, S_Z, S_DX, S_END, S_FREE} st_t;
  st_t st;

  // ---------------------------------------------------------------- triangle
  logic [ad_rx_pkg::SPT_WID-1:0] tg;
  logic          direct, ms4;
  logic [CW-1:0] bx0, by0, bx1, by1;
  assign bx0 = tg[ad_rx_pkg::SPT_BBX +: CW];
  assign by0 = tg[ad_rx_pkg::SPT_BBX + CW +: CW];
  assign bx1 = tg[ad_rx_pkg::SPT_BBX + 2*CW +: CW];
  assign by1 = tg[ad_rx_pkg::SPT_BBX + 3*CW +: CW];
  logic          tempty;
  assign tempty = (bx0 >= bx1) || (by0 >= by1);

  logic signed [XW-1:0] a8 [3], b8 [3];
  for (genvar e = 0; e < 3; e++) begin : g_ab
    assign a8[e] = XW'($signed(tg[PW*e +: AW])) <<< FR;
    assign b8[e] = XW'($signed(tg[PW*e + AW +: AW])) <<< FR;
  end

  // ---------------------------------------------------------------- children
  logic [3*2*AW-1:0] ab_in;
  for (genvar e = 0; e < 3; e++) begin : g_abi
    assign ab_in[2*AW*e +: 2*AW] = sp_tri[PW*e +: 2*AW];
  end
  logic [4*3*EW-1:0] dlt;
  logic [3*EW-1:0]   lowm;
  logic              tri_take;
  assign tri_take = sp_valid && sp_ready;
  ad_rx_cov #(.CW(AW), .EW(EW)) u_cov (.clk, .rst_n, .i_load(tri_take), .i_ab(ab_in), .o_dlt(dlt), .o_lowm(lowm));

  logic              c_valid, c_ready, t_valid, t_ready, t_triv, w_done, c_busy;
  logic [CW-1:0]     t_x, t_y;
  logic [3*EW-1:0]   t_e;
  ad_rx_coarse #(.CW(CW), .AW(AW), .EW(EW), .FR(FR)) u_coarse (.clk, .rst_n, .tri_valid(c_valid), .tri_ready(c_ready),
                         .bbox({by1, bx1, by0, bx0}), .edges(tg[0 +: 3*PW]),
                         .lowm(ms4 ? lowm : '0), .tile_valid(t_valid), .tile_ready(t_ready),
                         .tile_x(t_x), .tile_y(t_y), .tile_e(t_e), .tile_trivial(t_triv),
                         .walk_done(w_done), .busy(c_busy));

  // Hi-Z
  logic [ad_rx_pkg::HZ_DEPW-1:0] zlo, zhi;
  ad_rx_f2un #(.RUP(0)) u_zlo (.f(tg[ad_rx_pkg::SPT_ZMN +: 32]), .u(zlo));
  ad_rx_f2un #(.RUP(1)) u_zhi (.f(tg[ad_rx_pkg::SPT_ZMX +: 32]), .u(zhi));
  logic hz_rv, hz_rej, hz_busy, hz_q;
  generate
    if (ENEZHZ != 0) begin : g_hiz
      ad_rx_hiz u_hiz (.clk, .rst_n, .i_en(i_dfunc[3] && !direct), .i_func(i_dfunc[2:0]),
                       .i_clear(hz_clear), .q_valid(hz_q),
                       .q_tx(ad_rx_pkg::CRD_WID'(t_x >> ad_rx_pkg::TILE_SH)), .q_ty(ad_rx_pkg::CRD_WID'(t_y >> ad_rx_pkg::TILE_SH)),
                       .q_zmin(zlo), .q_zmax(zhi), .r_valid(hz_rv), .r_reject(hz_rej),
                       .u_valid(hz_upd), .u_x(hz_ux), .u_y(hz_uy), .u_z(hz_uz), .busy(hz_busy));
    end else begin : g_nohiz
      assign hz_rv = 1'b0; assign hz_rej = 1'b0; assign hz_busy = 1'b0;
    end
  endgenerate
  assign hz_q = (st == S_TILE) && t_valid;

  // ---------------------------------------------------------------- tile / quad walk
  logic [CW-1:0]        tx, ty;                   // the tile being walked
  logic                 ttriv;
  logic [1:0]           qx, qy;                   // quad within the tile
  logic signed [XW-1:0] eq [3];                   // E at lane 0 of the quad
  logic signed [XW-1:0] eqr [3];                  // E at lane 0 of the quad row

  // lane edges and coverage
  logic [3:0]  ccv;                               // centre coverage (bbox masked)
  logic [15:0] scv;                               // bit 4l + s
  logic [3:0]  lin;                               // lane inside the bbox
  logic [CW-1:0] lx [4], ly [4];
  for (genvar l = 0; l < 4; l++) begin : g_l
    assign lx[l] = tx + CW'(2 * qx) + CW'(l & 1);
    assign ly[l] = ty + CW'(2 * qy) + CW'(l >> 1);
    assign lin[l] = (lx[l] >= bx0) && (lx[l] < bx1) && (ly[l] >= by0) && (ly[l] < by1);
    logic signed [XW-1:0] le [3];
    logic [2:0] cin;
    for (genvar e = 0; e < 3; e++) begin : g_e
      assign le[e]  = eq[e] + (((l & 1) != 0) ? a8[e] : '0) + (((l >> 1) != 0) ? b8[e] : '0);
      assign cin[e] = !le[e][XW-1];
    end
    assign ccv[l] = lin[l] && (ttriv || (&cin));
    for (genvar s = 0; s < 4; s++) begin : g_s
      logic [2:0] sin;
      for (genvar e = 0; e < 3; e++) begin : g_se
        logic signed [XW-1:0] se;
        assign se = le[e] + XW'($signed(dlt[EW*(3*s + e) +: EW]));
        assign sin[e] = !se[XW-1];
      end
      assign scv[4*l + s] = lin[l] && !i_skill[s] &&
                            (ms4 ? (ttriv || (&sin)) : (s == 0) && ccv[l]);
    end
  end
  logic qcov;
  assign qcov = (scv != '0);

  // ---------------------------------------------------------------- direct path depth
  logic [31:0] fm_r, fa_r, zi_f, zj_f;
  logic [31:0] m_a, m_b, a_a, a_b, ztmp;
  logic [1:0]  zl;                                // lane
  logic [1:0]  zs;                                // step
  logic [3:0]  zm;
  logic [4*32-1:0] zq;
  logic signed [CW:0] zi, zj;
  assign zi = $signed({1'b0, lx[zl]}) - $signed({1'b0, bx0});
  assign zj = $signed({1'b0, ly[zl]}) - $signed({1'b0, by0});
  ad_rx_i2f #(.W(CW+1), .F(0)) u_zi (.v(zi), .f(zi_f));
  ad_rx_i2f #(.W(CW+1), .F(0)) u_zj (.v(zj), .f(zj_f));
  ad_rx_fmul u_fmul (.i_a(m_a), .i_b(m_b), .o_r(fm_r));
  ad_rx_fadd u_fadd (.i_a(a_a), .i_b(a_b), .i_sub(1'b0), .o_r(fa_r));
  // z = (Az i + Bz j) + Cz: step 0 Az i; step 1 + Bz j; step 2 + Cz
  always_comb begin
    m_a = (zs == 2'd0) ? tg[ad_rx_pkg::SPT_PLZ +: 32] : tg[ad_rx_pkg::SPT_PLZ + 32 +: 32];
    m_b = (zs == 2'd0) ? zi_f : zj_f;
    a_a = ztmp;
    a_b = (zs == 2'd1) ? fm_r : tg[ad_rx_pkg::SPT_PLZ + 64 +: 32];
  end

  // ---------------------------------------------------------------- control
  logic [2:0] fr;                                 // free index
  logic [2:0] lst;
  assign lst = tg[ad_rx_pkg::SPT_LST +: 3];

  assign sp_ready = (st == S_IDLE);
  assign t_ready  = (st == S_TILE);
  assign c_valid  = (st == S_SEQ);
  assign sq_req   = (st == S_SEQ) && direct && !tempty;
  assign busy     = (st != S_IDLE);

  assign fq_valid = (st == S_FQ) || (st == S_END && !direct);
  assign fq_end   = (st == S_END);
  assign fq_xy    = {ty + CW'(2 * qy), tx + CW'(2 * qx)};
  assign fq_scov  = (st == S_END) ? '0 : scv;
  assign fq_ccov  = (st == S_END) ? '0 : ccv;

  assign dx_valid = (st == S_DX) || (st == S_END && direct);
  assign dx_xy    = (st == S_END) ? '0 : {ty + CW'(2 * qy), tx + CW'(2 * qx)};
  assign dx_mask  = (st == S_END) ? 4'd0 : zm;
  assign dx_depth = zq;
  assign dx_last  = (st == S_END);

  assign pt_free     = (st == S_FREE) && lst[fr] && (direct || !f_busy);
  assign pt_free_idx = tg[ad_rx_pkg::SPT_PTE + PI*fr +: PI];

  logic wd_q;                                     // the coarse walk has ended (sticky)
  logic quad_last;                                // last quad of the tile
  assign quad_last = (qx == 2'd3) && (qy == 2'd3);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE; tg <= '0; direct <= 1'b0; wd_q <= 1'b0; ms4 <= 1'b0; tx <= '0; ty <= '0; ttriv <= 1'b0;
      qx <= '0; qy <= '0; fr <= '0; dx_seq <= '0; zl <= '0; zs <= '0; zm <= '0; zq <= '0; ztmp <= '0;
      for (int e = 0; e < 3; e++) begin eq[e] <= '0; eqr[e] <= '0; end
    end else begin
      if (w_done) wd_q <= 1'b1;
      case (st)
        S_IDLE: if (sp_valid) begin
          tg    <= sp_tri;
          direct <= sp_tri[ad_rx_pkg::SPT_RAW] || (HAS_SU == 0);
          ms4    <= (ENMSAA != 0) && (i_msctl[3:0] == 4'd2) && !sp_tri[ad_rx_pkg::SPT_RAW] && (HAS_SU != 0);
          fr <= '0; wd_q <= 1'b0;
          st <= S_SEQ;
        end
        S_SEQ: begin                               // coarse takes the triangle; direct: a number
          if (sq_req) dx_seq <= sq_seq;
          st <= tempty ? S_FREE : S_TILE;
        end
        S_TILE: begin
          if (t_valid) begin
            tx <= t_x; ty <= t_y; ttriv <= t_triv; qx <= '0; qy <= '0;
            for (int e = 0; e < 3; e++) begin
              eq[e]  <= XW'($signed(t_e[EW*e +: EW]));
              eqr[e] <= XW'($signed(t_e[EW*e +: EW]));
            end
            st <= S_HZ;
          end else if (w_done || wd_q)
            st <= S_END;
        end
        S_HZ: st <= (hz_rv && hz_rej) ? S_TILE : S_WALK;   // Hi-Z answer
        S_WALK: begin
          if (qcov) begin
            if (direct) begin zl <= '0; zs <= '0; zm <= ccv; st <= S_Z; end
            else st <= S_FQ;
          end else begin
            // next quad
            if (quad_last) st <= S_TILE;
            else if (qx == 2'd3) begin
              qx <= '0; qy <= qy + 1'b1;
              for (int e = 0; e < 3; e++) begin eqr[e] <= eqr[e] + (b8[e] <<< 1); eq[e] <= eqr[e] + (b8[e] <<< 1); end
            end else begin
              qx <= qx + 1'b1;
              for (int e = 0; e < 3; e++) eq[e] <= eq[e] + (a8[e] <<< 1);
            end
          end
        end
        S_FQ, S_DX: if ((st == S_FQ && fq_ready) || (st == S_DX && dx_ready)) begin
          if (quad_last) st <= S_TILE;
          else begin
            st <= S_WALK;
            if (qx == 2'd3) begin
              qx <= '0; qy <= qy + 1'b1;
              for (int e = 0; e < 3; e++) begin eqr[e] <= eqr[e] + (b8[e] <<< 1); eq[e] <= eqr[e] + (b8[e] <<< 1); end
            end else begin
              qx <= qx + 1'b1;
              for (int e = 0; e < 3; e++) eq[e] <= eq[e] + (a8[e] <<< 1);
            end
          end
        end
        S_Z: begin                                 // per lane: Az i; + Bz j; + Cz
          case (zs)
            2'd0: begin ztmp <= fm_r; zs <= 2'd1; end
            2'd1: begin ztmp <= fa_r; zs <= 2'd2; end
            default: begin
              zq[32*zl +: 32] <= fa_r;
              zs <= 2'd0;
              if (zl == 2'd3) st <= S_DX;
              zl <= zl + 1'b1;
            end
          endcase
        end
        S_END: if ((direct && dx_ready) || (!direct && fq_ready)) st <= S_FREE;
        S_FREE: begin
          if (direct || !f_busy) begin
            if (fr == 3'd2) st <= S_IDLE;
            fr <= fr + 1'b1;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  always @(posedge clk) if (f_vld && rst_n) begin
    // a quad leaves only with a sample, never outside the bbox
    if (fq_valid && !fq_end) begin
      assert (fq_scov != 0);
      for (int l = 0; l < 4; l++) if (!lin[l]) assert (fq_scov[4*l +: 4] == 0 && fq_ccov[l] == 0);
      for (int s = 0; s < 4; s++) if (i_skill[s]) assert (fq_scov[4*0+s] == 0 && fq_scov[4*1+s] == 0 && fq_scov[4*2+s] == 0 && fq_scov[4*3+s] == 0);
    end
    if (fq_valid) assert (!direct);
    if (dx_valid) assert (direct);
    if (pt_free) assert (st == S_FREE && (direct || !f_busy));
    if (sq_req) assert (direct);
    if (!ms4 && fq_valid) for (int l = 0; l < 4; l++) assert (fq_scov[4*l+1 +: 3] == 0);
  end
  always @(posedge clk) if (f_vld && rst_n && $past(rst_n) && $past(fq_valid && !fq_ready))
    assert (fq_valid && fq_xy == $past(fq_xy) && fq_scov == $past(fq_scov) && fq_end == $past(fq_end));
  always @(posedge clk) if (f_vld && rst_n && $past(rst_n) && $past(dx_valid && !dx_ready))
    assert (dx_valid && dx_xy == $past(dx_xy) && dx_mask == $past(dx_mask) && dx_last == $past(dx_last));
`endif
endmodule
