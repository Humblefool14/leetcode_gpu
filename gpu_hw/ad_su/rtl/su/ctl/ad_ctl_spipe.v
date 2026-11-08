// ad_ctl_spipe -- N-stage valid/data delay line (a short unit's result
// pipeline): in at cycle t, out at cycle t + N.  The valid bits are reset.
module ad_ctl_spipe #(
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
        else v <= {v[N-2:0], in_valid};
        d[0] <= in_data;
        for (i = 1; i < N; i = i + 1) d[i] <= d[i-1];
    end
    assign out_valid = v[N-1];
    assign out_data  = d[N-1];
endmodule
