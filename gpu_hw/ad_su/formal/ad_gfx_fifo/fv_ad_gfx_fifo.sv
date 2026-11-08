// fv_ad_gfx_fifo -- ad_gfx_fifo (W 8, DEPTH 4): no loss, no duplication, order kept.  The pushed
// data are the push count; the head (q while !empty) must equal the pop count; at most DEPTH
// entries (pushes - pops), full/empty follow the count; a push while full and a pop while empty
// change nothing.
module fv_ad_gfx_fifo (
    input wire clk,
    input wire rst_n,
    input wire push,
    input wire pop
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    reg [7:0] pushes, pops;
    wire [7:0] q;
    wire full, empty;
    ad_gfx_fifo #(.W(8), .DEPTH(4)) dut (.clk(clk), .rst_n(rst_n), .push(push), .d(pushes),
        .pop(pop), .q(q), .full(full), .empty(empty));
    always @(posedge clk) begin
        if (!rst_n) begin
            pushes <= 8'd0;
            pops <= 8'd0;
        end else begin
            if (push && !full) pushes <= pushes + 8'd1;
            if (pop && !empty) pops <= pops + 8'd1;
        end
    end
    wire [7:0] n = pushes - pops;
    always @(*) if (rst_n && !init) begin
        assert (n <= 8'd4);
        assert (full == (n == 8'd4));
        assert (empty == (n == 8'd0));
        if (!empty) assert (q == pops);
    end
endmodule
