// fv_ad_xu_divider: the XU's restoring divider at a reduced width (DW 6,
// up to 8 quotient bits; the XU uses DW 30 with 28/29 steps): one start
// with free r0 < d and steps 1..QW after the reset; done comes exactly
// steps + 1 cycles later with q * d + r == r0 << steps and r < d.
module fv_ad_xu_divider #(parameter DW = 6, parameter QW = 8, parameter CW = 4) (input wire clk);
    reg init = 1'b1;
    reg started = 1'b0;
    reg [7:0] age = 8'd0;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    (* anyconst *) reg [DW-1:0] r0, d;
    (* anyconst *) reg [CW-1:0] steps;
    (* anyseq *) reg start_free;
    always @(*) begin
        assume (r0 < d);
        assume (steps >= 1 && steps <= QW);
    end
    wire start = rst_n && !started && start_free;
    wire busy, done;
    wire [QW-1:0] q;
    wire [DW-1:0] r;
    ad_xu_divider #(.DW(DW), .QW(QW), .CW(CW)) dut (.clk(clk), .rst_n(rst_n), .start(start),
        .r0(r0), .d(d), .steps(steps), .busy(busy), .done(done), .q(q), .r(r));
    wire [DW+QW+1:0] lhs = q * d + r;
    wire [DW+QW+1:0] rhs = {{(QW+2){1'b0}}, r0} << steps;
    always @(posedge clk) begin
        if (start) started <= 1'b1;
        if (start || (started && age != 8'hFF)) age <= age + 1'b1;
    end
    // running invariant (strengthens the induction): after k = age - 1
    // steps, q * d + r == r0 << k and r < d
    wire [DW+QW+1:0] rk = {{(QW+2){1'b0}}, r0} << (age - 1);
    always @(*) begin
        if (!init) begin
            if (started && busy && age >= 1) begin
                assert (age <= steps);
                assert (r < d);
                assert (q * d + r == rk);
            end
            if (done) begin
                assert (started && age == steps + 1);
                assert (lhs == rhs);
                assert (r < d);
            end
            if (started && age == steps + 1)
                assert (done);
            if (!started)
                assert (!busy && !done);
        end
    end
endmodule
