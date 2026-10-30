// ============================================================================
// ad_rx_scan -- quad traversal.
//
// Takes a set-up triangle (sp_tri), walks its bbox through ad_rx_coarse in
// 8 x 8 tiles (empty tiles skipped in one cycle, Hi-Z rejected tiles too),
// and walks each tile's 16 quads, one quad per cycle.  Per quad the 4 lanes
// x 4 samples x 3 edges are evaluated in parallel (48 adders): 16-bit sample
// coverage fq_scov and 4-bit centre coverage fq_ccov in one cycle.
//
//  * warp path (HAS_SU, not raw): covered quads on fq_*, then one end
//    marker; ad_rx_frag builds the warps and takes the sequence numbers
//  * direct path (raw, or HAS_SU = 0): one sequence number per triangle,
//    each covered quad on dx_* with z = (Az i + Bz j) + Cz per lane
//    (fp32, clamped to [0, 1]); the last quad carries dx_last.  A triangle
//    without coverage sends one quad with mask 0 to retire its number.
//  * afterwards pt_free for each flagged vertex; on the warp path only once
//    f_busy is low.
//
// Folded in from rasterizer_core: the explicit seed step (no data value is
// used as a "first pixel" sentinel -- the coarse walker's INIT state plays
// SEED's role), incremental edge stepping, and its safety properties
// (busy == !idle, one-cycle pulses, nothing emitted outside the bbox).
// Fixed relative to rasterizer_core: pixel centres instead of corners,
// the top-left rule (no double coverage on shared edges), either winding,
// 48-bit edges instead of 16 x 16 products in 32 bits, no multiplier per
// row restart.
// ============================================================================
module ad_rx_scan #(
  parameter bit HAS_SU = 1'b1,
  parameter bit MS_EN  = 1'b1,     // multisampling coverage
  parameter bit HZ_EN  = 1'b1,     // Hi-Z tile rejection
  parameter bit COARSE = 1'b1,     // skip empty tiles / trivial accept
  parameter int HZ_AW  = ad_rx_pkg::HZ_AW
) (
  input  logic                         clk,
  input  logic                         rst_n,
  // STATE broadcast
  input  logic                         st_we,
  input  logic [ad_rx_pkg::ST_IW-1:0]  st_idx,
  input  logic [ad_rx_pkg::ST_DW-1:0]  st_wdata,
  // from ad_rx_setup
  input  logic                         sp_valid,
  output logic                         sp_ready,
  input  logic [ad_rx_pkg::SP_W-1:0]   sp_tri,
  input  logic [31:0]                  sp_zr,     // {zhi, zlo} unorm16 (Hi-Z)
  input  logic                         sp_last,
  // PT frees
  output logic                         pt_free,
  output logic [ad_rx_pkg::PT_IW-1:0]  pt_free_idx,
  // covered quads to ad_rx_frag
  output logic                         fq_valid,
  input  logic                         fq_ready,
  output logic [31:0]                  fq_xy,
  output logic [15:0]                  fq_scov,
  output logic [3:0]                   fq_ccov,
  output logic                         fq_end,
  input  logic                         f_busy,
  // direct quads to the ROP
  output logic                         dx_valid,
  input  logic                         dx_ready,
  output logic [ad_rx_pkg::SEQ_W-1:0]  dx_seq,
  output logic [31:0]                  dx_xy,
  output logic [3:0]                   dx_mask,
  output logic [127:0]                 dx_depth,
  output logic                         dx_last,
  // sequence numbers
  output logic                         sq_req,
  input  logic [ad_rx_pkg::SEQ_W-1:0]  sq_seq,
  // Hi-Z maintenance (ROP side)
  input  logic                         hz_clr,
  input  logic [15:0]                  hz_clrz,
  input  logic                         hz_uwe,
  input  logic [HZ_AW-1:0]             hz_uaddr,
  input  logic [15:0]                  hz_uz,
  output logic                         busy
);
  localparam int EW = ad_rx_pkg::EDGE_W;
  localparam int AW = ad_rx_pkg::FIX_W;
  localparam int CW = ad_rx_pkg::CRD_W;
  localparam int NE = ad_rx_pkg::NEDGE;
  localparam int ERW = ad_rx_pkg::ER_W;

  // ---- STATE ------------------------------------------------------------
  logic       ms4;
  logic [3:0] skill;
  logic [2:0] zfn;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ms4 <= 1'b0; skill <= '0; zfn <= ad_rx_pkg::DF_ALWS;
    end else if (st_we) begin
      if (st_idx == ad_rx_pkg::SA_MSCT) ms4   <= MS_EN && (st_wdata[3:0] == 4'd2);
      if (st_idx == ad_rx_pkg::SA_SKIL) skill <= st_wdata[3:0];
      if (st_idx == ad_rx_pkg::SA_ZFN)  zfn   <= st_wdata[2:0];
    end
  end

  // ---- triangle registers --------------------------------------------------
  typedef enum logic [3:0] {S_IDLE, S_LOAD, S_SEQ, S_TILE, S_WALK, S_FQ, S_Z,
                            S_EMIT, S_LAST, S_END, S_FREE} sst_e;
  sst_e st;

  logic [ad_rx_pkg::SP_W-1:0] ptri;
  logic          raw, direct;
  logic [CW-1:0] bx0, by0, bx1, by1;
  logic [2:0]    lu;
  logic [1:0]    fi;            // free index

  always_comb begin
    raw    = ptri[ad_rx_pkg::SP_RAW];
    direct = raw || !HAS_SU;
    bx0 = ptri[ad_rx_pkg::SP_BBX + 0*CW +: CW];
    by0 = ptri[ad_rx_pkg::SP_BBX + 1*CW +: CW];
    bx1 = ptri[ad_rx_pkg::SP_BBX + 2*CW +: CW];
    by1 = ptri[ad_rx_pkg::SP_BBX + 3*CW +: CW];
    lu  = ptri[ad_rx_pkg::SP_LU +: 3];
  end

  // edges, A and B sign-extended and scaled to one-pixel steps
  logic [3*EW-1:0] a8, b8, er;
  logic [3*2*AW-1:0] abv;
  always_comb begin
    for (int e = 0; e < NE; e++) begin
      a8[EW*e +: EW] = EW'($signed(ptri[ERW*e +: AW])) <<< 8;
      b8[EW*e +: EW] = EW'($signed(ptri[ERW*e + AW +: AW])) <<< 8;
      er[EW*e +: EW] = ptri[ERW*e + 2*AW +: EW];
      abv[2*AW*e +: 2*AW] = {ptri[ERW*e + AW +: AW], ptri[ERW*e +: AW]};
    end
  end

  // ---- MSAA offsets ---------------------------------------------------------
  // cov loads from the incoming sp_tri (same cycle as the triangle is taken)
  logic raw_in;
  logic [3*2*AW-1:0] abv_in;
  always_comb begin
    raw_in = sp_tri[ad_rx_pkg::SP_RAW];
    for (int e = 0; e < NE; e++)
      abv_in[2*AW*e +: 2*AW] = {sp_tri[ERW*e + AW +: AW], sp_tri[ERW*e +: AW]};
  end
  logic [3*4*EW-1:0] off;
  logic [3*EW-1:0]   lowm;
  ad_rx_cov u_cov (
    .clk(clk), .rst_n(rst_n), .i_load(st == S_IDLE && sp_valid),
    .i_ms(MS_EN && ms4 && !(raw_in)), .i_ab(abv_in), .o_off(off), .o_lowm(lowm));


  // ---- Hi-Z -----------------------------------------------------------------
  logic [CW-1:0] hz_tx, hz_ty;
  logic          hz_rej;
  logic [31:0]   zr;
  generate if (HZ_EN) begin : g_hz
    localparam int HW = HZ_AW / 2;
    logic q_rej;
    ad_rx_hiz #(.AW(HZ_AW)) u_hiz (
      .clk(clk), .rst_n(rst_n),
      .clr(hz_clr), .clr_z(hz_clrz), .clr_fn(zfn),
      .q_addr({hz_ty[HZ_AW-HW-1:0], hz_tx[HW-1:0]}),
      .q_zlo(zr[15:0]), .q_zhi(zr[31:16]), .q_fn(zfn), .q_rej(q_rej),
      .u_we(hz_uwe), .u_addr(hz_uaddr), .u_zfar(hz_uz), .hz_on());
    assign hz_rej = q_rej && !raw;
  end else begin : g_nohz
    assign hz_rej = 1'b0;
  end endgenerate

  // ---- coarse walker --------------------------------------------------------
  logic            c_tri_valid, c_tri_ready;
  logic            t_valid, t_ready, t_triv, t_last, t_none, c_busy;
  logic [CW-1:0]   t_x, t_y;
  logic [3*EW-1:0] t_e;
  ad_rx_coarse #(.SKIP(COARSE)) u_coarse (
    .clk(clk), .rst_n(rst_n),
    .tri_valid(c_tri_valid), .tri_ready(c_tri_ready),
    .bbox(ptri[ad_rx_pkg::SP_BBX +: ad_rx_pkg::BBOX_W]),
    .e_a8(a8), .e_b8(b8), .e_er(er), .lowm(lowm),
    .hz_tx(hz_tx), .hz_ty(hz_ty), .hz_rej(hz_rej),
    .tile_valid(t_valid), .tile_ready(t_ready), .tile_x(t_x), .tile_y(t_y),
    .tile_e(t_e), .tile_trivial(t_triv), .tile_last(t_last), .tile_none(t_none),
    .busy(c_busy));
  assign c_tri_valid = (st == S_SEQ) || (st == S_LOAD && !direct);

  // ---- fine walk: one quad of the held tile per cycle ----------------------
  logic [CW-1:0]   tx, ty;
  logic [3*EW-1:0] te;
  logic            triv, tlast;
  logic [3:0]      qi;                // quad index in the tile: {qy, qx}
  logic [CW-1:0]   qx, qy;            // quad pixel origin
  assign qx = tx + {13'd0, qi[1:0], 1'b0};
  assign qy = ty + {13'd0, qi[3:2], 1'b0};

  logic signed [EW-1:0] el [4][NE];   // lane centre edge values
  logic signed [EW-1:0] eqv [NE];
  logic signed [EW-1:0] eav [NE];
  logic signed [EW-1:0] ebv [NE];
  logic [CW:0] pxv [4];
  logic [CW:0] pyv [4];
  logic [15:0] hit;
  logic [3:0]  ccov, inbb;
  logic [15:0] scov;
  always_comb begin
    for (int e = 0; e < NE; e++) begin
      eav[e] = $signed(a8[EW*e +: EW]);
      ebv[e] = $signed(b8[EW*e +: EW]);
      eqv[e] = $signed(te[EW*e +: EW])
             + (qi[0] ? (eav[e] <<< 1) : EW'(0)) + (qi[1] ? (eav[e] <<< 2) : EW'(0))
             + (qi[2] ? (ebv[e] <<< 1) : EW'(0)) + (qi[3] ? (ebv[e] <<< 2) : EW'(0));
      el[0][e] = eqv[e];
      el[1][e] = eqv[e] + eav[e];
      el[2][e] = eqv[e] + ebv[e];
      el[3][e] = eqv[e] + eav[e] + ebv[e];
    end
    for (int l = 0; l < 4; l++) begin
      pxv[l] = {1'b0, qx} + (CW+1)'(l & 1);
      pyv[l] = {1'b0, qy} + (CW+1)'(l >> 1);
      inbb[l] = (pxv[l] >= {1'b0, bx0}) && (pxv[l] < {1'b0, bx1}) &&
                (pyv[l] >= {1'b0, by0}) && (pyv[l] < {1'b0, by1});
      ccov[l] = inbb[l] && (triv || ((el[l][0] >= 0) && (el[l][1] >= 0) && (el[l][2] >= 0)));
      for (int s = 0; s < 4; s++) begin
        hit[4*l+s] = triv ||
          (((el[l][0] + $signed(off[EW*(4*0+s) +: EW])) >= 0) &&
           ((el[l][1] + $signed(off[EW*(4*1+s) +: EW])) >= 0) &&
           ((el[l][2] + $signed(off[EW*(4*2+s) +: EW])) >= 0));
        if (ms4 && !direct)
          scov[4*l+s] = inbb[l] && hit[4*l+s] && !skill[s];
        else
          scov[4*l+s] = (s == 0) && ccov[l] && !skill[0];
      end
    end
  end

  logic quad_any;
  assign quad_any = direct ? (|ccov) : (|scov);
  assign t_ready  = (st == S_TILE);

  // ---- direct-path depth: z = (Az i + Bz j) + Cz, one lane op per cycle ----
  logic [1:0]  zl;               // lane
  logic [1:0]  zp;               // phase: 0 Az*i, 1 Bz*j, 2 sum, 3 + Cz
  logic [31:0] fa, fb, fm, fs, t1, t2;
  logic [16:0] iv;
  logic [31:0] ivf;
  ad_rx_fmul u_fmul (.a(fa), .b(fb), .r(fm));
  ad_rx_fadd u_fadd (.a(fa), .b(fb), .sub(1'b0), .r(fs));
  ad_rx_i2f #(.W(17), .F(0)) u_i2f (.v(iv), .f(ivf));
  always_comb begin
    iv = (zp == 2'd0) ? 17'({1'b0, qx} + 17'(zl & 1) - {1'b0, bx0})
                      : 17'({1'b0, qy} + 17'(zl >> 1) - {1'b0, by0});
    fa = '0; fb = '0;
    case (zp)
      2'd0: begin fa = ptri[ad_rx_pkg::SP_PZ +: 32];      fb = ivf; end
      2'd1: begin fa = ptri[ad_rx_pkg::SP_PZ + 32 +: 32]; fb = ivf; end
      2'd2: begin fa = t1;                               fb = t2;  end
      default: begin fa = t2; fb = ptri[ad_rx_pkg::SP_PZ + 64 +: 32]; end
    endcase
  end
  // clamp to [0, 1]: NaN and negatives 0
  logic [31:0] zc;
  always_comb begin
    if (ad_rx_pkg::fp_nan(fs) || fs[31]) zc = 32'd0;
    else if (fs > ad_rx_pkg::FP_ONE)      zc = ad_rx_pkg::FP_ONE;
    else                                  zc = fs;
  end

  // pending direct quad (one quad of look-ahead so the last carries dx_last)
  logic          pend;
  logic [31:0]   p_xy;
  logic [3:0]    p_mask;
  logic [127:0]  p_z, z_acc;
  logic [ad_rx_pkg::SEQ_W-1:0] seq;

  // ---- control ----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE; ptri <= '0; zr <= '0;
      tx <= '0; ty <= '0; te <= '0; triv <= 1'b0; tlast <= 1'b0; qi <= '0;
      fq_valid <= 1'b0; fq_xy <= '0; fq_scov <= '0; fq_ccov <= '0; fq_end <= 1'b0;
      dx_valid <= 1'b0; dx_seq <= '0; dx_xy <= '0; dx_mask <= '0; dx_depth <= '0; dx_last <= 1'b0;
      pend <= 1'b0; p_xy <= '0; p_mask <= '0; p_z <= '0; z_acc <= '0; seq <= '0;
      zl <= '0; zp <= '0; t1 <= '0; t2 <= '0;
      pt_free <= 1'b0; pt_free_idx <= '0; fi <= '0;
    end else begin
      pt_free <= 1'b0;
      case (st)
        S_IDLE: if (sp_valid) begin
          ptri  <= sp_tri;
          zr   <= sp_zr;
          pend <= 1'b0;
          st   <= S_LOAD;                 // cov offsets valid next cycle
        end

        S_LOAD: st <= direct ? S_SEQ : (c_tri_ready ? S_TILE : S_LOAD);

        S_SEQ: begin                      // direct: one number per triangle
          seq <= sq_seq;
          st  <= S_TILE;
        end

        S_TILE: if (t_valid) begin
          tx <= t_x; ty <= t_y; te <= t_e;
          triv <= t_triv; tlast <= t_last;
          qi <= '0;
          st <= t_none ? S_LAST : S_WALK;
        end

        S_WALK: begin
          if (quad_any) begin
            if (direct) begin
              if (pend) begin            // send the previous quad first
                dx_valid <= 1'b1; dx_seq <= seq; dx_xy <= p_xy;
                dx_mask <= p_mask; dx_depth <= p_z; dx_last <= 1'b0;
                st <= S_EMIT;
              end else begin
                zl <= '0; zp <= '0; st <= S_Z;
              end
            end else begin
              fq_valid <= 1'b1; fq_xy <= {qy, qx}; fq_scov <= scov;
              fq_ccov <= ccov; fq_end <= 1'b0;
              st <= S_FQ;
            end
          end else if (qi == 4'hF) begin
            st <= tlast ? S_LAST : S_TILE;
          end else begin
            qi <= qi + 4'd1;
          end
        end

        S_FQ: if (fq_ready) begin
          fq_valid <= 1'b0;
          if (fq_end) begin
            st <= S_FREE; fi <= '0;
          end else if (qi == 4'hF) begin
            st <= tlast ? S_LAST : S_TILE;
          end else begin
            qi <= qi + 4'd1; st <= S_WALK;
          end
        end

        S_EMIT: if (dx_ready) begin
          dx_valid <= 1'b0;
          if (dx_last) begin
            pend <= 1'b0; st <= S_FREE; fi <= '0;
          end else begin
            pend <= 1'b0; zl <= '0; zp <= '0; st <= S_Z;   // now the current quad
          end
        end

        S_Z: begin
          case (zp)
            2'd0: t1 <= fm;
            2'd1: t2 <= fm;
            2'd2: t2 <= fs;
            default: z_acc[32*zl +: 32] <= zc;
          endcase
          zp <= zp + 2'd1;
          if (zp == 2'd3) begin
            zl <= zl + 2'd1;
            if (zl == 2'd3) begin
              pend <= 1'b1; p_xy <= {qy, qx}; p_mask <= ccov;
              p_z <= {zc, z_acc[95:0]};
              if (qi == 4'hF) st <= tlast ? S_LAST : S_TILE;
              else begin qi <= qi + 4'd1; st <= S_WALK; end
            end
          end
        end

        S_LAST: begin                     // the triangle's end
          if (direct) begin
            dx_valid <= 1'b1; dx_seq <= seq; dx_last <= 1'b1;
            dx_xy    <= pend ? p_xy : {by0, bx0};
            dx_mask  <= pend ? p_mask : 4'd0;
            dx_depth <= pend ? p_z : '0;
            st <= S_EMIT;
          end else begin
            fq_valid <= 1'b1; fq_end <= 1'b1; fq_scov <= '0; fq_ccov <= '0;
            fq_xy <= {by0, bx0};
            st <= S_FQ;
          end
        end

        S_FREE: begin
          if (direct || !f_busy) begin
            if (lu[fi]) begin
              pt_free     <= 1'b1;
              pt_free_idx <= ptri[ad_rx_pkg::SP_PT + 8*fi +: 8];
            end
            if (fi == 2'd2) st <= S_IDLE;
            fi <= fi + 2'd1;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  assign sp_ready = (st == S_IDLE);
  assign sq_req   = (st == S_SEQ);
  assign busy     = (st != S_IDLE) || c_busy;

`ifdef FORMAL
  // ---------------------------------------------------------------- FPV ----
  logic f_past = 1'b0;
  always_ff @(posedge clk) f_past <= 1'b1;
  initial assume (!rst_n);
  // small, well-formed triangles from setup: bbox inside 24 x 24 pixels
  always_comb begin
    assume (sp_tri[ad_rx_pkg::SP_BBX + 2*CW +: CW] <= 16'd24);
    assume (sp_tri[ad_rx_pkg::SP_BBX + 3*CW +: CW] <= 16'd24);
    for (int e = 0; e < NE; e++) begin
      assume ($signed(sp_tri[ERW*e +: AW]) < (1 <<< 20) && $signed(sp_tri[ERW*e +: AW]) > -(1 <<< 20));
      assume ($signed(sp_tri[ERW*e + AW +: AW]) < (1 <<< 20) && $signed(sp_tri[ERW*e + AW +: AW]) > -(1 <<< 20));
      assume ($signed(sp_tri[ERW*e + 2*AW +: EW]) < (1 <<< 40) && $signed(sp_tri[ERW*e + 2*AW +: EW]) > -(1 <<< 40));
    end
  end

  // counters per triangle
  logic [1:0] f_ends, f_lasts;
  always_ff @(posedge clk)
    if (!rst_n || (st == S_IDLE && sp_valid)) begin f_ends <= '0; f_lasts <= '0; end
    else begin
      if (fq_valid && fq_ready && fq_end && f_ends != 2'd3) f_ends <= f_ends + 2'd1;
      if (dx_valid && dx_ready && dx_last && f_lasts != 2'd3) f_lasts <= f_lasts + 2'd1;
    end

  always_ff @(posedge clk) if (f_past && rst_n && $past(rst_n)) begin
    // busy is exactly "not idle" (rasterizer_core's p_busy_matches_state)
    if (st != S_IDLE) assert (busy);
    // valid/ready: held outputs stay unchanged until taken
    if ($past(fq_valid && !fq_ready)) assert (fq_valid && fq_xy == $past(fq_xy) &&
        fq_scov == $past(fq_scov) && fq_ccov == $past(fq_ccov) && fq_end == $past(fq_end));
    if ($past(dx_valid && !dx_ready)) assert (dx_valid && dx_xy == $past(dx_xy) &&
        dx_mask == $past(dx_mask) && dx_last == $past(dx_last) && dx_depth == $past(dx_depth));
    // one path per triangle
    assert (!(fq_valid && dx_valid));
    if (fq_valid) assert (!direct);
    if (dx_valid) assert (direct);
    // exactly one end marker / last quad per triangle, before the frees
    assert (f_ends <= 2'd1 && f_lasts <= 2'd1);
    if (st == S_FREE && !direct) assert (f_ends == 2'd1);
    if (st == S_FREE && direct)  assert (f_lasts == 2'd1);
    // no quad outside the bbox, coverage only inside it
    if (fq_valid && !fq_end) begin
      assert (fq_scov != '0);
      for (int l = 0; l < 4; l++) begin
        if (fq_ccov[l] || fq_scov[4*l +: 4] != '0) begin
          assert (fq_xy[15:0]  + 16'(l & 1)  >= bx0 && fq_xy[15:0]  + 16'(l & 1)  < bx1);
          assert (fq_xy[31:16] + 16'(l >> 1) >= by0 && fq_xy[31:16] + 16'(l >> 1) < by1);
        end
      end
    end
    if (fq_valid && fq_end) assert (fq_scov == '0 && fq_ccov == '0);
    // the lane edge values equal a direct evaluation from the bbox origin
    // (multiplier-heavy: bounded model checking, task bmc)
  `ifdef FPV_BMC
    if (st == S_WALK)
      for (int l = 0; l < 4; l++) for (int e = 0; e < NE; e++)
        assert (el[l][e] == $signed(er[EW*e +: EW])
                + $signed(8'(pxv[l] - {1'b0, bx0})) * $signed(a8[EW*e +: EW])
                + $signed(8'(pyv[l] - {1'b0, by0})) * $signed(b8[EW*e +: EW]));
  `endif
    // single-sample mode: only bit 0 of each lane
    if (fq_valid && !ms4) assert ((fq_scov & 16'hEEEE) == '0);
    // sample kill is honoured
    if (fq_valid) for (int s = 0; s < 4; s++) if (skill[s] && ms4) assert ((fq_scov & (16'h1111 << s)) == '0);
    // frees only in FREE, and only flagged vertices, never while f_busy (warp path)
    if (pt_free) assert ($past(st) == S_FREE && $past(lu[fi]));
    if (pt_free && !direct) assert (!$past(f_busy));
    // a sequence number is requested once per direct triangle only
    if (sq_req) assert (direct);
  end

  always_ff @(posedge clk) if (rst_n) begin
    cover (fq_valid && fq_ready && !fq_end && ms4 && fq_scov != 16'hFFFF && fq_scov != 0);
    cover (fq_valid && fq_ready && fq_end && f_past);
    cover (dx_valid && dx_ready && dx_last && dx_mask != 0);
    cover (pt_free && st == S_IDLE);
  end
`endif
endmodule
