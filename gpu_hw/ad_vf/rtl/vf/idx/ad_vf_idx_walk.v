// ad_vf_idx_walk -- two-level walk counter of ad_vf_index: n = 0..cnt_n-1 inside instance
// i = 0..cnt_i-1 (spec section 4: the whole walk repeated for every instance).  load starts a walk
// (cnt_n, cnt_i >= 1; the parent does not load with a zero count); step advances; last on the
// final (n, i); active until the step taken on last.  Used for the emitted items and for the
// index-buffer lines requested.
module ad_vf_idx_walk #(
    parameter W = 32
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         load,
    input  wire [W-1:0] cnt_n,
    input  wire [W-1:0] cnt_i,
    input  wire         step,
    output reg  [W-1:0] n,
    output reg  [W-1:0] i,
    output reg          active,
    output wire         last_n,
    output wire         last
);
    reg [W-1:0] mn, mi;          // cnt - 1
    assign last_n = (n == mn);
    assign last   = last_n && (i == mi);
    always @(posedge clk) begin
        if (!rst_n) begin
            n <= {W{1'b0}}; i <= {W{1'b0}}; mn <= {W{1'b0}}; mi <= {W{1'b0}}; active <= 1'b0;
        end else if (load) begin
            n <= {W{1'b0}}; i <= {W{1'b0}}; mn <= cnt_n - 1'b1; mi <= cnt_i - 1'b1; active <= 1'b1;
        end else if (step && active) begin
            if (last) active <= 1'b0;
            else if (last_n) begin n <= {W{1'b0}}; i <= i + 1'b1; end
            else n <= n + 1'b1;
        end
    end
endmodule
