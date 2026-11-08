// ad_gfx_skid -- two-stage skid buffer (spec ad_su_exp_mesh.md §4): an output register and a
// skid register; in_ready is registered (= skid empty), so neither side has a combinational
// path to the other.  Data leave in the order they came, none lost or duplicated.
module ad_gfx_skid #(
    parameter W = 8
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [W-1:0] in_data,
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [W-1:0] out_data,
    output wire         empty
);
    reg         sv;
    reg [W-1:0] sd;

`ifdef MUT_SKID_LOSS
    assign in_ready = 1'b1;                    // mutation: a datum taken while the skid is full
`else
    assign in_ready = !sv;
`endif
    assign empty = !out_valid && !sv;

    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            sv <= 1'b0;
        end else if (out_ready || !out_valid) begin
            if (sv) begin
                out_valid <= 1'b1;
                sv <= 1'b0;
            end else begin
                out_valid <= in_valid;
            end
        end else if (in_valid && !sv) begin
            sv <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (out_ready || !out_valid) begin
            if (sv) out_data <= sd;
            else if (in_valid) out_data <= in_data;
        end else if (in_valid && !sv) begin
            sd <= in_data;
        end
    end
endmodule
