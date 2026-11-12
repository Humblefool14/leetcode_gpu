// fv_rr_pick: equal to "first request at or after ptr, wrapping" for every req and ptr < N.
module fv_rr_pick #(parameter int N = 8, parameter int LOG_N = (N > 1) ? $clog2(N) : 1) (
    input logic [N-1:0] req,
    input logic [LOG_N-1:0] ptr
);
    logic [N-1:0] g; logic [LOG_N-1:0] gi; logic gv;
    rr_pick #(.N(N)) dut (.req(req), .ptr(ptr), .grant_onehot(g), .grant_index(gi), .grant_valid(gv));
    logic [N-1:0] ref_g; logic [LOG_N-1:0] ref_i; logic found;
    always_comb begin
        ref_g = '0; ref_i = '0; found = 1'b0;
        for (int k = 0; k < N; k++)
            for (int i = 0; i < N; i++)
                if (!found && req[i] && (int'(ptr) + k == i || int'(ptr) + k - N == i)) begin
                    found = 1'b1; ref_g[i] = 1'b1; ref_i = LOG_N'(i);
                end
    end
    always_comb if (int'(ptr) < N) begin
        assert (gv == |req);
        assert (g == ref_g);
        if (gv) assert (gi == ref_i);
    end
endmodule
