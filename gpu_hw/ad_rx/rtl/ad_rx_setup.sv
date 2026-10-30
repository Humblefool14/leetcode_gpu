// ============================================================================
// ad_rx_setup -- triangle / line / point setup.
//
// A micro-programmed engine (tools/ad_rx_ucode.py -> ad_rx_setup_uc.svh) over
// a 128 x fp32 register file with one fadd, one fmul, one fdiv and the integer
// unit ad_rx_edge (INT).  Per primitive: perspective divide, viewport, the
// viewport's rectangle, INT (snap, edges, bbox, culling, plane deltas), the
// planes z, 1/w, b0/w, b1/w as A x + B y + C at the bbox origin's centre,
// depth bias, and the depth range zmin / zmax for the Hi-Z (new).
// A line or a point runs INT and OUT twice (its two sub-triangles; the same
// planes; the last-use flags and sp_last on the second output only).
//
// Fixes vs atg_rx_setup: decoded state from ad_rx_state; LINE_WIDTH and
// POINT_SIZE are used (registers 126, 127 = width / 2, size / 2); sp_tri
// carries zmin / zmax for the Hi-Z (SPT_WID = 832); the kind is in [766:765]
// everywhere (atg_rx_scan's text still said [767:765] = 0); a 9-bit PC (the
// program is 367 instructions; atg's 8-bit target field could not reach past 255).
// ============================================================================
module ad_rx_setup (
  input  logic                               clk,
  input  logic                               rst_n,
  // decoded state
  input  logic [6*32-1:0]                    i_vp,      // xs ys xo yo zs zo
  input  logic [31:0]                        i_scmin,
  input  logic [31:0]                        i_scmax,
  input  logic [2:0]                         i_cull,
  input  logic [31:0]                        i_rmode,
  input  logic [3*32-1:0]                    i_dbias,
  input  logic [31:0]                        i_lwdth,
  input  logic [31:0]                        i_psize,
  input  logic [31:0]                        i_rtsiz,
  // from clip
  input  logic                               cl_valid,
  output logic                               cl_ready,
  input  logic [ad_rx_pkg::CLT_WID-1:0]      cl_tri,
  input  logic                               cl_last,
  // to scan
  output logic                               sp_valid,
  input  logic                               sp_ready,
  output logic [ad_rx_pkg::SPT_WID-1:0]      sp_tri,
  output logic                               sp_last,
  output logic                               busy
);
`include "ad_rx_setup_uc.svh"

  localparam int PI = ad_rx_pkg::PT_IDXW;

  typedef enum logic [2:0] {U_IDLE, U_LOAD, U_RUN, U_DIV, U_INT, U_OUT} st_t;
  st_t st;

  logic [31:0] rf [128];
  logic [8:0]  pc;
  logic [27:0] ir;
  logic [4:0]  op;
  logic [8:0]  dd;
  logic [6:0]  ra, rb;
  assign ir = ucode(pc);
  assign op = ir[27:23];
  assign dd = ir[22:14];
  assign ra = ir[13:7];
  assign rb = ir[6:0];

  // ---------------------------------------------------------------- primitive
  logic [3*PI-1:0] pte;
  logic [2:0]      lst;
  logic            raw, last_q, fin;
  logic [1:0]      kind;

  // ---------------------------------------------------------------- read-only registers
  logic [31:0] rcst, lhalf, phalf;
  assign rcst  = (i_rmode[5:4] == 2'd1) ? 32'h3780_0000 :     // 2^-16 (D16)
                 (i_rmode[5:4] == 2'd2) ? 32'h3380_0000 : 32'd0;  // 2^-24 (D24)
  // x / 2 exactly (normal x; a denormal or zero half is 0)
  function automatic logic [31:0] half(input logic [31:0] x);
    half = (x[30:23] <= 8'd1) ? 32'd0 : (x[30:23] == 8'hFF) ? x : {x[31], x[30:23] - 8'd1, x[22:0]};
  endfunction
  assign lhalf = half(i_lwdth);
  assign phalf = half(i_psize);

  // read ports (written as always_comb, not a function call, so that every
  // simulator re-evaluates them when rf changes, not only when the address does)
  logic [31:0] ro [8];                             // registers 120-127
  assign ro[0] = i_dbias[0 +: 32];
  assign ro[1] = i_dbias[32 +: 32];
  assign ro[2] = i_dbias[64 +: 32];
  assign ro[3] = ad_rx_pkg::FP_HALF;
  assign ro[4] = ad_rx_pkg::FP_ZERO;
  assign ro[5] = rcst;
  assign ro[6] = lhalf;
  assign ro[7] = phalf;

  logic [31:0] va, vb, e_rdc;
  logic [6:0]  e_ra;
  always_comb begin
    va    = (ra[6:3] == 4'hF)   ? ro[ra[2:0]]   : rf[ra];
    vb    = (rb[6:3] == 4'hF)   ? ro[rb[2:0]]   : rf[rb];
    e_rdc = (e_ra[6:3] == 4'hF) ? ro[e_ra[2:0]] : rf[e_ra];
  end

  // ---------------------------------------------------------------- fp units
  logic [31:0] fa_r, fm_r, fd_r;
  logic        fd_busy, fd_done, fd_go;
  ad_rx_fadd u_fadd (.i_a(va), .i_b(vb), .i_sub(op == 5'd2), .o_r(fa_r));
  ad_rx_fmul u_fmul (.i_a(va), .i_b(vb), .o_r(fm_r));
  ad_rx_fdiv u_fdiv (.clk, .rst_n, .i_start(fd_go), .i_a(va), .i_b(vb),
                     .busy(fd_busy), .o_done(fd_done), .o_r(fd_r));
  assign fd_go = (st == U_RUN) && (op == 5'd4);

  // ---------------------------------------------------------------- simple ops
  function automatic logic is_nan(input logic [31:0] x);
    is_nan = (x[30:23] == 8'hFF) && (x[22:0] != 0);
  endfunction
  function automatic logic flt(input logic [31:0] x, input logic [31:0] y);   // x < y (fp32, signed)
    if (x[31] != y[31]) flt = x[31] && !(x[30:0] == 0 && y[30:0] == 0);
    else if (x[31])     flt = x[30:0] > y[30:0];
    else                flt = x[30:0] < y[30:0];
  endfunction
  logic [31:0] simple;
  always_comb begin
    case (op)
      5'd5:  simple = {1'b0, va[30:0]};                                    // ABS
      5'd6:  simple = (va[30:0] >= vb[30:0]) ? va : vb;                    // MAX (magnitudes)
      5'd7:  simple = is_nan(vb) ? va : is_nan(va) ? vb : (flt(vb, va) ? vb : va);   // MIN
      5'd8:  simple = is_nan(vb) ? va : is_nan(va) ? vb : (flt(va, vb) ? vb : va);   // MXS
      5'd9:  simple = (va[30:23] > 8'd23) ? {1'b0, va[30:23] - 8'd23, 23'd0} : 32'd0; // ULP
      5'd10: begin                                                         // BCL
        if (vb[30:0] == 0)        simple = va;
        else if (!vb[31])         simple = flt(vb, va) ? vb : va;          // c > 0: min(o, c)
        else                      simple = flt(va, vb) ? vb : va;          // c < 0: max(o, c)
      end
      5'd16: simple = va;                                                  // MOV
      default: simple = 32'd0;
    endcase
  end

  // ---------------------------------------------------------------- INT (ad_rx_edge)
  logic        e_start, e_done, e_we, e_front, e_empty;
  logic [6:0]  e_wa;
  logic [31:0] e_rd, e_wd;
  logic [3*ad_rx_pkg::EDG_PCK-1:0] e_edges;
  logic [ad_rx_pkg::BBX_WID-1:0]   e_bbox;
  assign e_start = (st == U_RUN) && (op == 5'd11);
  ad_rx_edge u_edge (.clk, .rst_n, .start(e_start), .mode({raw, dd[0], kind}),
                     .smin(i_scmin), .smax(i_scmax), .rts(i_rtsiz), .cull(i_cull),
                     .vprect(i_rmode[3]), .r_ra(e_ra), .r_rd(e_rd), .r_we(e_we), .r_wa(e_wa),
                     .r_wd(e_wd), .done(e_done), .edges(e_edges), .bbox(e_bbox),
                     .front(e_front), .empty(e_empty));
  always_ff @(posedge clk) e_rd <= e_rdc;

  // ---------------------------------------------------------------- branches
  logic cond;
  always_comb begin
    case (ra[2:0])
      3'd0: cond = (kind == 2'd0);
      3'd1: cond = (kind == 2'd1);
      3'd2: cond = !i_rmode[0] || (i_rmode[5:4] == 2'd0) || (kind != 2'd2);
      3'd3: cond = (i_rmode[5:4] != 2'd3);
      3'd4: cond = !i_rmode[3];
      3'd5: cond = e_empty;
      default: cond = raw;
    endcase
  end

  // ---------------------------------------------------------------- engine
  assign cl_ready = (st == U_IDLE);
  assign busy     = (st != U_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= U_IDLE; pc <= '0; sp_valid <= 1'b0; sp_last <= 1'b0;
      pte <= '0; lst <= '0; raw <= 1'b0; last_q <= 1'b0; fin <= 1'b0; kind <= '0;
    end else begin
      case (st)
        U_IDLE: if (cl_valid) begin
          for (int i = 0; i < 21; i++) rf[i] <= cl_tri[32*i +: 32];
          for (int i = 0; i < 6; i++)  rf[21+i] <= i_vp[32*i +: 32];
          rf[27] <= ad_rx_pkg::FP_ONEV;
          pte <= cl_tri[672 +: 3*PI]; lst <= cl_tri[696 +: 3]; raw <= cl_tri[699];
          kind <= cl_tri[700 +: 2]; last_q <= cl_last;
          pc <= '0; st <= U_RUN;
        end
        U_RUN: begin
          case (op)
            5'd1, 5'd2: begin rf[dd[6:0]] <= fa_r; pc <= pc + 1'b1; end
            5'd3:       begin rf[dd[6:0]] <= fm_r; pc <= pc + 1'b1; end
            5'd4:       st <= U_DIV;
            5'd11:      st <= U_INT;
            5'd12:      begin fin <= 1'b0; st <= U_OUT; end
            5'd13:      begin fin <= 1'b1; st <= U_OUT; end
            5'd14:      pc <= cond ? dd : pc + 1'b1;
            5'd15:      pc <= dd;
            5'd0:       pc <= pc + 1'b1;
            default:    begin rf[dd[6:0]] <= simple; pc <= pc + 1'b1; end
          endcase
        end
        U_DIV: if (fd_done) begin rf[dd[6:0]] <= fd_r; pc <= pc + 1'b1; st <= U_RUN; end
        U_INT: begin
          if (e_we) rf[e_wa] <= e_wd;
          if (e_done) begin pc <= pc + 1'b1; st <= U_RUN; end
        end
        U_OUT: begin
          if (!sp_valid) begin
            sp_valid <= 1'b1;
            sp_last  <= fin && last_q;
          end else if (sp_ready) begin
            sp_valid <= 1'b0;
            if (fin) st <= U_IDLE;
            else begin pc <= pc + 1'b1; st <= U_RUN; end
          end
        end
        default: st <= U_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- sp_tri
  always_comb begin
    sp_tri = '0;
    sp_tri[ad_rx_pkg::SPT_EDG +: 288] = e_edges;
    sp_tri[ad_rx_pkg::SPT_BBX +: 64]  = e_bbox;
    for (int i = 0; i < 12; i++) sp_tri[ad_rx_pkg::SPT_PLZ + 32*i +: 32] = rf[80 + i];
    sp_tri[ad_rx_pkg::SPT_PTE +: 24]  = pte;
    sp_tri[ad_rx_pkg::SPT_LST +: 3]   = fin ? lst : 3'b000;
    sp_tri[ad_rx_pkg::SPT_FRT]        = e_front;
    sp_tri[ad_rx_pkg::SPT_RAW]        = raw;
    sp_tri[ad_rx_pkg::SPT_KND +: 2]   = kind;
    sp_tri[ad_rx_pkg::SPT_ZMN +: 32]  = rf[92];
    sp_tri[ad_rx_pkg::SPT_ZMX +: 32]  = rf[93];
  end

`ifdef FORMAL
  logic f_vld = 1'b0;
  always @(posedge clk) if (!rst_n) f_vld <= 1'b1;
  always @(posedge clk) if (f_vld && rst_n) begin
    assert (pc < 9'(UC_LEN));                                   // never runs off the program
    if (sp_valid && sp_tri[ad_rx_pkg::SPT_LST +: 3] != 0) assert (fin);
    if (sp_valid && sp_last) assert (fin && last_q);
    if (st == U_INT) assert (op == 5'd11);
    if (st == U_DIV) assert (op == 5'd4);
  end
  always @(posedge clk) if (f_vld && rst_n && $past(rst_n) && $past(sp_valid && !sp_ready))
    assert (sp_valid && sp_tri == $past(sp_tri) && sp_last == $past(sp_last));
`endif
endmodule
