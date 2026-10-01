// ---------------------------------------------------------------------------
// qos_arbiter
//   Two request classes per slot: req_hi[N-1:0] and req_lo[N-1:0].
//
//   Policy
//   - High-priority class normally wins over low-priority class.
//   - While any low request is pending, at most HI_BURST consecutive grants
//     may go to the high class. After that, the next grant is forced to the
//     low class (if any low request is pending), then the count restarts.
//   - HI_BURST = 1 -> strict alternation hi/lo under contention.
//   - Each class is round-robin internally, so no single slot starves
//     inside its class either.
//
//   Handshake
//   - grant_* are combinational from the current requests and state.
//   - grant_ready = 1 means the grant is consumed this cycle; state
//     (RR pointers and the burst counter) only advances on
//     grant_valid & grant_ready. Tie it to 1 for one grant per cycle.
//
//   Bounded wait (in accepted grants), worst case:
//     low  slot : N_LO_WAIT = N * (HI_BURST + 1)
//     high slot : N * (1 + ceil(1/HI_BURST)) <= 2N
// ---------------------------------------------------------------------------
module qos_arbiter #(
    parameter int N        = 8,
    parameter int HI_BURST = 1,
    parameter int LOG_N    = (N > 1) ? $clog2(N) : 1,
    parameter int CNT_W    = (HI_BURST > 1) ? $clog2(HI_BURST + 1) : 1
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [N-1:0]     req_hi,
    input  logic [N-1:0]     req_lo,
    input  logic             grant_ready,
    output logic [N-1:0]     grant_onehot,
    output logic [LOG_N-1:0] grant_index,
    output logic             grant_is_hi,
    output logic             grant_valid
);
    // synopsys translate_off
    initial if (HI_BURST < 1) $error("qos_arbiter: HI_BURST must be >= 1");
    // synopsys translate_on

    logic [N-1:0]     gnt_hi, gnt_lo;
    logic [LOG_N-1:0] idx_hi, idx_lo;
    logic             vld_hi, vld_lo;
    logic             pick_hi, fire;
    logic [CNT_W-1:0] hi_cnt;          // consecutive hi grants while lo waits

    // Class selection
    //   lo pending and burst budget exhausted -> low class
    //   otherwise high class if it has a request, else low class
    wire hi_throttled = vld_lo && (hi_cnt >= CNT_W'(HI_BURST));
    assign pick_hi    = vld_hi && !hi_throttled;

    assign fire = grant_valid && grant_ready;

    rr_arbiter #(.N(N)) u_hi (
        .clk(clk), .rst_n(rst_n), .req(req_hi), .update(fire &&  pick_hi),
        .grant_onehot(gnt_hi), .grant_index(idx_hi), .grant_valid(vld_hi));

    rr_arbiter #(.N(N)) u_lo (
        .clk(clk), .rst_n(rst_n), .req(req_lo), .update(fire && !pick_hi),
        .grant_onehot(gnt_lo), .grant_index(idx_lo), .grant_valid(vld_lo));

    assign grant_valid  = vld_hi | vld_lo;
    assign grant_is_hi  = pick_hi;
    assign grant_onehot = pick_hi ? gnt_hi : gnt_lo;
    assign grant_index  = pick_hi ? idx_hi : idx_lo;

    // Burst counter
    //   - cleared on a low grant, or whenever no low request is waiting
    //     (high traffic only "costs" budget while someone low is waiting)
    //   - incremented on each high grant while low is waiting
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hi_cnt <= '0;
        end else if (fire) begin
            if (!pick_hi || !vld_lo) hi_cnt <= '0;
            else                     hi_cnt <= hi_cnt + 1'b1;
        end
    end

    // synopsys translate_off
`ifndef QOS_NO_ASSERT
    // Never more than HI_BURST high grants in a row while low is waiting.
    always @(posedge clk) if (rst_n && fire && vld_lo && pick_hi)
        if (hi_cnt >= CNT_W'(HI_BURST))
            $error("qos_arbiter: high burst limit violated");
    // Grant is one-hot and a subset of the selected class's requests.
    always @(posedge clk) if (rst_n && grant_valid) begin
        if ($countones(grant_onehot) != 1)
            $error("qos_arbiter: grant not one-hot");
        if ((grant_onehot & (pick_hi ? req_hi : req_lo)) != grant_onehot)
            $error("qos_arbiter: grant to non-requesting slot");
    end
`endif
    // synopsys translate_on
endmodule
