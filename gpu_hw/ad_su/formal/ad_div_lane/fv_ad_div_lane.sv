// fv_ad_div_lane: one lane's divide, end to end, at a reduced width W
// (parameter, 8 here): one start with free a, b, op after the reset; done
// comes exactly W + 2 cycles later, once, with the RISC-V result
// (div/divu/rem/remu, /0 and INT_MIN/-1), and busy until then.
module fv_ad_div_lane #(parameter W = 8) (input wire clk);
    reg init = 1'b1;
    reg started = 1'b0;
    reg [7:0] age = 8'd0;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    (* anyconst *) reg [1:0] op;
    (* anyconst *) reg [W-1:0] a, b;
    (* anyseq *) reg start_free;
    wire start = rst_n && !started && start_free;
    wire busy, done;
    wire [W-1:0] res;
    ad_div_lane #(.W(W)) dut (.clk(clk), .rst_n(rst_n), .start(start), .op(op), .a(a), .b(b),
        .busy(busy), .done(done), .res(res));
    reg [W-1:0] refv;
    always @(*) begin
        if (b == 0)
            refv = op[1] ? a : {W{1'b1}};
        else if (!op[0] && a == {1'b1, {(W-1){1'b0}}} && b == {W{1'b1}})
            refv = op[1] ? {W{1'b0}} : a;
        else case (op)
            2'd0: refv = $signed(a) / $signed(b);
            2'd1: refv = a / b;
            2'd2: refv = $signed(a) % $signed(b);
            default: refv = a % b;
        endcase
    end
    always @(posedge clk) begin
        if (start) started <= 1'b1;
        if (start || (started && age != 8'hFF)) age <= age + 1'b1;
    end
    always @(*) begin
        if (!init) begin
            if (done) begin
                assert (started && age == W + 2);
                assert (res == refv);
            end
            if (started && age == W + 2)
                assert (done);
            if (started && age > 0 && age < W + 2)
                assert (busy);
            if (!started)
                assert (!busy && !done);
        end
    end
endmodule
