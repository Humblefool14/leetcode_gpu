// ============================================================================
// ad_rx_clip -- primitive input and clipping.
//
// Reads the clip-space positions of a primitive's vertices from the PT (or
// DRAW_RAW's screen-space vertices), clips points, lines and triangles against
// the planes  0 w >= 2^-16 (always), 1 near z >= 0, 2 far z <= w, 3-6 the
// guard band |xo w + xs x| <= 16383 w (same in y), and passes the results to
// ad_rx_setup with weights relative to the original vertices.
//
// Near applies when DEPTH_CLAMP[1] (clip) && !DEPTH_CLAMP[0] (clamp), or
// always when DEPTH_CLAMP[1] = 0; far only when [1] && ![0].
// Trivial accept (compares only, no arithmetic): every vertex w >= 2^-16,
// |x| <= 4w, |y| <= 4w, inside the applicable depth planes, and the viewport
// within |xo|,|yo| <= 6144, |xs|,|ys| <= 2048 (6144 + 4 x 2048 = 14336 <= 16383).
// Otherwise the vertices go to ad_rx_cpoly, each applicable plane cuts in
// order (3-6 only when the xy check failed), a triangle's polygon is emitted
// as a fan (up to 8 triangles), a line as one line.  Nothing left, or
// RAST_MODE[6] (discard): one empty triangle carrying the last-use flags.
//
// Fixes vs atg_rx_clip: decoded state from ad_rx_state (no private viewport
// array), prim_vtx is 26 bits at the top too (atg_rx said 24), kind 3 reads
// as a triangle, widths from ad_rx_pkg.
// ============================================================================
module ad_rx_clip (
  input  logic                               clk,
  input  logic                               rst_n,
  // decoded state
  input  logic [4*32-1:0]                    i_vp,      // xs ys xo yo
  input  logic [1:0]                         i_dclmp,
  input  logic                               i_discard, // RAST_MODE[6]
  input  logic [9*32-1:0]                    i_rawv,
  input  logic                               raw_kick,
  // primitives
  input  logic                               prim_valid,
  output logic                               prim_ready,
  input  logic [ad_rx_pkg::PRM_VTW-1:0]      prim_vtx,
  input  logic [2:0]                         prim_free,
  input  logic                               prim_last,
  // PT read (ad_rx_frag has priority)
  output logic                               pt_rd,
  output logic [ad_rx_pkg::PT_IDXW-1:0]      pt_idx,
  output logic [ad_rx_pkg::PT_WRDW-1:0]      pt_word,
  input  logic [31:0]                        pt_rdata,
  input  logic                               pt_busy,
  // to setup
  output logic                               cl_valid,
  input  logic                               cl_ready,
  output logic [ad_rx_pkg::CLT_WID-1:0]      cl_tri,
  output logic                               cl_last,
  output logic                               busy
);
  localparam int PI = ad_rx_pkg::PT_IDXW;
  localparam int VW = ad_rx_pkg::VTX_WID;
  localparam int IW = ad_rx_pkg::PLY_IDX;

  typedef enum logic [3:0] {C_IDLE, C_READ, C_TRIV, C_LOAD, C_CMD, C_CWAIT,
                            C_EMIT, C_EWT, C_OUT} st_t;
  st_t st;

  // ---------------------------------------------------------------- primitive
  logic [3*PI-1:0] pv;                            // PT entries
  logic [1:0]      kind;                          // 0 point 1 line 2 triangle
  logic [2:0]      pfree;
  logic            plast;
  logic [31:0]     pos [12];                      // v0 x y z w, v1 ..., v2 ...
  logic [3:0]      rw;                            // PT word being read (0-11)
  logic            rpend;                         // a read issued last cycle
  logic [3:0]      nwords;
  assign nwords = (kind == 2'd0) ? 4'd4 : (kind == 2'd1) ? 4'd8 : 4'd12;

  // ---------------------------------------------------------------- plane applicability
  logic near_on, far_on;
  assign near_on = (i_dclmp[1] && !i_dclmp[0]) || !i_dclmp[1];
  assign far_on  = i_dclmp[1] && !i_dclmp[0];

  // exact fp32 compares (no flushing)
  function automatic logic f_nan(input logic [31:0] a);
    f_nan = (a[30:23] == 8'hFF) && (a[22:0] != 0);
  endfunction
  function automatic logic f_ge0(input logic [31:0] a);  // a >= 0 (-0 included)
    f_ge0 = !f_nan(a) && (!a[31] || a[30:0] == 0);
  endfunction
  function automatic logic f_le(input logic [31:0] a, input logic [31:0] b); // a <= b, b > 0
    f_le = !f_nan(a) && (a[31] ? 1'b1 : (a[30:0] <= b[30:0]));
  endfunction
  function automatic logic f_absle(input logic [31:0] a, input logic [31:0] b); // |a| <= b, b > 0
    f_absle = !f_nan(a) && (a[30:0] <= b[30:0]);
  endfunction

  logic [2:0] w_ok, n_ok, f_ok, xy_ok;
  for (genvar i = 0; i < 3; i++) begin : g_v
    logic [31:0] x, y, z, w, w4;
    assign x = pos[4*i]; assign y = pos[4*i+1]; assign z = pos[4*i+2]; assign w = pos[4*i+3];
    assign w4 = (w[30:23] >= 8'd253) ? {1'b0, 8'hFF, 23'd0} : {w[31], w[30:23] + 8'd2, w[22:0]};
    assign w_ok[i]  = !f_nan(w) && !w[31] && (w[30:0] >= ad_rx_pkg::FP_WMIN[30:0]);
    assign n_ok[i]  = !near_on || f_ge0(z);
    assign f_ok[i]  = !far_on || f_le(z, w);
`ifdef MUT_WCLIP
    assign xy_ok[i] = f_absle(x, w4) && f_absle(y, w4);
`else
    assign xy_ok[i] = w_ok[i] && f_absle(x, w4) && f_absle(y, w4);
`endif
  end
  logic vp_ok;
  assign vp_ok = f_absle(i_vp[64 +: 32], ad_rx_pkg::FP_VOFF) && f_absle(i_vp[96 +: 32], ad_rx_pkg::FP_VOFF) &&
                 f_absle(i_vp[0 +: 32], ad_rx_pkg::FP_VSCL)  && f_absle(i_vp[32 +: 32], ad_rx_pkg::FP_VSCL);
  logic triv, guard;
`ifdef MUT_FARCLIP
  assign triv  = (&w_ok) && (&n_ok) && (&xy_ok) && vp_ok;
`else
  assign triv  = (&w_ok) && (&n_ok) && (&f_ok) && (&xy_ok) && vp_ok;
`endif
  assign guard = !((&xy_ok) && vp_ok);
  logic pt_in;                                    // a point is inside planes 0-2
  assign pt_in = w_ok[0] && n_ok[0] && f_ok[0];

  // ---------------------------------------------------------------- cpoly
  logic          ld_we, cmd_valid, cmd_ready, cmd_first, cp_done;
  logic [IW-1:0] ld_idx, n_out, rd_idx;
  logic [VW-1:0] ld_data, rd_data;
  logic [2:0]    cmd_plane;
  ad_rx_cpoly u_cpoly (.clk, .rst_n, .vp(i_vp), .ld_we, .ld_idx, .ld_data,
                       .ld_n((kind == 2'd1) ? IW'(2) : IW'(3)), .ld_line(kind == 2'd1),
                       .cmd_valid, .cmd_ready, .cmd_plane, .cmd_first, .done(cp_done),
                       .n_out, .rd_idx, .rd_data);

  // identity weights of vertex i
  function automatic logic [95:0] idw(input logic [1:0] i);
    idw = '0;
    idw[32*i +: 32] = ad_rx_pkg::FP_ONEV;
  endfunction
  always_comb begin
    ld_data = {idw(ld_idx[1:0]), pos[4*ld_idx+3], pos[4*ld_idx+2], pos[4*ld_idx+1], pos[4*ld_idx]};
  end

  // ---------------------------------------------------------------- plane sequence
  logic [2:0] pl;
  logic       pfirst;
  function automatic logic pl_on(input logic [2:0] p, input logic nr, input logic fr, input logic gd);
    case (p)
      3'd0: pl_on = 1'b1;
      3'd1: pl_on = nr;
      3'd2: pl_on = fr;
      default: pl_on = gd;
    endcase
  endfunction
  logic gd_q;                                     // guard planes needed (latched)
  logic [2:0] pl_next;                            // the next applicable plane after pl
  logic       pl_found;
  always_comb begin
    pl_found = 1'b0; pl_next = pl;
    for (int p = 6; p >= 1; p--)
      if (3'(p) > pl && pl_on(3'(p), near_on, far_on, gd_q)) begin pl_next = 3'(p); pl_found = 1'b1; end
  end

  // ---------------------------------------------------------------- fan emission
  logic [IW-1:0] fi;                              // fan triangle: (v0, v_fi, v_fi+1)
  logic [1:0]    fv;                              // vertex of the output being read
  logic [VW-1:0] ov [3];
  logic          ofin;                            // last output of this primitive
  logic          o_empty;
  logic          o_raw;
  logic [1:0]    o_kind;

  assign cmd_plane = pl;
  assign cmd_valid = (st == C_CMD);
  assign cmd_first = pfirst;
  assign ld_we     = (st == C_LOAD);
  assign ld_idx    = IW'(rw);
  assign rd_idx    = (fv == 2'd0) ? IW'(0) : (fv == 2'd1) ? fi : fi + 1'b1;

  assign prim_ready = (st == C_IDLE) && !raw_kick;
  assign busy       = (st != C_IDLE);

  // PT reads: one word per cycle while frag is not using the port
  assign pt_rd   = (st == C_READ) && !pt_busy && (rw < nwords) && !rpend;
  assign pt_idx  = pv[PI*rw[3:2] +: PI];
  assign pt_word = ad_rx_pkg::PT_WRDW'(rw[1:0]);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= C_IDLE; cl_valid <= 1'b0; cl_last <= 1'b0; rw <= '0; rpend <= 1'b0;
      pv <= '0; kind <= '0; pfree <= '0; plast <= 1'b0; pl <= '0; pfirst <= 1'b0; gd_q <= 1'b0;
      fi <= '0; fv <= '0; ofin <= 1'b0; o_empty <= 1'b0; o_raw <= 1'b0; o_kind <= '0;
    end else begin
      case (st)
        C_IDLE: begin
          o_raw <= 1'b0; o_empty <= 1'b0;
          if (raw_kick) begin                      // DRAW_RAW: screen space, no clipping
            o_raw <= 1'b1; o_kind <= 2'd2; ofin <= 1'b1; pfree <= '0; plast <= 1'b0;
            for (int i = 0; i < 3; i++)
              ov[i] <= {idw(2'(i)), ad_rx_pkg::FP_ONEV, i_rawv[96*i+64 +: 32], i_rawv[96*i+32 +: 32], i_rawv[96*i +: 32]};
            st <= C_OUT;
          end else if (prim_valid) begin
            pv <= prim_vtx[3*PI-1:0];
            kind <= (prim_vtx[3*PI +: 2] == 2'd3) ? 2'd2 : prim_vtx[3*PI +: 2];
            pfree <= prim_free; plast <= prim_last; rw <= '0; rpend <= 1'b0;
            if (i_discard) begin o_empty <= 1'b1; o_kind <= 2'd2; ofin <= 1'b1; st <= C_OUT; end
            else st <= C_READ;
          end
        end
        C_READ: begin
          rpend <= pt_rd;
          if (pt_rd) rw <= rw + 1'b1;
          if (rpend) pos[rw - 1'b1] <= pt_rdata;
          if (rpend && rw == nwords) begin
            // expand: a point (p, p, p), a line (a, b, b)
            st <= C_TRIV;
          end
        end
        C_TRIV: begin
          if (kind == 2'd0) for (int c = 0; c < 4; c++) begin pos[4+c] <= pos[c]; pos[8+c] <= pos[c]; end
          if (kind == 2'd1) for (int c = 0; c < 4; c++) pos[8+c] <= pos[4+c];
          gd_q <= guard;
          ofin <= 1'b1; o_kind <= kind;
          if (kind == 2'd0) begin                  // points: pass or discard
            if (pt_in) for (int i = 0; i < 3; i++) ov[i] <= {idw(2'd0), pos[3], pos[2], pos[1], pos[0]};
            o_empty <= !pt_in; if (!pt_in) o_kind <= 2'd2;
            st <= C_OUT;
          end else if (kind == 2'd1 ? (w_ok[1:0] == 2'b11 && n_ok[1:0] == 2'b11 && f_ok[1:0] == 2'b11 && xy_ok[1:0] == 2'b11 && vp_ok)
                                    : triv) begin
            for (int i = 0; i < 3; i++)
              ov[i] <= {idw((kind == 2'd1 && i == 2) ? 2'd1 : 2'(i)),
                        pos[4*((kind == 2'd1 && i == 2) ? 1 : i)+3], pos[4*((kind == 2'd1 && i == 2) ? 1 : i)+2],
                        pos[4*((kind == 2'd1 && i == 2) ? 1 : i)+1], pos[4*((kind == 2'd1 && i == 2) ? 1 : i)]};
            st <= C_OUT;
          end else begin
            rw <= '0; st <= C_LOAD;
          end
        end
        C_LOAD: begin
          rw <= rw + 1'b1;
          if (rw == ((kind == 2'd1) ? 4'd1 : 4'd2)) begin pl <= 3'd0; pfirst <= 1'b1; st <= C_CMD; end
        end
        C_CMD: if (cmd_ready) begin pfirst <= 1'b0; st <= C_CWAIT; end
        C_CWAIT: if (cp_done) begin
          if (n_out == '0) begin                   // nothing left
            o_empty <= 1'b1; o_kind <= 2'd2; ofin <= 1'b1; st <= C_OUT;
          end else begin
            if (pl_found) begin pl <= pl_next; st <= C_CMD; end
            else begin fi <= IW'(1); fv <= '0; st <= C_EMIT; end
          end
        end
        C_EMIT: st <= C_EWT;                       // rd_idx presented, data next cycle
        C_EWT: begin
          ov[fv] <= rd_data;
          if (fv == 2'd2 || (kind == 2'd1 && fv == 2'd1)) begin
            if (kind == 2'd1) ov[2] <= rd_data;
            ofin <= (kind == 2'd1) || (fi + 2'd2 >= n_out);
            st <= C_OUT;
          end else begin fv <= fv + 1'b1; st <= C_EMIT; end
        end
        C_OUT: begin
          if (!cl_valid) begin
            cl_valid <= 1'b1;
            cl_last  <= plast && ofin;
          end else if (cl_ready) begin
            cl_valid <= 1'b0;
            if (ofin || o_raw || o_empty) st <= C_IDLE;
            else begin fi <= fi + 1'b1; fv <= '0; st <= C_EMIT; end
          end
        end
        default: st <= C_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- cl_tri
  always_comb begin
    cl_tri = '0;
    for (int i = 0; i < 3; i++) begin
      cl_tri[128*i +: 128] = o_empty ? {ad_rx_pkg::FP_ONEV, 96'd0} : ov[i][127:0];
      cl_tri[384 + 96*i +: 96] = o_empty ? 96'd0 : ov[i][223:128];
    end
    cl_tri[672 +: 24] = pv;
    cl_tri[696 +: 3]  = ofin ? pfree : 3'b000;   // only the last output frees
    cl_tri[699]       = o_raw;
    cl_tri[700 +: 2]  = o_raw ? 2'd2 : o_kind;
  end

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  always @(posedge clk) if (f_vld && rst_n) begin
    if (pt_rd) assert (!pt_busy);                 // never reads while frag owns the port
    if (cl_valid && cl_tri[698:696] != 0) assert (ofin);
    if (cl_valid && cl_last) assert (plast && ofin);
    if (cl_valid) assert (cl_tri[701:700] != 2'd3);
  end
  always @(posedge clk) if (f_vld && rst_n && $past(rst_n) && $past(cl_valid && !cl_ready))
    assert (cl_valid && cl_tri == $past(cl_tri) && cl_last == $past(cl_last));
`endif
endmodule
