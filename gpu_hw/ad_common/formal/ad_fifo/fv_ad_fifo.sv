// fv_ad_fifo: one harness for every (W, DEPTH).  Control: count/empty/full match a counter
// model; a push while full and a pop while empty change nothing.  Data (width-independent):
// one pushed item, chosen by the solver (watch), is followed through the queue: it reaches the
// head exactly after the items ahead of it are popped, and is popped with its value.
module fv_ad_fifo #(parameter W = 8, parameter DEPTH = 4, parameter AW = (DEPTH > 1) ? $clog2(DEPTH) : 1) (
    input wire clk,
    input wire push, input wire pop, input wire [W-1:0] din,
    input wire watch
);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire [W-1:0] dout; wire empty, full; wire [AW:0] count;
    wire [AW:0] wp, rp; wire [DEPTH*W-1:0] mem;
    ad_fifo #(.W(W), .DEPTH(DEPTH)) dut (.clk(clk), .rst_n(rst_n), .push(push), .din(din), .pop(pop),
        .dout(dout), .empty(empty), .full(full), .count(count), .fv_wp(wp), .fv_rp(rp), .fv_mem(mem));
    // slot of the watched item: rp + ahead (mod DEPTH)
    wire [AW:0] slot = rp + ahead;
    wire do_push = push && !full, do_pop = pop && !empty;
    reg [AW:0] n;                          // model count
    reg [AW:0] ahead;                      // items in front of the watched one
    reg        armed, done;                // watching an item; it has left
    reg [W-1:0] wval;
    always @(posedge clk) begin
        if (!rst_n) begin n <= 0; armed <= 0; done <= 0; end
        else begin
            n <= n + do_push - do_pop;
            if (armed && do_pop) begin
                if (ahead == 0) begin armed <= 0; done <= 1; end
                else ahead <= ahead - 1'b1;
            end
            if (!armed && !done && watch && do_push) begin
                armed <= 1'b1; wval <= din; ahead <= n - do_pop;
            end
        end
    end
    always @(*) if (rst_n) begin
        assert (count == n);
        assert (empty == (n == 0));
        assert (full == (n == DEPTH));
        assert (n <= DEPTH);
        if (armed) assert (ahead < n);
        if (armed && ahead == 0) assert (!empty && dout == wval);
        // induction strengthening: the pointers' distance is the count, and the watched item
        // sits in its slot (makes the proof k-inductive at any DEPTH)
        assert (wp - rp == n);
        if (armed) assert (mem[slot[AW-1:0]*W +: W] == wval);
    end
    always @(*) if (rst_n) cover (done && full);
endmodule
