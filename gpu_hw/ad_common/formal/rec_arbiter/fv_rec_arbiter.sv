// fv_rec_arbiter: equal to "lowest set bit wins" for every request vector.
module fv_rec_arbiter #(parameter int N = 8, parameter int LOG_N = (N > 1) ? $clog2(N) : 1) (
    input logic [N-1:0] req
);
    logic [N-1:0] g; logic [LOG_N-1:0] gi; logic gv;
    rec_arbiter #(.N(N)) dut (.req(req), .grant_onehot(g), .grant_index(gi), .grant_valid(gv));
    logic [N-1:0] ref_g; logic [LOG_N-1:0] ref_i;
    always_comb begin
        ref_g = '0; ref_i = '0;
        for (int i = N - 1; i >= 0; i--) if (req[i]) begin ref_g = '0; ref_g[i] = 1'b1; ref_i = LOG_N'(i); end
    end
    always_comb begin
        assert (gv == |req);
        assert (g == ref_g);
        if (gv) assert (gi == ref_i);
    end
endmodule
