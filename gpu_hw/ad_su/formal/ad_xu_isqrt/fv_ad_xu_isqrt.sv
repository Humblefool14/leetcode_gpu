// fv_ad_xu_isqrt: the bit-by-bit square root at a reduced root width RW
// (parameter; 6 here, n of 12 bits; the XU uses RW 30): one start with a
// free n after the reset; done comes exactly RW + 1 cycles later with
// root * root <= n < (root + 1)^2 and rem == n - root * root.
module fv_ad_xu_isqrt #(parameter RW = 6) (input wire clk);
    reg init = 1'b1;
    reg started = 1'b0;
    reg [7:0] age = 8'd0;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    (* anyconst *) reg [2*RW-1:0] n;
    (* anyseq *) reg start_free;
    wire start = rst_n && !started && start_free;
    wire busy, done;
    wire [RW-1:0] root;
    wire [RW+1:0] rem;
    ad_xu_isqrt #(.RW(RW)) dut (.clk(clk), .rst_n(rst_n), .start(start), .n(n), .busy(busy),
        .done(done), .root(root), .rem(rem));
    wire [2*RW+1:0] r2 = root * root;
    wire [2*RW+1:0] r12 = (root + 1) * (root + 1);
    always @(posedge clk) begin
        if (start) started <= 1'b1;
        if (start || (started && age != 8'hFF)) age <= age + 1'b1;
    end
    always @(*) begin
        if (!init) begin
            if (done) begin
                assert (started && age == RW + 1);
                assert (r2 <= n && n < r12);
                assert (rem == n - r2);
            end
            if (started && age == RW + 1)
                assert (done);
            if (!started)
                assert (!busy && !done);
        end
    end
endmodule
