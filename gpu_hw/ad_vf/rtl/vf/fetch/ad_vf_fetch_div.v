// ad_vf_fetch_div -- instance-element divider of ad_vf_fetch (spec §4): q = n / d, r = n % d
// for the per-instance divisor rule, n = inst - FIRST_INSTANCE (32 bits), d = DESC[31:24].
// Sequential restoring divider, one quotient bit per cycle (32 cycles), with a one-entry memo
// of the last (n, d) -> (q, r): a start whose (n, d) equals the memo answers the next cycle.
//   start (one cycle, while !busy) -> busy ... -> done (one cycle, q and r valid; held after).
// d = 0 is never started by ad_vf_fetch (divisors 0 and 1 need no division); the result is
// then q = all ones, r = n's low bits (no property).
module ad_vf_fetch_div (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [31:0] n,
    input  wire [7:0]  d,
    output wire        busy,
    output reg         done,
    output wire [31:0] q,
    output wire [7:0]  r
`ifdef AD_FV_DIV
    // formal-only observation (helper invariants)
    ,output wire [5:0]  fv_cnt
    ,output wire [31:0] fv_qn
    ,output wire [8:0]  fv_rem
    ,output wire [7:0]  fv_dd
    ,output wire [31:0] fv_nn
    ,output wire        fv_m_v
    ,output wire [31:0] fv_m_n
    ,output wire [7:0]  fv_m_d
    ,output wire        fv_ge
`endif
);
    reg        run;
    reg [5:0]  cnt;          // iterations done (0..32)
    reg [31:0] qn;           // {dividend bits not yet consumed, quotient bits so far}
    reg [8:0]  rem;          // partial remainder (< d after each step)
    reg [7:0]  dd;
    reg [31:0] nn;
    // memo
    reg        m_v;
    reg [31:0] m_n, m_q;
    reg [7:0]  m_d, m_r;

    wire       m_hit = m_v && (m_n == n) && (m_d == d);
    wire [8:0] t     = {rem[7:0], qn[31]};
    wire       ge    = (t >= {1'b0, dd});
    wire [8:0] t_sub = t - {1'b0, dd};

    assign busy = run;
    assign q    = m_q;
    assign r    = m_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            run <= 1'b0; done <= 1'b0; cnt <= 6'd0; m_v <= 1'b0;
            qn <= 32'd0; rem <= 9'd0; dd <= 8'd0; nn <= 32'd0;
            m_n <= 32'd0; m_q <= 32'd0; m_d <= 8'd0; m_r <= 8'd0;
        end else begin
            done <= 1'b0;
            if (run) begin
                qn  <= {qn[30:0], ge};
                rem <= ge ? t_sub : t;
                cnt <= cnt + 6'd1;
                if (cnt == 6'd31) begin
                    run <= 1'b0; done <= 1'b1;
                    m_v <= 1'b1; m_n <= nn; m_d <= dd;
                    m_q <= {qn[30:0], ge}; m_r <= ge ? t_sub[7:0] : t[7:0];
                end
            end else if (start) begin
                if (m_hit) done <= 1'b1;
                else begin
                    run <= 1'b1; cnt <= 6'd0; qn <= n; rem <= 9'd0; dd <= d; nn <= n;
                end
            end
        end
    end
`ifdef AD_FV_DIV
    assign fv_cnt = cnt; assign fv_qn = qn; assign fv_rem = rem; assign fv_dd = dd; assign fv_nn = nn;
    assign fv_m_v = m_v; assign fv_m_n = m_n; assign fv_m_d = m_d; assign fv_ge = ge;
`endif
endmodule
