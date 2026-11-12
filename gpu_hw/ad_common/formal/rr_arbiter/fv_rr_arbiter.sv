// fv_rr_arbiter: with every request held until it is granted, a requester waits at most N-1
// grants to others (starvation-free), the grant is one-hot and to a requester, and the pointer
// stays below N.
module fv_rr_arbiter #(parameter int N = 5, parameter int LOG_N = (N > 1) ? $clog2(N) : 1) (
    input logic clk,
    input logic [N-1:0] req,
    input logic update
);
    logic init = 1'b1;
    always_ff @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    logic [N-1:0] g; logic [LOG_N-1:0] gi; logic gv;
    rr_arbiter #(.N(N)) dut (.clk(clk), .rst_n(rst_n), .req(req), .update(update),
                             .grant_onehot(g), .grant_index(gi), .grant_valid(gv));
    wire fire = update && gv && rst_n;
    logic [N-1:0] p_req, p_g; logic p_fire = 1'b0;
    logic [7:0] wait_n [N];
    always_ff @(posedge clk) begin
        p_req <= req; p_g <= g; p_fire <= fire;
        for (int i = 0; i < N; i++)
            if (!rst_n || !req[i] || (fire && g[i])) wait_n[i] <= '0;
            else if (fire) wait_n[i] <= wait_n[i] + 1'b1;
    end
    // a request is held until granted
    always_comb if (rst_n && !init) for (int i = 0; i < N; i++)
        if (p_req[i] && !(p_fire && p_g[i])) assume (req[i]);
    always_comb if (rst_n) begin
        assert ($onehot0(g));
        assert ((g & ~req) == '0);
        assert (gv == |req);
        for (int i = 0; i < N; i++) assert (wait_n[i] <= N - 1);
    end
endmodule
