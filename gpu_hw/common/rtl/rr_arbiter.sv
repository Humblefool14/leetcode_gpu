// ---------------------------------------------------------------------------
// rr_arbiter
//   Round-robin arbiter built from two rec_arbiter instances.
//   - "masked" instance sees only requests above the last granted index
//   - "unmasked" instance sees all requests (wrap-around)
//   The masked result wins if it has any request; otherwise wrap around.
//   The pointer advances only when the grant is actually taken (update=1).
// ---------------------------------------------------------------------------
module rr_arbiter #(
    parameter int N     = 8,
    parameter int LOG_N = (N > 1) ? $clog2(N) : 1
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [N-1:0]     req,
    input  logic             update,        // grant consumed this cycle
    output logic [N-1:0]     grant_onehot,
    output logic [LOG_N-1:0] grant_index,
    output logic             grant_valid
);
    logic [LOG_N-1:0] last_idx;
    logic [N-1:0]     mask, req_m;
    logic [N-1:0]     gnt_m, gnt_u;
    logic [LOG_N-1:0] idx_m, idx_u;
    logic             vld_m, vld_u;

    // mask[i] = 1 for slots strictly above the last granted slot
    for (genvar i = 0; i < N; i++) begin : g_mask
        assign mask[i] = (LOG_N'(i) > last_idx);
    end
    assign req_m = req & mask;

    rec_arbiter #(.N(N)) arb_masked (
        .req(req_m), .grant_onehot(gnt_m), .grant_index(idx_m), .grant_valid(vld_m));

    rec_arbiter #(.N(N)) arb_unmasked (
        .req(req),   .grant_onehot(gnt_u), .grant_index(idx_u), .grant_valid(vld_u));

    assign grant_onehot = vld_m ? gnt_m : gnt_u;
    assign grant_index  = vld_m ? idx_m : idx_u;
    assign grant_valid  = vld_u;            // vld_m implies vld_u

    // Reset to N-1 so slot 0 has priority first.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    last_idx <= LOG_N'(N-1);
        else if (update && grant_valid) last_idx <= grant_index;
    end
endmodule


