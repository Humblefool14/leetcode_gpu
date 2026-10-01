// ---------------------------------------------------------------------------
// rec_arbiter
//   Recursive fixed-priority arbiter (lowest index wins).
//
//   Recursion:  N -> N_A = N/2 (floor), N_B = N - N_A (ceil)
//               e.g. 7 -> 3 + 4, 4 -> 2 + 2, 5 -> 2 + 3
//   Base cases: N == 2 and N == 3 (N == 1 is handled as a trivial guard
//               so the module is also legal at the top level for N = 1;
//               the recursion itself never produces N == 1 for N >= 2).
//
//   Outputs:
//     grant_onehot : exactly one bit set when any request is active, else 0
//     grant_index  : binary index of the granted slot (valid with grant_valid)
//     grant_valid  : |req
// ---------------------------------------------------------------------------
module rec_arbiter #(
    parameter int N     = 8,
    parameter int LOG_N = (N > 1) ? $clog2(N) : 1
) (
    input  logic [N-1:0]     req,
    output logic [N-1:0]     grant_onehot,
    output logic [LOG_N-1:0] grant_index,
    output logic             grant_valid
);

    if (N == 1) begin : g_n1
        // Trivial guard; not reached by the recursion for N >= 2.
        assign grant_onehot = req;
        assign grant_index  = '0;
        assign grant_valid  = req[0];

    end else if (N == 2) begin : g_n2
        assign grant_onehot[0] = req[0];
        assign grant_onehot[1] = req[1] & ~req[0];
        assign grant_index     = LOG_N'(~req[0] & req[1]);
        assign grant_valid     = |req;

    end else if (N == 3) begin : g_n3
        assign grant_onehot[0] = req[0];
        assign grant_onehot[1] = req[1] & ~req[0];
        assign grant_onehot[2] = req[2] & ~req[1] & ~req[0];
        assign grant_index     = req[0] ? LOG_N'(0) :
                                 req[1] ? LOG_N'(1) :
                                          LOG_N'(2);
        assign grant_valid     = |req;

    end else begin : g_split
        localparam int N_A   = N / 2;       // lower slots  [N_A-1:0]
        localparam int N_B   = N - N_A;     // upper slots  [N-1:N_A]
        localparam int LOG_A = $clog2(N_A);
        localparam int LOG_B = $clog2(N_B);

        logic [N_A-1:0]   gnt_A;
        logic [N_B-1:0]   gnt_B;
        logic [LOG_A-1:0] idx_A;
        logic [LOG_B-1:0] idx_B;
        logic             vld_A, vld_B;

        rec_arbiter #(.N(N_A)) arb_A (
            .req          (req[N_A-1:0]),
            .grant_onehot (gnt_A),
            .grant_index  (idx_A),
            .grant_valid  (vld_A)
        );

        rec_arbiter #(.N(N_B)) arb_B (
            .req          (req[N-1:N_A]),
            .grant_onehot (gnt_B),
            .grant_index  (idx_B),
            .grant_valid  (vld_B)
        );

        // Combine: lower half has priority. If A has any request, B is masked.
        assign grant_onehot = {gnt_B & {N_B{~vld_A}}, gnt_A};
        assign grant_index  = vld_A ? LOG_N'(idx_A)
                                    : LOG_N'(N_A) + LOG_N'(idx_B);
        assign grant_valid  = vld_A | vld_B;
    end

endmodule
