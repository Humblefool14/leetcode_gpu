// ad_ctl_wsel -- the fetch selector of ad_su_sched.  cand: the selectable
// warps.  GTO = 1 (greedy-then-oldest): the greedy warp gw (when gv) if it
// is a candidate, else the candidate with the largest age (lowest index on a
// tie).  GTO = 0: round-robin, the first candidate after last (cyclic).
// Combinational; sel_v = some candidate.
module ad_ctl_wsel #(
    parameter NWARPS = 4,
    parameter WARP_W = 2,
    parameter AGE_W  = 8,
    parameter GTO    = 1
) (
    input  wire [NWARPS-1:0]       cand,
    input  wire                    gv,
    input  wire [WARP_W-1:0]       gw,
    input  wire [NWARPS*AGE_W-1:0] age,
    input  wire [WARP_W-1:0]       last,
    output reg                     sel_v,
    output reg  [WARP_W-1:0]       sel_w
);
    integer i, j;
    reg [AGE_W-1:0] best;
    always @(*) begin
        sel_v = |cand;
        sel_w = {WARP_W{1'b0}};
        best  = {AGE_W{1'b0}};
        if (GTO != 0) begin
            if (gv && cand[gw]) sel_w = gw;
            else begin
                for (i = NWARPS - 1; i >= 0; i = i - 1)
                    if (cand[i] && age[AGE_W*i +: AGE_W] >= best) begin
                        best = age[AGE_W*i +: AGE_W]; sel_w = i;
                    end
            end
        end else begin
            for (i = NWARPS; i >= 1; i = i - 1) begin
                j = (last + i) % NWARPS;
                if (cand[j]) sel_w = j;
            end
        end
    end
endmodule
