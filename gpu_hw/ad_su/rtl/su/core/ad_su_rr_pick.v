// ad_su_rr_pick -- round-robin choice among N requests (leaf of ad_su_wb): the
// first request at or after ptr (wrapping); gnt is one-hot, any = |req.
// Combinational; the parent advances ptr to the granted index + 1.
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off UNUSEDSIGNAL */
module ad_su_rr_pick #(
    parameter N  = 6,
    parameter PW = (N > 1) ? $clog2(N) : 1
) (
    input  wire [N-1:0]  req,
    input  wire [PW-1:0] ptr,
    output reg  [N-1:0]  gnt,
    output reg  [PW-1:0] idx,
    output wire          any
);
    assign any = |req;
    integer k, j;
    reg found;
    reg [PW:0] pos;
    always @(*) begin
        gnt = {N{1'b0}};
        idx = {PW{1'b0}};
        found = 1'b0;
        for (k = 0; k < N; k = k + 1) begin
            pos = ptr + k;                       // ptr < N
            if (pos >= N) pos = pos - N;
            for (j = 0; j < N; j = j + 1)
                if (!found && pos == j && req[j]) begin
                    found = 1'b1;
                    gnt[j] = 1'b1;
                    idx = j;
                end
        end
    end
endmodule
