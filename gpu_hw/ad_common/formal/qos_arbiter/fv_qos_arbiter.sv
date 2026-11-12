// fv_qos_arbiter: requests held (per class) until granted.  Checks: grant one-hot and to a
// requester of the selected class; never more than HI_BURST high grants in a row while a low
// request waits; a low request waits at most N*(HI_BURST+1) grants, a high request at most
// N*(1+ceil(1/HI_BURST)) grants (the bounds in qos_arbiter's header).
module fv_qos_arbiter #(parameter int N = 4, parameter int HI_BURST = 2,
                        parameter int LOG_N = (N > 1) ? $clog2(N) : 1) (
    input logic clk,
    input logic [N-1:0] req_hi,
    input logic [N-1:0] req_lo,
    input logic grant_ready
);
    logic init = 1'b1;
    always_ff @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    logic [N-1:0] g; logic [LOG_N-1:0] gi; logic ghi, gv;
    qos_arbiter #(.N(N), .HI_BURST(HI_BURST)) dut (.clk(clk), .rst_n(rst_n), .req_hi(req_hi),
        .req_lo(req_lo), .grant_ready(grant_ready), .grant_onehot(g), .grant_index(gi),
        .grant_is_hi(ghi), .grant_valid(gv));
    localparam int LO_BOUND = N * (HI_BURST + 1);
    localparam int HI_BOUND = N * (1 + (1 + HI_BURST - 1) / HI_BURST);
    wire fire = gv && grant_ready && rst_n;
    logic [N-1:0] p_hi, p_lo, p_g; logic p_fire = 1'b0, p_ghi;
    logic [7:0] w_hi [N], w_lo [N], run;
    always_ff @(posedge clk) begin
        p_hi <= req_hi; p_lo <= req_lo; p_g <= g; p_fire <= fire; p_ghi <= ghi;
        for (int i = 0; i < N; i++) begin
            if (!rst_n || !req_hi[i] || (fire && ghi && g[i])) w_hi[i] <= '0;
            else if (fire) w_hi[i] <= w_hi[i] + 1'b1;
            if (!rst_n || !req_lo[i] || (fire && !ghi && g[i])) w_lo[i] <= '0;
            else if (fire) w_lo[i] <= w_lo[i] + 1'b1;
        end
        // consecutive high grants while a low request waits
        if (!rst_n) run <= '0;
        else if (fire) run <= (ghi && |req_lo) ? run + 1'b1 : '0;
    end
    always_comb if (rst_n && !init) for (int i = 0; i < N; i++) begin
        if (p_hi[i] && !(p_fire && p_ghi && p_g[i]))  assume (req_hi[i]);
        if (p_lo[i] && !(p_fire && !p_ghi && p_g[i])) assume (req_lo[i]);
    end
    always_comb if (rst_n) begin
        assert ($onehot0(g));
        assert (gv == (|req_hi || |req_lo));
        if (gv) assert ((g & ~(ghi ? req_hi : req_lo)) == '0);
        assert (run <= HI_BURST);
        for (int i = 0; i < N; i++) begin
            assert (w_lo[i] <= LO_BOUND);
            assert (w_hi[i] <= HI_BOUND);
        end
    end
endmodule
