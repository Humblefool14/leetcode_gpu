// fv_ad_core_fifo -- ad_su_fifo (W 2, DEPTH 4) against a reference FIFO in the harness:
// count / empty / full agree, the head is the oldest word, pushes while full and pops
// while empty are ignored.
module fv_ad_core_fifo (input wire clk, input wire push, input wire [1:0] din, input wire pop);
    reg init = 1; always @(posedge clk) init <= 0;
    wire [1:0] dout; wire empty, full; wire [2:0] count;
    ad_su_fifo #(.W(2), .DEPTH(4)) dut (.clk(clk), .rst_n(!init), .push(push), .din(din), .pop(pop), .dout(dout),
        .empty(empty), .full(full), .count(count));
    reg [1:0] q [0:3]; reg [2:0] n = 0; integer k;
    wire dp = push && n != 4, dq = pop && n != 0;
    always @(posedge clk)
        if (init) n <= 0;
        else begin
            for (k = 0; k < 3; k = k + 1) if (dq) q[k] <= q[k+1];
            if (dp) q[dq ? n - 1 : n] <= din;
            n <= n + dp - dq;
        end
    always @(*) if (!init) begin
        assert (count == n && empty == (n == 0) && full == (n == 4));
        if (n != 0) assert (dout == q[0]);
    end
endmodule
