// ============================================================================
// ad_rx_frag -- fragment warps.
//
// Packs the covered quads of one triangle (from ad_rx_scan) into 32-lane
// warps (QUAD_MX = 8 quads), copies the triangle's varyings from the PT into
// the warp's primitive table, writes each lane's registers and starts the warp
// with a sequence number for the ROP order:
//   r0 b0, r1 b1, r2 b2, r3 z, r4 x + 0.5, r5 y + 0.5, r6 the lane's 4 sample bits,
//   r7-r9 b0 b1 b2 at the centroid (MS_CTRL[4] CENTROID only).
// r3: clamped to [0, 1] with one sample and DEPTH_CLAMP[1] = 0; not clamped
// with four samples (the ROP adds each sample's slope) or with DEPTH_CLAMP[1].
// Primitive table: {0, v, w} <- PT word 4 + w of vertex v; 0xFFF the map (0);
// 0xFF8-0xFFB the samples' depth slopes (four samples).
//
// Fixes vs atg_rx_frag: decoded state (VARYING_COUNT is clamped once, in
// ad_rx_state); t_tri carries SPT_WID bits; the lane arithmetic is
// ad_rx_bary (~45 cycles per quad, not ~200 as the atg text still said).
// ============================================================================
module ad_rx_frag (
  input  logic                               clk,
  input  logic                               rst_n,
  // decoded state
  input  logic [6:0]                         i_varyc,
  input  logic [4:0]                         i_msctl,
  input  logic [1:0]                         i_dclmp,
  // the triangle
  input  logic                               t_load,
  input  logic [ad_rx_pkg::SPT_WID-1:0]      t_tri,
  // covered quads
  input  logic                               fq_valid,
  output logic                               fq_ready,
  input  logic [ad_rx_pkg::QXY_WID-1:0]      fq_xy,
  input  logic [ad_rx_pkg::MS_COVW-1:0]      fq_scov,
  input  logic [3:0]                         fq_ccov,
  input  logic                               fq_end,
  output logic                               busy,
  // PT of SU 0
  output logic                               pt_rd,
  output logic [ad_rx_pkg::PT_IDXW-1:0]      pt_idx,
  output logic [ad_rx_pkg::PT_WRDW-1:0]      pt_word,
  input  logic [31:0]                        pt_rdata,
  output logic                               pt_busy,
  // warps to the SU
  output logic                               fl_req,
  input  logic                               fl_gnt,
  output logic                               fl_we,
  output logic [ad_rx_pkg::FL_REGW-1:0]      fl_reg,
  output logic [ad_rx_pkg::LANE_IW-1:0]      fl_lane,
  output logic [31:0]                        fl_data,
  output logic                               fl_pw_we,
  output logic [ad_rx_pkg::FL_ADRW-1:0]      fl_pw_addr,
  output logic [31:0]                        fl_pw_data,
  output logic                               fl_go,
  output logic [ad_rx_pkg::LANE_NB-1:0]      fl_mask,
  output logic [ad_rx_pkg::FL_INFW-1:0]      fl_info,
  // sequence numbers
  output logic                               sq_req,
  input  logic [ad_rx_pkg::SEQ_WID-1:0]      sq_seq
);
  localparam int NQ = ad_rx_pkg::QUAD_MX;
  localparam int CW = ad_rx_pkg::CRD_WID;
  localparam int PI = ad_rx_pkg::PT_IDXW;

  typedef enum logic [3:0] {F_COL, F_ALLOC, F_DZ, F_DZW, F_COPY, F_MAP, F_DS,
                            F_BARYC, F_BCW, F_BARY, F_BW, F_WR, F_GO} st_t;
  st_t st;

  logic [ad_rx_pkg::SPT_WID-1:0] tg;
  logic          dz_done;                          // this triangle's d_s computed
  always_ff @(posedge clk) if (!rst_n) tg <= '0; else if (t_load) tg <= t_tri;

  logic ms4, cent;
  assign ms4  = (i_msctl[3:0] == 4'd2);
  assign cent = i_msctl[4];

  // ---------------------------------------------------------------- held quads
  logic [CW-1:0] hx [NQ], hy [NQ];
  logic [15:0]   hs [NQ];
  logic [3:0]    hc [NQ];
  logic [3:0]    nh;                               // quads held
  logic [2:0]    qi;                               // quad being written

  assign fq_ready = (st == F_COL) && (nh < 4'(NQ));
  assign busy     = (nh != 0) || (st != F_COL);

  // ---------------------------------------------------------------- bary
  logic          b_start, b_dz, b_busy, b_done;
  logic [11:0]   osel;
  logic [127:0]  b0, b1, b2, bz, bds;
  logic [127:0]  c0, c1, c2;                       // centroid barycentrics
  logic [127:0]  ds_q;
  ad_rx_bary u_bary (.clk, .rst_n, .i_start(b_start), .i_dz(b_dz),
                     .i_pl(tg[ad_rx_pkg::SPT_PLZ +: ad_rx_pkg::PLN_ALL]),
                     .i_qx(hx[qi]), .i_qy(hy[qi]),
                     .i_bx0(tg[ad_rx_pkg::SPT_BBX +: CW]), .i_by0(tg[ad_rx_pkg::SPT_BBX + CW +: CW]),
                     .i_osel(osel), .busy(b_busy), .o_done(b_done),
                     .o_b0(b0), .o_b1(b1), .o_b2(b2), .o_z(bz), .o_ds(bds));
  assign b_dz    = (st == F_DZ);
  assign b_start = (st == F_BARYC && cneed) || (st == F_BARY);

  // centroid locations: the centre, or the lowest covered sample of a lane whose centre is out
  logic [11:0] csel;
  logic        cneed;
  always_comb begin
    csel = '0; cneed = 1'b0;
    for (int l = 0; l < 4; l++) begin
      if (!hc[qi][l] && hs[qi][4*l +: 4] != 0) begin
        cneed = 1'b1;
        if      (hs[qi][4*l])     csel[3*l +: 3] = 3'd1;
        else if (hs[qi][4*l + 1]) csel[3*l +: 3] = 3'd2;
        else if (hs[qi][4*l + 2]) csel[3*l +: 3] = 3'd3;
        else                      csel[3*l +: 3] = 3'd4;
      end
    end
  end
  assign osel = (st == F_BARYC || st == F_BCW) ? csel : 12'd0;   // held through the pass

  // ---------------------------------------------------------------- copy
  logic [1:0] cv;                                  // vertex
  logic [6:0] cw;                                  // word
  logic       crd;                                 // read issued last cycle
  logic [1:0] pv_v; logic [6:0] pv_w;              // address of that read
  assign pt_busy = (st == F_COPY);
  assign pt_rd   = (st == F_COPY) && (cv != 2'd3) && (i_varyc != 0);
  assign pt_idx  = tg[ad_rx_pkg::SPT_PTE + PI*cv +: PI];
  assign pt_word = 7'd4 + cw;

  // ---------------------------------------------------------------- register writes
  logic [1:0]  wl;                                 // lane
  logic [3:0]  wr;                                 // register
  logic [3:0]  nreg;
  assign nreg = cent ? 4'd10 : 4'd7;
  logic [31:0] zc, rx, ry, rv;
  logic [CW:0] x2, y2;
  assign x2 = {hx[qi] + CW'(wl & 1), 1'b1};       // 2 x + 1
  assign y2 = {hy[qi] + CW'(wl >> 1), 1'b1};
  ad_rx_i2f #(.W(CW+2), .F(1)) u_rx (.v({1'b0, x2}), .f(rx));
  ad_rx_i2f #(.W(CW+2), .F(1)) u_ry (.v({1'b0, y2}), .f(ry));
  logic [31:0] zl;
  assign zl = bz[32*wl +: 32];
  always_comb begin
    if (i_dclmp[1] || ms4)                                       zc = zl;
    else if ((zl[30:23] == 8'hFF && zl[22:0] != 0) || (zl[31] && zl[30:0] != 0)) zc = 32'd0;
    else if (zl[30:0] >= ad_rx_pkg::FP_ONEV[30:0])               zc = ad_rx_pkg::FP_ONEV;
    else                                                         zc = zl;
  end
  always_comb begin
    case (wr)
      4'd0: rv = b0[32*wl +: 32];
      4'd1: rv = b1[32*wl +: 32];
      4'd2: rv = b2[32*wl +: 32];
      4'd3: rv = zc;
      4'd4: rv = rx;
      4'd5: rv = ry;
      4'd6: rv = {28'd0, hs[qi][4*wl +: 4]};
      4'd7: rv = c0[32*wl +: 32];
      4'd8: rv = c1[32*wl +: 32];
      default: rv = c2[32*wl +: 32];
    endcase
  end
  assign fl_we   = (st == F_WR);
  assign fl_reg  = 6'(wr);
  assign fl_lane = {qi, wl};
  assign fl_data = rv;

  // ---------------------------------------------------------------- warp start
  logic [31:0] mask, cov;
  always_comb begin
    mask = '0; cov = '0;
    for (int q = 0; q < NQ; q++)
      if (4'(q) < nh) begin
        mask[4*q +: 4] = 4'b1111;                  // whole quads (helper lanes)
        for (int l = 0; l < 4; l++) cov[4*q + l] = (hs[q][4*l +: 4] != 0);
      end
  end
  assign fl_req  = (st == F_ALLOC);
  assign fl_go   = (st == F_GO);
  assign sq_req  = (st == F_GO);
  assign fl_mask = mask;
  assign fl_info = {15'd0, tg[ad_rx_pkg::SPT_FRT], sq_seq, cov};

  // primitive-table writes
  logic [2:0] dsi;
  always_comb begin
    fl_pw_we = 1'b0; fl_pw_addr = '0; fl_pw_data = '0;
    if (st == F_COPY && crd) begin
      fl_pw_we = 1'b1; fl_pw_addr = {3'd0, 1'b0, pv_v, pv_w[5:0]}; fl_pw_data = pt_rdata;
    end else if (st == F_MAP) begin
      fl_pw_we = 1'b1; fl_pw_addr = 12'hFFF; fl_pw_data = 32'd0;
    end else if (st == F_DS) begin
      fl_pw_we = 1'b1; fl_pw_addr = 12'hFF8 + 12'(dsi); fl_pw_data = ds_q[32*dsi +: 32];
    end
  end

  // ---------------------------------------------------------------- FSM
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= F_COL; nh <= '0; qi <= '0; cv <= '0; cw <= '0; crd <= 1'b0; pv_v <= '0; pv_w <= '0;
      wl <= '0; wr <= '0; dsi <= '0; dz_done <= 1'b0; ds_q <= '0; c0 <= '0; c1 <= '0; c2 <= '0;
    end else begin
      if (t_load) dz_done <= 1'b0;
      case (st)
        F_COL: begin
          if (fq_valid && fq_ready) begin
            if (fq_end) begin
              if (nh != 0) st <= F_ALLOC;
            end else begin
              hx[nh[2:0]] <= fq_xy[CW-1:0]; hy[nh[2:0]] <= fq_xy[2*CW-1:CW];
              hs[nh[2:0]] <= fq_scov; hc[nh[2:0]] <= fq_ccov;
              nh <= nh + 1'b1;
              if (nh == 4'(NQ - 1)) st <= F_ALLOC;
            end
          end
        end
        F_ALLOC: if (fl_gnt) begin
          cv <= '0; cw <= '0; crd <= 1'b0;
          st <= (ms4 && !dz_done) ? F_DZ : F_COPY;
        end
        F_DZ:  st <= F_DZW;
        F_DZW: if (b_done) begin ds_q <= bds; dz_done <= 1'b1; st <= F_COPY; end
        F_COPY: begin                              // one read per cycle, written the next
          crd <= pt_rd; pv_v <= cv; pv_w <= cw;
          if (pt_rd) begin
            if (cw + 1'b1 >= i_varyc) begin cw <= '0; cv <= cv + 1'b1; end
            else cw <= cw + 1'b1;
          end
          if (!pt_rd && !crd) st <= F_MAP;         // all reads issued and written
        end
        F_MAP: begin dsi <= '0; st <= ms4 ? F_DS : (cent ? F_BARYC : F_BARY); qi <= '0; end
        F_DS:  begin
          dsi <= dsi + 1'b1;
          if (dsi == 3'd3) st <= cent ? F_BARYC : F_BARY;
        end
        F_BARYC: st <= cneed ? F_BCW : F_BARY;     // b_start pulsed; skip when not needed
        F_BCW: if (b_done) begin c0 <= b0; c1 <= b1; c2 <= b2; st <= F_BARY; end
        F_BARY: st <= F_BW;
        F_BW: if (b_done) begin
          if (cent && !cneed) begin c0 <= b0; c1 <= b1; c2 <= b2; end   // centroid = centre
          wl <= '0; wr <= '0; st <= F_WR;
        end
        F_WR: begin
          if (wr + 1'b1 == nreg) begin
            wr <= '0;
            if (wl == 2'd3) begin
              if (qi + 1'b1 == nh[2:0] || (nh == 4'(NQ) && qi == 3'(NQ - 1))) st <= F_GO;
              else begin qi <= qi + 1'b1; st <= cent ? F_BARYC : F_BARY; end
            end
            wl <= wl + 1'b1;
          end else wr <= wr + 1'b1;
        end
        F_GO: begin nh <= '0; qi <= '0; st <= F_COL; end
        default: st <= F_COL;
      endcase
    end
  end

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  always @(posedge clk) if (f_vld && rst_n) begin
    assert (nh <= 4'(NQ));
    if (fl_go) assert (nh != 0 && fl_mask != 0);
    if (fl_go) assert ((fl_info[31:0] & ~fl_mask) == 0);   // coverage within EXEC
    if (pt_rd) assert (pt_busy);
    if (fl_pw_we && st == F_COPY) assert (fl_pw_addr[5:0] < 6'(i_varyc) || i_varyc == 7'd64);
    if (fl_we) assert (fl_reg < 6'(nreg) && {1'b0, qi} < nh);
    if (sq_req) assert (fl_go);
  end
`endif
endmodule
