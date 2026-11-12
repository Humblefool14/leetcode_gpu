// ad_delay -- N-stage valid/data delay line (common library): in at cycle t,
// out at cycle t + N (N >= 1).  Only the valid bits are reset; the data is
// datapath qualified by them.  Replaces ad_ctl_spipe (ad_su).
module ad_delay #(
    parameter N = 6,
    parameter W = 8
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         in_valid,
    input  wire [W-1:0] in_data,
    output wire         out_valid,
    output wire [W-1:0] out_data
);
    reg [N-1:0] v;
    reg [W-1:0] d [0:N-1];
    integer i;
    always @(posedge clk) begin
        if (!rst_n) v <= {N{1'b0}};
        else v <= {v, in_valid};
        d[0] <= in_data;
        for (i = 1; i < N; i = i + 1) d[i] <= d[i-1];
    end
`ifdef MUT_DELAY_SHORT
    assign out_valid = (N > 1) ? v[(N > 1) ? N-2 : 0] : in_valid;   // mutation: one stage early
`else
    assign out_valid = v[N-1];
`endif
    assign out_data  = d[N-1];
endmodule
