// ---------------------------------------------------------------------------
// rr_pick
//   Combinational round-robin choice: the first request at or after ptr
//   (wrapping).  Built from two rec_arbiters: one on the requests at or above
//   ptr, one on all requests; the first wins when it has any.
//   ptr must be < N.  grant_* as rec_arbiter.  The caller keeps ptr; for
//   round-robin it loads grant_index + 1 (mod N) when a grant is used.
//   Equivalent to ad_su_rr_pick (ad_su) and the inline pick of ad_amb_mux
//   (ptr = rr_last + 1).
// ---------------------------------------------------------------------------
module rr_pick #(
    parameter int N     = 8,
    parameter int LOG_N = (N > 1) ? $clog2(N) : 1
) (
    input  logic [N-1:0]     req,
    input  logic [LOG_N-1:0] ptr,
    output logic [N-1:0]     grant_onehot,
    output logic [LOG_N-1:0] grant_index,
    output logic             grant_valid
);
    logic [N-1:0]     mask, gm, ga;
    logic [LOG_N-1:0] im, ia;
    logic             vm, va;

    // mask[i] = (i >= ptr): thermometer, constant indices only
    always_comb
        for (int i = 0; i < N; i++) mask[i] = (LOG_N'(i) >= ptr);

    rec_arbiter #(.N(N)) u_m (.req(req & mask), .grant_onehot(gm), .grant_index(im), .grant_valid(vm));
    rec_arbiter #(.N(N)) u_a (.req(req),        .grant_onehot(ga), .grant_index(ia), .grant_valid(va));

    assign grant_onehot = vm ? gm : ga;
    assign grant_index  = vm ? im : ia;
    assign grant_valid  = va;
endmodule
