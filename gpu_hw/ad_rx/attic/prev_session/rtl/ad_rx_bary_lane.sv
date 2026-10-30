// ============================================================================
// ad_rx_bary_lane -- the arithmetic of one fragment lane (submodule of
// ad_rx_bary, one instance per quad lane).
//
// Barycentric pass (i_start, i_dz = 0), at fp32 position (i, j) relative to
// the bbox origin's pixel centre:
//   P = (A i + B j) + C          for z, 1/w, b0/w, b1/w   (4 x 4 cycles)
//   r = 1 / P_1/w                                          (fdiv, 28 cycles)
//   b0 = P_b0 r,  b1 = P_b1 r,  b2 = (1 - b0) - b1         (4 cycles)
// Depth-slope pass (i_dz = 1):  ds = Az i + Bz j            (3 cycles)
// One fadd, one fmul, one fdiv; RX arithmetic (RNE, denormals flushed).
// ============================================================================
module ad_rx_bary_lane (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          i_start,
  input  logic          i_dz,
  input  logic [383:0]  i_pl,       // (z, 1/w, b0/w, b1/w) x (A, B, C)
  input  logic [31:0]   i_i,
  input  logic [31:0]   i_j,
  output logic          busy,
  output logic          o_done,
  output logic [31:0]   o_z,
  output logic [31:0]   o_b0,
  output logic [31:0]   o_b1,
  output logic [31:0]   o_b2,
  output logic [31:0]   o_ds
);
  typedef enum logic [2:0] {L_IDLE, L_PL, L_DIV, L_BC, L_DZ} lst_e;
  lst_e st;

  logic [1:0]  pp;              // plane
  logic [1:0]  ph;              // phase
  logic [31:0] m1, m2, pw, pb0, pb1, rr, t0;
  logic [31:0] fa, fb, fm, ma, mb, fr;
  logic        fsub;
  logic        dv_go, dv_busy, dv_done;
  logic [31:0] dv_r;
  logic        started;

  ad_rx_fadd u_add (.a(fa), .b(fb), .sub(fsub), .r(fr));
  ad_rx_fmul u_mul (.a(ma), .b(mb), .r(fm));
  ad_rx_fdiv u_div (.clk(clk), .rst_n(rst_n), .i_start(dv_go), .i_a(ad_rx_pkg::FP_ONE),
                    .i_b(pw), .busy(dv_busy), .o_done(dv_done), .o_r(dv_r));

  logic [31:0] pa, pb, pc;
  always_comb begin
    pa = i_pl[96*pp      +: 32];
    pb = i_pl[96*pp + 32 +: 32];
    pc = i_pl[96*pp + 64 +: 32];
  end

  always_comb begin
    fa = '0; fb = '0; fsub = 1'b0; ma = '0; mb = '0;
    case (st)
      L_PL, L_DZ: case (ph)
        2'd0: begin ma = pa; mb = i_i; end
        2'd1: begin ma = pb; mb = i_j; end
        2'd2: begin fa = m1; fb = m2; end
        default: begin fa = t0; fb = pc; end
      endcase
      L_BC: case (ph)
        2'd0: begin ma = pb0; mb = rr; end
        2'd1: begin ma = pb1; mb = rr; end
        2'd2: begin fa = ad_rx_pkg::FP_ONE; fb = o_b0; fsub = 1'b1; end
        default: begin fa = t0; fb = o_b1; fsub = 1'b1; end
      endcase
      default: ;
    endcase
  end

  assign busy  = (st != L_IDLE);
  assign dv_go = (st == L_DIV) && !started;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= L_IDLE; pp <= '0; ph <= '0; started <= 1'b0; o_done <= 1'b0;
      m1 <= '0; m2 <= '0; pw <= '0; pb0 <= '0; pb1 <= '0; rr <= '0; t0 <= '0;
      o_z <= '0; o_b0 <= '0; o_b1 <= '0; o_b2 <= '0; o_ds <= '0;
    end else begin
      o_done <= 1'b0;
      case (st)
        L_IDLE: begin
          pp <= '0; ph <= '0;
          if (i_dz) st <= L_DZ;
          else if (i_start) st <= L_PL;
        end
        L_PL: begin
          ph <= ph + 2'd1;
          case (ph)
            2'd0: m1 <= fm;
            2'd1: m2 <= fm;
            2'd2: t0 <= fr;
            default: begin
              case (pp)
                2'd0: o_z <= fr;
                2'd1: pw  <= fr;
                2'd2: pb0 <= fr;
                default: pb1 <= fr;
              endcase
              pp <= pp + 2'd1;
              if (pp == 2'd3) begin st <= L_DIV; started <= 1'b0; end
            end
          endcase
        end
        L_DIV: begin
          if (dv_go) started <= 1'b1;
          if (dv_done) begin rr <= dv_r; ph <= '0; st <= L_BC; end
        end
        L_BC: begin
          ph <= ph + 2'd1;
          case (ph)
            2'd0: o_b0 <= fm;
            2'd1: o_b1 <= fm;
            2'd2: t0   <= fr;
            default: begin o_b2 <= fr; o_done <= 1'b1; st <= L_IDLE; end
          endcase
        end
        L_DZ: begin
          ph <= ph + 2'd1;
          case (ph)
            2'd0: m1 <= fm;
            2'd1: m2 <= fm;
            default: begin
            `ifdef MUT_DZ_SIGN
              o_ds <= fr ^ 32'h8000_0000;
            `else
              o_ds <= fr;
            `endif
              o_done <= 1'b1; st <= L_IDLE;
            end
          endcase
        end
        default: st <= L_IDLE;
      endcase
    end
  end

`ifdef FORMAL
  logic f_past = 1'b0;
  always_ff @(posedge clk) f_past <= 1'b1;
  initial assume (!rst_n);
  logic [6:0] f_age;
  always_ff @(posedge clk)
    if (!rst_n || st == L_IDLE) f_age <= '0;
    else if (f_age != '1) f_age <= f_age + 7'd1;
  always_ff @(posedge clk) if (f_past && rst_n && $past(rst_n)) begin
    assert (!(o_done && $past(o_done)));
    if (o_done) assert (st == L_IDLE);
  `ifdef FPV_BMC
    assert (f_age <= 7'd50);                       // 16 + 30 + 4 at most
  `endif
    if (st == L_DZ) assert (ph <= 2'd2);
    if (st == L_DIV && started) assert (dv_busy || dv_done);
    if (st == L_DIV && !started) assert (!dv_busy && !dv_done);
    if (st != L_DIV) assert (!dv_busy);
    if (st == L_PL) assert (f_age == {3'd0, pp, ph});
  end
  always_ff @(posedge clk) if (rst_n) begin cover (st == L_DIV && started); cover (o_done && $past(st) == L_DZ); end
`endif
endmodule
