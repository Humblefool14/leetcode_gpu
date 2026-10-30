// ============================================================================
// ad_rx_edge -- the integer part of triangle setup.
//
// Reads the window x, y of the vertices from ad_rx_setup's fp registers,
// snaps them to 15.8 (ad_rx_f2fix), builds the triangle the scan walks
// (a triangle; a line's or a point's sub-triangle), its edges with the
// top-left rule, bbox (all corners of the primitive) n scissor n [0, RT)
// n the viewport's rectangle, facing and culling, and writes the plane
// deltas DX1 DY1 DX2 DY2 DF OX OY (pixels, fp32) to registers 40-46.
//
// Edge i runs P_i -> P_j (j = i+1 mod 3):  A = P_i.y - P_j.y,  B = P_j.x - P_i.x,
// E(p) = A (p.x - P_i.x) + B (p.y - P_i.y) - bias;  inside <=> E >= 0 once the
// corners are ordered so that D = (P1-P0) x (P2-P0) > 0.  Top-left edges
// (A > 0, or A = 0 and B > 0) have bias 0, the others 1.
// Facing (Vulkan, y down): front = (D_original < 0) ^ CULL[2].
// Lines: x-major when |dx| >= |dy|; corners a -+ o, b -+ o with o the half
// width along the minor axis (LINE_WIDTH / 2, register 126); sub 0 (a-, b-, b+),
// sub 1 (a-, b+, a+).  Points: the square p +- h (POINT_SIZE / 2, register 127);
// sub 0 (p--, p+-, p++), sub 1 (p--, p++, p-+).
//
// Fixes vs atg_rx_edge: wide lines and point sizes (LINE_WIDTH / POINT_SIZE
// were stored by atg_rx_setup but the edge spec used 1 px only); the delta DF
// is rounded (RNE) rather than assumed exact; widths from ad_rx_pkg.
// One signed 25 x 25 multiplier, used 10 times per call.
// ============================================================================
module ad_rx_edge (
  input  logic                               clk,
  input  logic                               rst_n,
  input  logic                               start,
  input  logic [3:0]                         mode,      // [1:0] kind, [2] sub, [3] raw
  input  logic [31:0]                        smin,      // {y, x}
  input  logic [31:0]                        smax,
  input  logic [31:0]                        rts,
  input  logic [2:0]                         cull,
  input  logic                               vprect,
  output logic [6:0]                         r_ra,
  input  logic [31:0]                        r_rd,      // the cycle after r_ra
  output logic                               r_we,
  output logic [6:0]                         r_wa,
  output logic [31:0]                        r_wd,
  output logic                               done,
  output logic [3*ad_rx_pkg::EDG_PCK-1:0]    edges,
  output logic [ad_rx_pkg::BBX_WID-1:0]      bbox,
  output logic                               front,
  output logic                               empty
);
  localparam int QW = ad_rx_pkg::FIX_WID;          // 24
  localparam int EW = ad_rx_pkg::EDG_ACC;          // 48
  localparam int AW = ad_rx_pkg::EDG_COF;          // 24
  localparam int CW = ad_rx_pkg::CRD_WID;          // 16
  localparam int FR = ad_rx_pkg::FIX_FRC;          // 8
  localparam int PW = ad_rx_pkg::EDG_PCK;

  typedef enum logic [3:0] {E_IDLE, E_READ, E_CORN, E_MUL, E_EDGE, E_CONV, E_DONE} st_t;
  st_t st;

  // ---------------------------------------------------------------- reads
  // order: v0x v0y v1x v1y v2x v2y rx0 rx1 ry0 ry1 hw_line hw_point
  logic [3:0] ri;
  logic       rv;
  function automatic logic [6:0] raddr(input logic [3:0] i);
    case (i)
      4'd0: raddr = 7'd31;  4'd1: raddr = 7'd32;  4'd2: raddr = 7'd34;  4'd3: raddr = 7'd35;
      4'd4: raddr = 7'd37;  4'd5: raddr = 7'd38;  4'd6: raddr = 7'd76;  4'd7: raddr = 7'd77;
      4'd8: raddr = 7'd78;  4'd9: raddr = 7'd79;  4'd10: raddr = 7'd126; default: raddr = 7'd127;
    endcase
  endfunction
  assign r_ra = raddr(ri);

  logic [QW-1:0] snap;
  ad_rx_f2fix u_snap (.f(r_rd), .q(snap));
  logic signed [QW-1:0] sv [12];                   // snapped values

  // ---------------------------------------------------------------- corners
  logic [1:0] kind;
  logic       sub, raw;
  logic signed [QW+1:0] px [3], py [3];           // walked triangle (2 bits headroom)
  logic signed [QW+1:0] qx [3], qy [3];           // plane triangle
  logic signed [QW+1:0] lox, hix, loy, hiy;        // primitive's extent (all corners)
  logic       xmaj, zlen;

  // ---------------------------------------------------------------- multiplier
  logic signed [QW+1:0] ma, mb;
  logic signed [2*QW+3:0] mp;
  assign mp = ma * mb;
  logic [3:0] mi;                                  // product index 0..9
  logic signed [2*QW+3:0] pr [10];

  // ---------------------------------------------------------------- results
  logic signed [2*QW+3:0] dT, dQ;                  // cross products
  logic signed [AW-1:0]   ea [3], eb [3];
  logic        [CW-1:0]   bx0, by0, bx1, by1;
  logic        [2:0]      ci;                       // conversion index
  logic signed [QW+1:0]   cx, cy;                   // bbox origin's pixel centre (15.8)

  // the delta being converted (fixed point, 8 fraction bits)
  logic signed [2*QW+3:0] cvv;
  logic [31:0] cvf_s, cvf_d;
  ad_rx_i2f #(.W(QW+2),     .F(FR))   u_i2f_s (.v(cvv[QW+1:0]), .f(cvf_s));
  ad_rx_i2f #(.W(2*QW+4),   .F(2*FR)) u_i2f_d (.v(cvv),         .f(cvf_d));
  always_comb begin
    case (ci)
      3'd0: cvv = (2*QW+4)'(qx[1] - qx[0]);
      3'd1: cvv = (2*QW+4)'(qy[1] - qy[0]);
      3'd2: cvv = (2*QW+4)'(qx[2] - qx[0]);
      3'd3: cvv = (2*QW+4)'(qy[2] - qy[0]);
      3'd4: cvv = dQ;
      3'd5: cvv = (2*QW+4)'(cx - qx[0]);
      default: cvv = (2*QW+4)'(cy - qy[0]);
    endcase
  end
  assign r_we = (st == E_CONV);
  assign r_wa = 7'd40 + {4'd0, ci};
  assign r_wd = (ci == 3'd4) ? cvf_d : cvf_s;

  // ---------------------------------------------------------------- corner build (combinational)
  logic signed [QW+1:0] ax_, ay_, bx_, by_, hl, hp, ddx, ddy, adx, ady;
  assign ax_ = (QW+2)'(sv[0]); assign ay_ = (QW+2)'(sv[1]);
  assign bx_ = (QW+2)'(sv[2]); assign by_ = (QW+2)'(sv[3]);
  assign hl  = (QW+2)'(sv[10]);
  assign hp  = (QW+2)'(sv[11]);
  assign ddx = bx_ - ax_;
  assign ddy = by_ - ay_;
  assign adx = ddx[QW+1] ? -ddx : ddx;
  assign ady = ddy[QW+1] ? -ddy : ddy;

  localparam logic signed [QW+1:0] ONE = (QW+2)'(1 << FR);   // one pixel in subpixels
  // a line's half-width offset o and its one-pixel step e, both along the minor axis
  logic signed [QW+1:0] ox, oy, ex, ey;
  assign ox = (adx >= ady) ? '0 : hl;
  assign oy = (adx >= ady) ? hl : '0;
  assign ex = (adx >= ady) ? '0 : ONE;
  assign ey = (adx >= ady) ? ONE : '0;

  // E for edge e at the bbox origin's centre: pr[2+2e] = A (cx - Pi.x), pr[3+2e] = B (cy - Pi.y)
  function automatic logic signed [EW-1:0] bias_e(input logic signed [AW-1:0] a, input logic signed [AW-1:0] b);
    bias_e = ((a > 0) || (a == 0 && b > 0)) ? '0 : EW'(1);
  endfunction

  // bbox intersections
  logic [CW:0] rx0, rx1, ry0, ry1;                 // candidate, 17 bits signed-ish
  function automatic logic [CW-1:0] clamp_lo(input logic signed [QW+1:0] v);   // floor(v / 256), >= 0
    logic signed [QW+1:0] p;
    p = v >>> FR;
    clamp_lo = (p < 0) ? '0 : (p > 32767) ? 16'd32767 : CW'(p);
  endfunction
  function automatic logic [CW-1:0] clamp_hi(input logic signed [QW+1:0] v);   // floor(v / 256) + 1
    logic signed [QW+1:0] p;
    p = (v >>> FR) + 1;
    clamp_hi = (p < 0) ? '0 : (p > 32767) ? 16'd32767 : CW'(p);
  endfunction
  function automatic logic [CW-1:0] umax(input logic [CW-1:0] a, input logic [CW-1:0] b);
    umax = (a > b) ? a : b;
  endfunction
  function automatic logic [CW-1:0] umin(input logic [CW-1:0] a, input logic [CW-1:0] b);
    umin = (a < b) ? a : b;
  endfunction

  logic use_sc, use_rect;
  assign use_sc   = (smax != 32'd0);
  assign use_rect = vprect && !raw;
  logic [CW-1:0] fx0, fy0, fx1, fy1;
  always_comb begin
    fx0 = clamp_lo(lox);  fy0 = clamp_lo(loy);
    fx1 = clamp_hi(hix);  fy1 = clamp_hi(hiy);
    if (use_sc) begin
      fx0 = umax(fx0, smin[15:0]);  fy0 = umax(fy0, smin[31:16]);
      fx1 = umin(fx1, smax[15:0]);  fy1 = umin(fy1, smax[31:16]);
    end
    fx1 = umin(fx1, rts[15:0]);     fy1 = umin(fy1, rts[31:16]);
    if (use_rect) begin
      fx0 = umax(fx0, clamp_lo((QW+2)'(sv[6])));  fx1 = umin(fx1, clamp_lo((QW+2)'(sv[7])));
      fy0 = umax(fy0, clamp_lo((QW+2)'(sv[8])));  fy1 = umin(fy1, clamp_lo((QW+2)'(sv[9])));
    end
  end

  logic culled, nobox;
  logic dneg;                                      // original winding D < 0
  assign nobox = (bx0 >= bx1) || (by0 >= by1);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= E_IDLE; done <= 1'b0; ri <= '0; rv <= 1'b0; mi <= '0; ci <= '0;
      kind <= '0; sub <= 1'b0; raw <= 1'b0; xmaj <= 1'b0; zlen <= 1'b0;
      edges <= '0; bbox <= '0; front <= 1'b1; empty <= 1'b1; culled <= 1'b0; dneg <= 1'b0;
      bx0 <= '0; by0 <= '0; bx1 <= '0; by1 <= '0; cx <= '0; cy <= '0; dT <= '0; dQ <= '0;
      ma <= '0; mb <= '0;
      for (int i = 0; i < 3; i++) begin
        px[i] <= '0; py[i] <= '0; qx[i] <= '0; qy[i] <= '0; ea[i] <= '0; eb[i] <= '0;
      end
    end else begin
      done <= 1'b0;
      case (st)
        E_IDLE: if (start) begin
          kind <= mode[1:0]; sub <= mode[2]; raw <= mode[3];
          ri <= '0; rv <= 1'b0; st <= E_READ;
        end
        E_READ: begin                              // 12 reads, one per cycle, data next cycle
          rv <= 1'b1;
          if (rv) sv[ri - 1'b1] <= $signed(snap);
          if (ri != 4'd12) ri <= ri + 1'b1;
          if (rv && ri == 4'd12) st <= E_CORN;
        end
        E_CORN: begin
          // walked and plane triangles, extent
          xmaj <= (adx >= ady);
          case (kind)
            2'd1: begin                            // line a = v0, b = v1
              zlen <= (adx >= ady) ? (adx == 0) : (ady == 0);
              // a- = a - o, a+ = a + o, b- = b - o, b+ = b + o
              px[0] <= ax_ - ox;                           py[0] <= ay_ - oy;
              px[1] <= sub ? bx_ + ox : bx_ - ox;          py[1] <= sub ? by_ + oy : by_ - oy;
              px[2] <= sub ? ax_ + ox : bx_ + ox;          py[2] <= sub ? ay_ + oy : by_ + oy;
              qx[0] <= ax_; qy[0] <= ay_; qx[1] <= bx_; qy[1] <= by_;
              qx[2] <= ax_ + ex; qy[2] <= ay_ + ey;
              lox <= ((ax_ < bx_) ? ax_ : bx_) - ox;  hix <= ((ax_ > bx_) ? ax_ : bx_) + ox;
              loy <= ((ay_ < by_) ? ay_ : by_) - oy;  hiy <= ((ay_ > by_) ? ay_ : by_) + oy;
            end
            2'd0: begin                            // point p = v0
              zlen <= 1'b0;
              px[0] <= ax_ - hp;                   py[0] <= ay_ - hp;
              px[1] <= sub ? ax_ + hp : ax_ + hp;  py[1] <= sub ? ay_ + hp : ay_ - hp;
              px[2] <= sub ? ax_ - hp : ax_ + hp;  py[2] <= ay_ + hp;
              qx[0] <= ax_; qy[0] <= ay_; qx[1] <= ax_ + ONE; qy[1] <= ay_;
              qx[2] <= ax_; qy[2] <= ay_ + ONE;
              lox <= ax_ - hp; hix <= ax_ + hp; loy <= ay_ - hp; hiy <= ay_ + hp;
            end
            default: begin                         // triangle
              zlen <= 1'b0;
              for (int i = 0; i < 3; i++) begin
                px[i] <= (QW+2)'(sv[2*i]); py[i] <= (QW+2)'(sv[2*i+1]);
                qx[i] <= (QW+2)'(sv[2*i]); qy[i] <= (QW+2)'(sv[2*i+1]);
              end
              lox <= ((ax_ < bx_) ? ((ax_ < (QW+2)'(sv[4])) ? ax_ : (QW+2)'(sv[4])) : ((bx_ < (QW+2)'(sv[4])) ? bx_ : (QW+2)'(sv[4])));
              hix <= ((ax_ > bx_) ? ((ax_ > (QW+2)'(sv[4])) ? ax_ : (QW+2)'(sv[4])) : ((bx_ > (QW+2)'(sv[4])) ? bx_ : (QW+2)'(sv[4])));
              loy <= ((ay_ < by_) ? ((ay_ < (QW+2)'(sv[5])) ? ay_ : (QW+2)'(sv[5])) : ((by_ < (QW+2)'(sv[5])) ? by_ : (QW+2)'(sv[5])));
              hiy <= ((ay_ > by_) ? ((ay_ > (QW+2)'(sv[5])) ? ay_ : (QW+2)'(sv[5])) : ((by_ > (QW+2)'(sv[5])) ? by_ : (QW+2)'(sv[5])));
            end
          endcase
          mi <= '0; st <= E_MUL;
        end
        E_MUL: begin
          // products: 0,1 -> D_T; 2..7 -> E terms (after ordering); 8,9 -> D_Q
          if (mi == 4'd0) begin
            bx0 <= fx0; by0 <= fy0; bx1 <= fx1; by1 <= fy1;
            cx <= ((QW+2)'(fx0) <<< FR) + (QW+2)'(1 << (FR-1));
            cy <= ((QW+2)'(fy0) <<< FR) + (QW+2)'(1 << (FR-1));
          end
          if (mi != 4'd0) pr[mi - 1'b1] <= mp;
          case (mi)
            4'd0: begin ma <= px[1] - px[0]; mb <= py[2] - py[0]; end
            4'd1: begin ma <= px[2] - px[0]; mb <= py[1] - py[0]; end
            4'd2: begin                            // order the corners: D > 0
              dT    <= pr[0] - mp;
              dneg  <= (pr[0] - mp) < 0;
              if ((pr[0] - mp) < 0) begin
                px[1] <= px[2]; py[1] <= py[2]; px[2] <= px[1]; py[2] <= py[1];
              end
              ma <= qx[1] - qx[0]; mb <= qy[2] - qy[0];
            end
            4'd3: begin ma <= qx[2] - qx[0]; mb <= qy[1] - qy[0]; end
            4'd4: begin
              dQ <= pr[2] - mp;
              // edge coefficients
              for (int e = 0; e < 3; e++) begin
                ea[e] <= AW'(py[e] - py[(e + 1) % 3]);
                eb[e] <= AW'(px[(e + 1) % 3] - px[e]);
              end
              ma <= py[0] - py[1]; mb <= cx - px[0];
            end
            4'd5: begin ma <= px[1] - px[0]; mb <= cy - py[0]; end
            4'd6: begin ma <= py[1] - py[2]; mb <= cx - px[1]; end
            4'd7: begin ma <= px[2] - px[1]; mb <= cy - py[1]; end
            4'd8: begin ma <= py[2] - py[0]; mb <= cx - px[2]; end
            4'd9: begin ma <= px[0] - px[2]; mb <= cy - py[2]; end
            default: ;
          endcase
          if (mi == 4'd10) st <= E_EDGE;
          mi <= mi + 1'b1;
        end
        E_EDGE: begin
          // pr[4..9] hold A(cx-Pi.x), B(cy-Pi.y) for e = 0..2 (pr index = mi - 1)
          culled <= (kind == 2'd2) && !raw &&
                    ((cull[0] && (dneg ^ cull[2])) || (cull[1] && !(dneg ^ cull[2])));
          for (int e = 0; e < 3; e++)
            edges[PW*e +: PW] <= {EW'(pr[4 + 2*e] + pr[5 + 2*e]) - bias_e(ea[e], eb[e]), eb[e], ea[e]};
          ci <= '0; st <= E_CONV;
        end
        E_CONV: begin                              // r_we: 7 deltas to registers 40-46
          if (ci == 3'd6) st <= E_DONE;
          ci <= ci + 1'b1;
        end
        E_DONE: begin
          if (dT == 0 || zlen || culled || nobox) begin
            empty <= 1'b1; edges <= '0; bbox <= '0;
          end else begin
            empty <= 1'b0; bbox <= {by1, bx1, by0, bx0};
          end
          front <= (kind == 2'd2) ? (dneg ^ cull[2]) : 1'b1;
          done <= 1'b1; st <= E_IDLE;
        end
        default: st <= E_IDLE;
      endcase
    end
  end

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  logic [6:0] f_age;
  always @(posedge clk) if (!rst_n || (start && st == E_IDLE)) f_age <= 0; else if (st != E_IDLE) f_age <= f_age + 1;
  always @(posedge clk) if (f_vld && rst_n) begin
    if (st != E_IDLE) assert (f_age < 7'd40);                    // bounded latency
    if (done && !empty) begin
      assert (bbox[15:0] < bbox[47:32] && bbox[31:16] < bbox[63:48]);   // non-empty box
      assert (bbox[47:32] <= rts[15:0] && bbox[63:48] <= rts[31:16]);   // inside the RT
      if (smax != 0) assert (bbox[15:0] >= smin[15:0] && bbox[47:32] <= smax[15:0]);
    end
    if (done && empty) assert (bbox == '0 && edges == '0);
    if (done && kind != 2'd2) assert (front);
    if (r_we) assert (r_wa >= 7'd40 && r_wa <= 7'd46);
  end
`endif
endmodule
