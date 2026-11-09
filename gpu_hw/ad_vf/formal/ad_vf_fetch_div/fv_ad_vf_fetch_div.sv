// fv_ad_vf_fetch_div -- the instance-element divider with memo.
// A start accepted while idle samples (n, d), d != 0 (the parent starts only for divisors >= 2;
// d = 1 is allowed here too).  Properties:
//   done only for an accepted start, at most 33 cycles after it, and then
//   P + r == n and r < d, where P = q * d is computed by the harness as a shift-add product of
//   the quotient bits as the DUT produces them (P' = 2P + bit * d alongside q' = 2q + bit), so
//   no multiplier enters the solver; q itself is checked equal to those bits.
//   busy only while a started division runs.
// Helper invariants (k-induction), on the AD_FV_DIV observation ports: at iteration i = cnt the
// unconsumed dividend bits are n's low 32 - i bits, P + rem == n >> (32 - i), rem < d; the memo
// holds a correct division (mP + m_r == m_n, m_r < m_d).
module fv_ad_vf_fetch_div (
    input wire        clk,
    input wire        rst_n,
    input wire        start,
    input wire [31:0] n,
    input wire [7:0]  d
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);
    wire busy, done; wire [31:0] q; wire [7:0] r;
    wire [5:0] cnt; wire [31:0] qn, nn, m_n; wire [8:0] rem; wire [7:0] dd, m_d; wire m_v, ge;
    ad_vf_fetch_div dut (.clk(clk), .rst_n(rst_n), .start(start), .n(n), .d(d), .busy(busy), .done(done), .q(q), .r(r),
        .fv_cnt(cnt), .fv_qn(qn), .fv_rem(rem), .fv_dd(dd), .fv_nn(nn), .fv_m_v(m_v), .fv_m_n(m_n), .fv_m_d(m_d),
        .fv_ge(ge));
    always @(*) if (start) assume (d != 8'd0);
    always @(*) if (start) assume (!busy && !done);     // parent: one division at a time
    reg        pend;
    reg [31:0] s_n; reg [7:0] s_d; reg [5:0] age;
    reg [39:0] P, mP;                                   // running / memo quotient * divisor
    reg [31:0] Qh, mQ;                                  // the quotient bits seen
    wire [39:0] P_nx = {P[38:0], 1'b0} + (ge ? {32'd0, dd} : 40'd0);
    wire [31:0] Q_nx = {Qh[30:0], ge};
    always @(posedge clk) begin
        if (!rst_n) begin pend <= 1'b0; s_n <= 0; s_d <= 8'd1; age <= 0; P <= 0; mP <= 0; Qh <= 0; mQ <= 0; end
        else begin
            if (done) pend <= 1'b0;
            if (start) begin pend <= 1'b1; s_n <= n; s_d <= d; age <= 0; P <= 0; Qh <= 0; end
            else if (pend && age != 6'd63) age <= age + 1;
            if (busy) begin
                P <= P_nx; Qh <= Q_nx;
                if (cnt == 6'd31) begin mP <= P_nx; mQ <= Q_nx; end
            end
        end
    end
    always @(*) if (!init && rst_n) begin
        if (done) begin
            a_pend:  assert (pend);
            a_q:     assert (q == mQ);
            a_div:   assert (mP + {32'd0, r} == {8'd0, s_n});
            a_rem:   assert (r < s_d);
        end
        a_lat:  assert (!pend || age <= 6'd33);
        a_busy: assert (!busy || (pend && !done));
    end
    // helper invariants
    wire [5:0]  i   = cnt;
    wire [31:0] nhi = (i == 0) ? 32'd0 : (s_n >> (6'd32 - i));
    always @(*) if (!init && rst_n) begin
        h_mv:  assert (!m_v || (m_d != 0 && mP + {32'd0, r} == {8'd0, m_n} && r < m_d && q == mQ));
        h_pd:  assert (!pend || busy || done);
        if (busy) begin
            h_cnt: assert (cnt <= 6'd31);
            h_op:  assert (dd == s_d && nn == s_n && pend && dd != 0);
            h_age: assert (age == cnt);
            h_lo:  assert ((qn >> i) == ((s_n << i) >> i));
            h_qb:  assert ((i == 0) || (qn << (6'd32 - i)) == (Qh << (6'd32 - i)));
            h_rem: assert (rem < {1'b0, dd});
            h_p:   assert (P + {31'd0, rem} == {8'd0, nhi});
        end
        if (done) h_dn: assert (m_v && m_n == s_n && m_d == s_d);
    end
endmodule
