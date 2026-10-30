// ============================================================================
// ad_rx_cpoly -- the clipping polygon of one primitive (Sutherland-Hodgman).
//
// A buffer of two banks x PLY_MAX vertices (VTX_WID bits: x y z w b0 b1 b2,
// fp32).  ad_rx_clip loads the vertices into bank 0, then issues one cut per
// clip plane; each cut reads the current bank and writes the other.
//
// Plane distances (inside: d >= 0, -0 and denormals inside, NaN outside):
//   0  w - 2^-16            1  z                    2  w - z
//   3  G w - (xo w + xs x)  4  G w + (xo w + xs x)  5, 6 the same in y; G = 16383
// evaluated in that order of operations (xo w, xs x, sum, G w, G w -/+ sum).
// Intersection from the inside vertex a to the outside one b:
//   t = d_a / (d_a - d_b);  v_c = a_c + (b_c - a_c) t   for all 7 words.
// A polygon's edges start at the first inside vertex after an outside one; a
// line has the one edge (0, 1) and no closing edge.
//
// Fixes vs atg_rx_cpoly: ld_we writes one whole vertex (the atg text still
// said "one vertex word"); the duplicate spec file is dropped; widths from
// ad_rx_pkg.  One fadd, one fmul, one fdiv, shared.
// ============================================================================
module ad_rx_cpoly (
  input  logic                               clk,
  input  logic                               rst_n,
  input  logic [4*ad_rx_pkg::FP_WDTH-1:0]    vp,        // {y off, x off, y scale, x scale}
  input  logic                               ld_we,     // write one vertex (idle only)
  input  logic [ad_rx_pkg::PLY_IDX-1:0]      ld_idx,
  input  logic [ad_rx_pkg::VTX_WID-1:0]      ld_data,
  input  logic [ad_rx_pkg::PLY_IDX-1:0]      ld_n,      // vertex count, taken with cmd_first
  input  logic                               ld_line,   // a line segment (taken with cmd_first)
  input  logic                               cmd_valid,
  output logic                               cmd_ready,
  input  logic [ad_rx_pkg::CPL_SEL-1:0]      cmd_plane,
  input  logic                               cmd_first,
  output logic                               done,      // one cycle
  output logic [ad_rx_pkg::PLY_IDX-1:0]      n_out,     // vertex count now
  input  logic [ad_rx_pkg::PLY_IDX-1:0]      rd_idx,
  output logic [ad_rx_pkg::VTX_WID-1:0]      rd_data    // the cycle after rd_idx
);
  localparam int NV = ad_rx_pkg::PLY_MAX;
  localparam int IW = ad_rx_pkg::PLY_IDX;
  localparam int VW = ad_rx_pkg::VTX_WID;

  typedef enum logic [3:0] {P_IDLE, P_DIST, P_EVAL, P_EDGE, P_EMIT, P_DEN, P_DIV, P_DWT,
                            P_WSUB, P_WMUL, P_WADD, P_WRV, P_LAST, P_FIN} st_t;
  st_t st;

  logic [VW-1:0]  vb [2*NV];                      // bank b vertex i at b*NV + i
  logic           cur;                            // the bank holding the polygon
  logic [IW-1:0]  n;                              // its vertex count
  logic           line;
  logic [2:0]     pl;
  logic [31:0]    dst [NV];
  logic [NV-1:0]  ins;

  // ---------------------------------------------------------------- fp units
  logic [31:0] t1, t2, t3;                        // step temporaries
  logic [31:0] fd_a;
  logic [31:0] fa_a, fa_b, fa_r, fm_a, fm_b, fm_r, fd_r;
  logic        fa_sub, fd_go, fd_busy, fd_done;
  ad_rx_fadd u_fadd (.i_a(fa_a), .i_b(fa_b), .i_sub(fa_sub), .o_r(fa_r));
  ad_rx_fmul u_fmul (.i_a(fm_a), .i_b(fm_b), .o_r(fm_r));
  ad_rx_fdiv u_fdiv (.clk, .rst_n, .i_start(fd_go), .i_a(fd_a), .i_b(t1),
                     .busy(fd_busy), .o_done(fd_done), .o_r(fd_r));

  // ---------------------------------------------------------------- distance steps
  logic [IW-1:0] vi;                              // vertex being measured
  logic [2:0]    ds;                              // step within the distance
  logic [VW-1:0] vcur;
  logic [31:0]   vx, vy, vz, vw, sc, of, cc;
  assign vcur = vb[{1'b0, cur} * NV + vi];        // index: bank * NV + vertex
  assign vx = vcur[0 +: 32];
  assign vy = vcur[32 +: 32];
  assign vz = vcur[64 +: 32];
  assign vw = vcur[96 +: 32];
  assign sc = (pl >= 3'd5) ? vp[32 +: 32] : vp[0 +: 32];
  assign of = (pl >= 3'd5) ? vp[96 +: 32] : vp[64 +: 32];
  assign cc = (pl >= 3'd5) ? vy : vx;
  logic [2:0] ds_last;
  assign ds_last = (pl >= 3'd3) ? 3'd4 : 3'd0;

  function automatic logic is_in(input logic [31:0] d);
    is_in = !((d[30:23] == 8'hFF) && (d[22:0] != 0)) && (!d[31] || d[30:23] == 8'd0);
  endfunction

  // ---------------------------------------------------------------- cut bookkeeping
  logic [IW-1:0] s0;                              // first edge's start
  logic [IW-1:0] k;                               // edge count done
  logic [IW-1:0] m;                               // vertices written to the other bank
  logic [IW-1:0] pi, qi;                          // the edge (p, q)
  logic          pdone;                           // p already emitted for this edge
  logic [2:0]    wc;                              // word of the intersection
  logic [VW-1:0] nv;                              // the intersection being built

  always_comb begin
    pi = (s0 + k >= n) ? (s0 + k - n) : (s0 + k);
    qi = (pi + 1'b1 == n) ? '0 : pi + 1'b1;
  end

  logic [NV-1:0] act;                             // vertices that exist
  always_comb for (int i = 0; i < NV; i++) act[i] = (IW'(i) < n);

  logic          all_in, all_out;
  assign all_in  = ((ins | ~act) == {NV{1'b1}});
  assign all_out = ((ins & act) == '0);

  // first inside vertex after an outside one (polygons); 0 for a line
  logic [IW-1:0] s_c;
  always_comb begin
    s_c = '0;
    for (int i = NV - 1; i >= 0; i--) begin
      if (IW'(i) < n && ins[i] && !ins[(i == 0) ? (n - 1'b1) : IW'(i - 1)])
        s_c = IW'(i);
    end
    if (line) s_c = '0;
  end

  logic          ap_in;                           // p is the inside end of the crossing
  logic [VW-1:0] va, vbo;                         // inside a, outside b
  assign ap_in = ins[pi];
  assign va  = vb[{1'b0, cur} * NV + (ap_in ? pi : qi)];
  assign vbo = vb[{1'b0, cur} * NV + (ap_in ? qi : pi)];

  // fp operand selection
  always_comb begin
    fa_a = '0; fa_b = '0; fa_sub = 1'b0; fm_a = '0; fm_b = '0; fd_go = 1'b0; fd_a = dst[ap_in ? pi : qi];
    case (st)
      P_DIST: case (pl)
        3'd0: begin fa_a = vw; fa_b = ad_rx_pkg::FP_WMIN; fa_sub = 1'b1; end
        3'd2: begin fa_a = vw; fa_b = vz; fa_sub = 1'b1; end
        3'd1: ;
        default: case (ds)
          3'd0: begin fm_a = of; fm_b = vw; end
          3'd1: begin fm_a = sc; fm_b = cc; end
          3'd2: begin fa_a = t1; fa_b = t2; end
          3'd3: begin fm_a = ad_rx_pkg::FP_GRDB; fm_b = vw; end
          default: begin fa_a = t1; fa_b = t3; fa_sub = (pl == 3'd3) || (pl == 3'd5); end
        endcase
      endcase
      P_DEN:  begin fa_a = dst[ap_in ? pi : qi]; fa_b = dst[ap_in ? qi : pi]; fa_sub = 1'b1; end
      P_DIV:  fd_go = 1'b1;
      P_WSUB: begin fa_a = vbo[32*wc +: 32]; fa_b = va[32*wc +: 32]; fa_sub = 1'b1; end
      P_WMUL: begin fm_a = t2; fm_b = t3; end
      P_WADD: begin fa_a = va[32*wc +: 32]; fa_b = t2; end
      default: ;
    endcase
  end

  // ---------------------------------------------------------------- FSM
  assign cmd_ready = (st == P_IDLE);
  assign n_out = n;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= P_IDLE; done <= 1'b0; cur <= 1'b0; n <= '0; line <= 1'b0; pl <= '0;
      vi <= '0; ds <= '0; k <= '0; m <= '0; s0 <= '0; pdone <= 1'b0; wc <= '0;
      t1 <= '0; t2 <= '0; t3 <= '0; ins <= '0; nv <= '0;
    end else begin
      done <= 1'b0;
      case (st)
        P_IDLE: begin
          if (ld_we) vb[ld_idx] <= ld_data;        // bank 0
          if (cmd_valid) begin
            pl <= cmd_plane; vi <= '0; ds <= '0;
            if (cmd_first) begin n <= ld_n; line <= ld_line; cur <= 1'b0; end
            st <= P_DIST;
          end
        end
        P_DIST: begin                              // one step per cycle
          if (pl >= 3'd3) begin
            case (ds)
              3'd0: t1 <= fm_r;
              3'd1: t2 <= fm_r;
              3'd2: t3 <= fa_r;
              3'd3: t1 <= fm_r;
              default: ;
            endcase
          end
          if (ds == ds_last) begin
            dst[vi] <= (pl == 3'd1) ? vz : fa_r;
            ins[vi]  <= is_in((pl == 3'd1) ? vz : fa_r);
            ds <= '0;
            if (vi + 1'b1 >= n) st <= P_EVAL;
            vi <= vi + 1'b1;
          end else
            ds <= ds + 1'b1;
        end
        P_EVAL: begin
          k <= '0; m <= '0; pdone <= 1'b0; s0 <= s_c;
          if (all_in)       st <= P_FIN;           // unchanged
          else if (all_out) begin n <= '0; st <= P_FIN; end
          else              st <= P_EDGE;
        end
        P_EDGE: begin                              // emit p if inside, then the crossing
          if (ins[pi] && !pdone) begin
            vb[{1'b0, ~cur} * NV + m] <= vb[{1'b0, cur} * NV + pi];
            m <= m + 1'b1; pdone <= 1'b1;
          end else if (ins[pi] != ins[qi]) begin
            st <= P_DEN;
          end else
            st <= P_EMIT;
        end
        P_DEN:  begin t1 <= fa_r; st <= P_DIV; end // d_a - d_b
        P_DIV:  st <= P_DWT;                       // fdiv started
        P_DWT:  if (fd_done) begin t3 <= fd_r; wc <= '0; st <= P_WSUB; end
        P_WSUB: begin t2 <= fa_r; st <= P_WMUL; end
        P_WMUL: begin t2 <= fm_r; st <= P_WADD; end
        P_WADD: begin
          nv[32*wc +: 32] <= fa_r;
          if (wc == 3'd6) st <= P_WRV;
          else begin wc <= wc + 1'b1; st <= P_WSUB; end
        end
        P_WRV: begin
          vb[{1'b0, ~cur} * NV + m] <= nv;
          m <= m + 1'b1; st <= P_EMIT;
        end
        P_EMIT: begin                              // next edge
          pdone <= 1'b0;
          if (line) st <= P_LAST;
          else if (k + 1'b1 >= n) begin n <= m; cur <= ~cur; st <= P_FIN; end
          else begin k <= k + 1'b1; st <= P_EDGE; end
        end
        P_LAST: begin                              // a line: its end q if inside
          if (ins[1]) begin
            vb[{1'b0, ~cur} * NV + m] <= vb[{1'b0, cur} * NV + 1];
            n <= m + 1'b1;
          end else
            n <= m;
          cur <= ~cur; st <= P_FIN;
        end
        P_FIN: begin done <= 1'b1; st <= P_IDLE; end
        default: st <= P_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) rd_data <= vb[{1'b0, cur} * NV + rd_idx];

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  logic [IW-1:0] f_n0;                             // n at the start of the cut
  logic [IW:0]   f_nin, f_ncr;                     // inside vertices / crossings of the cut
  always_comb begin
    f_nin = '0; f_ncr = '0;
    for (int i = 0; i < NV; i++) if (IW'(i) < n) begin
      if (ins[i]) f_nin = f_nin + 1'b1;
      if (line ? (i == 0 && ins[0] != ins[1])
               : (ins[i] != ins[(IW'(i) + 1'b1 == n) ? 0 : i + 1])) f_ncr = f_ncr + 1'b1;
    end
  end
  always @(posedge clk) if (f_vld && rst_n) begin
    if (st == P_DIST && vi == 0 && ds == 0) f_n0 <= n;   // n as the cut starts
    assert (n <= IW'(NV));
    assert (m <= IW'(NV));
    if (st != P_IDLE && st != P_DIST && st != P_EVAL && st != P_FIN) assert (m <= f_nin + f_ncr);
    if (st == P_EDGE || st == P_EMIT) assert (k < n);
    if (done) assert ($past(st) == P_FIN);
    if (line && st == P_IDLE) assert (n <= IW'(2));
  end
  // a polygon grows by at most one vertex per cut; a line stays <= 2
  always @(posedge clk) if (f_vld && rst_n && $past(rst_n) && done && !$past(line)) begin
    assert (n <= f_n0 + 1'b1);
  end
`endif
endmodule
