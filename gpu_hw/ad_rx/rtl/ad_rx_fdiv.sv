// ============================================================================
// ad_rx_fdiv -- fp32 a / b, iterative restoring division, one quotient bit per
// cycle.  Rules as ad_rx_fadd.  x/0 = +-inf (x != 0), 0/0 = inf/inf = NaN.
// Latency: FDV_ITR + 2 = 28 cycles from i_start to o_done; 2 for a special case.
// ============================================================================
module ad_rx_fdiv (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_start,    // taken only while !busy
  input  logic [31:0] i_a,
  input  logic [31:0] i_b,
  output logic        busy,
  output logic        o_done,     // one cycle
  output logic [31:0] o_r         // held until the next start
);
  localparam int NQ = ad_rx_pkg::FDV_ITR;         // 26 quotient bits

  typedef enum logic [1:0] {S_IDLE, S_RUN, S_SPEC, S_DONE} st_t;
  st_t st;

  logic [4:0]  cnt;
  logic [25:0] rem;               // partial remainder (< 2 * divisor)
  logic [23:0] dv;                // divisor significand
  logic [NQ-1:0] q;
  logic        sgn;
  logic [9:0]  eq;                // ea - eb + 127 (signed)
  logic [31:0] spec;

  // special cases decided at start
  logic        za, zb, ia, ib, na, nb, s0;
  assign s0 = i_a[31] ^ i_b[31];
  assign za = (i_a[30:23] == 8'd0);
  assign zb = (i_b[30:23] == 8'd0);
  assign ia = (i_a[30:23] == 8'hFF) && (i_a[22:0] == 23'd0);
  assign ib = (i_b[30:23] == 8'hFF) && (i_b[22:0] == 23'd0);
  assign na = (i_a[30:23] == 8'hFF) && (i_a[22:0] != 23'd0);
  assign nb = (i_b[30:23] == 8'hFF) && (i_b[22:0] != 23'd0);

  logic is_spec;
  logic [31:0] spec_v;
  always_comb begin
    is_spec = 1'b1;
    if (na || nb || (za && zb) || (ia && ib)) spec_v = ad_rx_pkg::FP_QNAN;
    else if (ia || zb)                        spec_v = {s0, 8'hFF, 23'd0};
    else if (za || ib)                        spec_v = {s0, 31'd0};
    else begin is_spec = 1'b0;                spec_v = 32'd0; end
  end

  // rounding of the finished quotient
  logic        top;
  logic [23:0] sig;
  logic        g, stk, rup;
  logic [24:0] rnd;
  logic [9:0]  en, er;
  assign top = q[NQ-1];
  assign sig = top ? q[NQ-1 -: 24] : q[NQ-2 -: 24];
  assign g   = top ? q[1] : q[0];
  assign stk = (top ? q[0] : 1'b0) | (rem != '0);
  assign rup = g & (stk | sig[0]);
  assign rnd = {1'b0, sig} + {24'd0, rup};
  assign en  = top ? eq : eq - 10'd1;
  assign er  = rnd[24] ? en + 10'd1 : en;

  logic [31:0] res;
  always_comb begin
    if (er[9] || er == 10'd0)  res = {sgn, 31'd0};
    else if (er >= 10'd255)    res = {sgn, 8'hFF, 23'd0};
    else                       res = {sgn, er[7:0], rnd[24] ? rnd[23:1] : rnd[22:0]};
  end

  logic [31:0] res_o;
`ifdef AD_FPABS
  (* anyseq *) logic [31:0] f_any;  // FPV cut-point
  assign res_o = f_any;
`else
  assign res_o = res;
`endif

  // one restoring step
  logic [26:0] trial;
  assign trial = {1'b0, rem} - {3'b000, dv};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE; o_done <= 1'b0; o_r <= 32'd0; cnt <= '0;
      rem <= '0; dv <= '0; q <= '0; sgn <= 1'b0; eq <= '0; spec <= '0;
    end else begin
      o_done <= 1'b0;
      case (st)
        S_IDLE: if (i_start) begin
          sgn  <= s0;
          spec <= spec_v;
          if (is_spec) st <= S_SPEC;
          else begin
            rem <= {2'b00, 1'b1, i_a[22:0]};
            dv  <= {1'b1, i_b[22:0]};
            eq  <= {2'b00, i_a[30:23]} - {2'b00, i_b[30:23]} + 10'd127;
            q   <= '0;
            cnt <= 5'(NQ);
            st  <= S_RUN;
          end
        end
        S_RUN: begin
          if (!trial[26]) begin
            rem <= {trial[24:0], 1'b0};
            q   <= {q[NQ-2:0], 1'b1};
          end else begin
            rem <= {rem[24:0], 1'b0};
            q   <= {q[NQ-2:0], 1'b0};
          end
          cnt <= cnt - 5'd1;
          if (cnt == 5'd1) st <= S_DONE;
        end
        S_SPEC: begin o_r <= spec; o_done <= 1'b1; st <= S_IDLE; end
        S_DONE: begin o_r <= res_o; o_done <= 1'b1; st <= S_IDLE; end
        default: st <= S_IDLE;
      endcase
    end
  end
  assign busy = (st != S_IDLE);

`ifdef FORMAL
  // tracker of the running division: its age and operands
  logic        f_run;
  logic [5:0]  f_age;
  logic [31:0] f_a, f_b;
  always_ff @(posedge clk) begin
    if (!rst_n) begin f_run <= 1'b0; f_age <= '0; end
    else begin
      if (o_done) f_run <= 1'b0; else if (f_run) f_age <= f_age + 1'b1;
      if (i_start && !busy) begin f_run <= 1'b1; f_age <= '0; f_a <= i_a; f_b <= i_b; end
    end
  end
  logic f_init = 1'b1;
  always @(posedge clk) begin
    f_init <= 1'b0;
    if (!f_init && $past(rst_n) && rst_n) begin
      assert (f_run == busy || o_done);
      if (f_run) assert (f_age <= 6'd27);                  // bounded latency: 28 cycles
      if (st == S_RUN) assert (f_age + 6'(cnt) == 6'd26); // one quotient bit per cycle
      if (st == S_RUN) assert (dv == {1'b1, f_b[22:0]});
      // x / 1.0 == x and x / x == 1.0 for normal x
      if (o_done && f_b == ad_rx_pkg::FP_ONEV && f_a[30:23] != 0 && f_a[30:23] != 8'hFF) assert (o_r == f_a);
      if (o_done && f_b == f_a && f_a[30:23] != 0 && f_a[30:23] != 8'hFF) assert (o_r == ad_rx_pkg::FP_ONEV);
      if (o_done) assert ($past(st) == S_SPEC || $past(st) == S_DONE);
      if (st == S_RUN) assert (cnt != 0 && cnt <= 5'(NQ));
      if (st == S_RUN) assert (rem < {1'b0, dv, 1'b0});   // restoring invariant
      if (st == S_RUN) assert (dv[23]);
    end
  end
`endif
endmodule
