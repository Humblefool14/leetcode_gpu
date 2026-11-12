// ---------------------------------------------------------------------------
// rr_arbiter
//   Round-robin arbiter with registered pointer (the interface qos_arbiter
//   expects).  grant_* are combinational from req and the pointer; on update
//   (the grant is used this cycle) the pointer moves to grant_index + 1, so
//   the granted slot becomes the lowest priority.  Reset: synchronous, active
//   low (repository convention); the pointer starts at 0.
//   Bounded wait: a request held until granted waits at most N-1 grants.
// ---------------------------------------------------------------------------
module rr_arbiter #(
    parameter int N     = 8,
    parameter int LOG_N = (N > 1) ? $clog2(N) : 1
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [N-1:0]     req,
    input  logic             update,
    output logic [N-1:0]     grant_onehot,
    output logic [LOG_N-1:0] grant_index,
    output logic             grant_valid
);
    logic [LOG_N-1:0] ptr;

    rr_pick #(.N(N)) u_pick (.req(req), .ptr(ptr), .grant_onehot(grant_onehot),
                             .grant_index(grant_index), .grant_valid(grant_valid));

    always_ff @(posedge clk) begin
        if (!rst_n)
            ptr <= '0;
        else if (update && grant_valid)
`ifdef MUT_RR_STUCK
            ptr <= ptr;                                   // mutation: pointer never moves
`else
            ptr <= (grant_index == LOG_N'(N - 1)) ? '0 : grant_index + 1'b1;
`endif
    end
endmodule
