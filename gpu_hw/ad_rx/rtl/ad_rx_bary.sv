// ============================================================================
// ad_rx_bary -- lane arithmetic of the fragment warps, 4 lanes in parallel.
//
// Pass (i_start): for each lane l at pixel (x, y) = quad + (l & 1, l >> 1) and
// location i_osel[3l +: 3] (0 the centre, 1 + s sample s):
//   i = x - bx0 + dx, j = y - by0 + dy   (8 i, 8 j integers -> fp32, exact)
//   P = (A i + B j) + C  for the planes z, 1/w, b0/w, b1/w      PL: 12 cycles
//   r = 1 / (1/w)                                                DIV: 28 cycles
//   b0 = (b0/w) r, b1 = (b1/w) r, b2 = (1 - b0) - b1             BC: 3 cycles
// Depth slopes (i_dz): d_s = Az dx_s + Bz dy_s for the 4 samples  DZ: 2 cycles
// Sample offsets from the centre in eighths (Vulkan standard 4x locations):
//   s0 (-1, -3), s1 (3, -1), s2 (-3, 1), s3 (1, 3).
// RX fp rules (RNE, denormals flushed).  Per lane: one fadd, one fmul, one fdiv.
//
// Fixes vs atg_rx_bary: children named consistently (atg named am_fp_*); the
// pass is 12 + 28 + 3 + 2 = ~45 cycles (atg's 20/28/13 split overlapped its
// adds less); d_s uses the same lane units (no extra multipliers).
// ============================================================================
module ad_rx_bary (
  input  logic                               clk,
  input  logic                               rst_n,
  input  logic                               i_start,   // pulse while idle: the barycentric pass
  input  logic                               i_dz,      // pulse while idle: the depth slopes
  input  logic [ad_rx_pkg::PLN_ALL-1:0]      i_pl,      // (z, 1/w, b0/w, b1/w) x (A, B, C)
  input  logic [ad_rx_pkg::CRD_WID-1:0]      i_qx,
  input  logic [ad_rx_pkg::CRD_WID-1:0]      i_qy,
  input  logic [ad_rx_pkg::CRD_WID-1:0]      i_bx0,
  input  logic [ad_rx_pkg::CRD_WID-1:0]      i_by0,
  input  logic [4*ad_rx_pkg::SMP_OFS-1:0]    i_osel,    // lane l location at 3l
  output logic                               busy,
  output logic                               o_done,
  output logic [127:0]                       o_b0,
  output logic [127:0]                       o_b1,
  output logic [127:0]                       o_b2,
  output logic [127:0]                       o_z,
  output logic [127:0]                       o_ds
);
  localparam int CW = ad_rx_pkg::CRD_WID;

  typedef enum logic [2:0] {B_IDLE, B_PL, B_DIV, B_DWT, B_BC, B_DZ, B_FIN} st_t;
  st_t st;
  logic [1:0] pl;                                  // plane 0..3
  logic [1:0] cy;                                  // cycle within the step

  function automatic logic signed [3:0] sdx(input logic [2:0] o);
    case (o) 3'd1: sdx = -4'sd1; 3'd2: sdx = 4'sd3; 3'd3: sdx = -4'sd3; 3'd4: sdx = 4'sd1; default: sdx = 4'sd0; endcase
  endfunction
  function automatic logic signed [3:0] sdy(input logic [2:0] o);
    case (o) 3'd1: sdy = -4'sd3; 3'd2: sdy = -4'sd1; 3'd3: sdy = 4'sd1; 3'd4: sdy = 4'sd3; default: sdy = 4'sd0; endcase
  endfunction
  // the same offsets as fp32 (pixels) for the slopes: -1/8, 3/8, -3/8, 1/8 ...
  function automatic logic [31:0] e8(input logic signed [3:0] v);
    case (v)
      -4'sd3: e8 = 32'hBEC0_0000;  -4'sd1: e8 = 32'hBE00_0000;
       4'sd1: e8 = 32'h3E00_0000;   4'sd3: e8 = 32'h3EC0_0000;
      default: e8 = 32'h0;
    endcase
  endfunction

  logic [31:0] pa [4], pb [4], pc [4];             // plane A, B, C
  for (genvar p = 0; p < 4; p++) begin : g_pl
    assign pa[p] = i_pl[96*p +: 32];
    assign pb[p] = i_pl[96*p + 32 +: 32];
    assign pc[p] = i_pl[96*p + 64 +: 32];
  end

  logic fd_go;
  logic [3:0] fd_done;
  for (genvar l = 0; l < 4; l++) begin : g_ln
    // lane coordinates in eighths
    logic signed [20:0] i8, j8;
    logic [2:0] os;
    assign os = i_osel[3*l +: 3];
    assign i8 = ($signed({5'd0, i_qx}) + 21'(l & 1) - $signed({5'd0, i_bx0})) * 8 + 21'(sdx(os));
    assign j8 = ($signed({5'd0, i_qy}) + 21'(l >> 1) - $signed({5'd0, i_by0})) * 8 + 21'(sdy(os));
    logic [31:0] fi, fj;
    ad_rx_i2f #(.W(21), .F(3)) u_i (.v(i8), .f(fi));
    ad_rx_i2f #(.W(21), .F(3)) u_j (.v(j8), .f(fj));

    logic [31:0] t1;                               // partial sum
    logic [31:0] pv [4];                           // plane values z, 1/w, b0/w, b1/w
    logic [31:0] rr, b0, b1, b2, ds;
    logic [31:0] ma, mb, mr, aa, ab, ar, dr;
    logic        asub, dbusy;
    ad_rx_fmul u_fmul (.i_a(ma), .i_b(mb), .o_r(mr));
    ad_rx_fadd u_fadd (.i_a(aa), .i_b(ab), .i_sub(asub), .o_r(ar));
    ad_rx_fdiv u_fdiv (.clk, .rst_n, .i_start(fd_go), .i_a(ad_rx_pkg::FP_ONEV), .i_b(pv[1]),
                       .busy(dbusy), .o_done(fd_done[l]), .o_r(dr));

    always_comb begin
      ma = '0; mb = '0; aa = '0; ab = '0; asub = 1'b0;
      case (st)
        B_PL: case (cy)
          2'd0: begin ma = pa[pl]; mb = fi; end
          2'd1: begin ma = pb[pl]; mb = fj; aa = t1; ab = mr; end
          default: begin aa = t1; ab = pc[pl]; end
        endcase
        B_BC: case (cy)
          2'd0: begin ma = pv[2]; mb = rr; end
          2'd1: begin ma = pv[3]; mb = rr; aa = ad_rx_pkg::FP_ONEV; ab = b0; asub = 1'b1; end
          default: begin aa = t1; ab = b1; asub = 1'b1; end
        endcase
        B_DZ: case (cy)                            // lane l computes sample l's slope
          2'd0: begin ma = pa[0]; mb = e8(sdx(3'(l + 1))); end
          default: begin ma = pb[0]; mb = e8(sdy(3'(l + 1))); aa = t1; ab = mr; end
        endcase
        default: ;
      endcase
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        t1 <= '0; rr <= '0; b0 <= '0; b1 <= '0; b2 <= '0; ds <= '0;
        for (int p = 0; p < 4; p++) pv[p] <= '0;
      end else begin
        case (st)
          B_PL: case (cy)
            2'd0: t1 <= mr;
            2'd1: t1 <= ar;
            default: pv[pl] <= ar;
          endcase
          B_DWT: if (fd_done[l]) rr <= dr;
          B_BC: case (cy)
            2'd0: b0 <= mr;
            2'd1: begin b1 <= mr; t1 <= ar; end
            default: b2 <= ar;
          endcase
`ifdef MUT_DZ_SIGN
          B_DZ: if (cy == 2'd0) t1 <= mr; else ds <= ar ^ 32'h8000_0000;
`else
          B_DZ: if (cy == 2'd0) t1 <= mr; else ds <= ar;
`endif
          default: ;
        endcase
      end
    end
    assign o_b0[32*l +: 32] = b0;
    assign o_b1[32*l +: 32] = b1;
    assign o_b2[32*l +: 32] = b2;
    assign o_z [32*l +: 32] = pv[0];
    assign o_ds[32*l +: 32] = ds;
  end

  assign fd_go = (st == B_DIV);
  // a special-case division (1/w = 0, inf, NaN) ends early: wait for all four
  logic [3:0] dn;
  always_ff @(posedge clk) if (!rst_n || st != B_DWT) dn <= '0; else dn <= dn | fd_done;
  assign busy  = (st != B_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= B_IDLE; pl <= '0; cy <= '0; o_done <= 1'b0;
    end else begin
      o_done <= 1'b0;
      case (st)
        B_IDLE: begin
          cy <= '0; pl <= '0;
          if (i_start) st <= B_PL;
          else if (i_dz) st <= B_DZ;
        end
        B_PL: begin
          if (cy == 2'd2) begin
            cy <= '0;
            if (pl == 2'd3) st <= B_DIV;
            pl <= pl + 1'b1;
          end else cy <= cy + 1'b1;
        end
        B_DIV: st <= B_DWT;                        // all four dividers start together
        B_DWT: if ((dn | fd_done) == 4'b1111) begin cy <= '0; st <= B_BC; end
        B_BC:  begin if (cy == 2'd2) st <= B_FIN; cy <= cy + 1'b1; end
        B_DZ:  begin if (cy == 2'd1) st <= B_FIN; cy <= cy + 1'b1; end
        B_FIN: begin o_done <= 1'b1; st <= B_IDLE; end
        default: st <= B_IDLE;
      endcase
    end
  end

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  logic [6:0] f_age;
  always @(posedge clk) if (!rst_n || st == B_IDLE) f_age <= '0; else f_age <= f_age + 1'b1;
  always @(posedge clk) if (f_vld && rst_n) begin
    if (st != B_IDLE) assert (f_age < 7'd50);               // pass done within 50 cycles
    if (o_done) assert ($past(st) == B_FIN);
    if (st == B_BC) assert (cy <= 2'd2);
  end
`endif
endmodule
