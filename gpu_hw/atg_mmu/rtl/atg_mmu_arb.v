// ============================================================================
// atg_mmu_arb -- round-robin arbiter for L1 miss requests into the shared L2
// ----------------------------------------------------------------------------
// * gnt is one-hot (or zero) and only ever selects an asserted req bit.
// * The priority pointer (one-hot "lst" = last winner) moves only when the
//   grant is actually taken (rdy), so a stalled grant keeps its owner.
// * Arithmetic-free: the circular scan is unrolled at elaboration time;
//   (p + k) % N below are constant loop expressions, not signal arithmetic.
// ============================================================================
`include "atg_mmu_pkg.vh"
module atg_mmu_arb #(
    parameter N = `AMU_NCL
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] req,     // requesters
    input  wire         rdy,     // downstream accepts the granted request this cycle
    output reg  [N-1:0] gnt      // one-hot grant
);
    reg [N-1:0] lst;             // one-hot: last granted requester

    integer p, k, c;
    reg     fnd;
    always @(*) begin
        gnt = {N{1'b0}};
        fnd = 1'b0;
        for (p = 0; p < N; p = p + 1) begin
            for (k = 1; k <= N; k = k + 1) begin
                c = (p + k) % N;
                if (lst[p] && !fnd && req[c]) begin
                    gnt[c] = 1'b1;
                    fnd    = 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n)
            lst <= {1'b1, {(N-1){1'b0}}};       // first scan starts at requester 0
        else if (rdy && |gnt)
            lst <= gnt;
    end

`ifdef FORMAL
    // ---- internal invariants (proved standalone and again inside atg_mmu)
    reg f_pv = 1'b0;
    always @(posedge clk) f_pv <= 1'b1;
    always @(*) if (f_pv && rst_n) begin
        assert (lst != 0 && (lst & (lst - 1)) == 0);       // pointer stays one-hot
        assert ((gnt & (gnt - 1)) == 0);                   // grant one-hot or zero
        assert ((gnt & ~req) == 0);                        // only requesters win
        assert ((|req) == (|gnt));                         // work conserving
    end

    // Requesters hold req until granted with rdy.  Standalone (AMU_FVA) this
    // is the environment; inside atg_mmu it is checked against the L1s.
    always @(posedge clk) if (f_pv && rst_n && $past(rst_n))
`ifdef AMU_FVA
        assume ((($past(req) & ~($past(gnt) & {N{$past(rdy)}})) & ~req) == 0);
`else
        assert ((($past(req) & ~($past(gnt) & {N{$past(rdy)}})) & ~req) == 0);
`endif

    // Fairness: a waiting requester is passed over at most N-1 times.
    // Inductive form: wt + (circular distance from the pointer) <= N.
    reg [7:0] f_wt [0:N-1];
    integer fi, fj, fk;
    reg [7:0] f_lp, f_d;
    always @(posedge clk)
        for (fk = 0; fk < N; fk = fk + 1)
            if (!rst_n || !req[fk] || (gnt[fk] && rdy)) f_wt[fk] <= 8'd0;
            else if (rdy && |gnt)                       f_wt[fk] <= f_wt[fk] + 8'd1;
    always @(*) begin
        f_lp = 8'd0;
        for (fj = 0; fj < N; fj = fj + 1) if (lst[fj]) f_lp = fj;
        for (fi = 0; fi < N; fi = fi + 1) begin
            f_d = ((fi + N - f_lp - 1) % N) + 1;
            if (f_pv && rst_n) begin
                assert (f_wt[fi] < N);
                if (req[fi]) assert (f_wt[fi] + f_d <= N);
                else         assert (f_wt[fi] == 0);
            end
        end
    end
`endif
endmodule
