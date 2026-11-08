// ad_xu_engine_stub: stands in for rtl/su/xu/ad_xu_engine.v in the block
// protocol proof (the arithmetic is checked bit for bit in simulation and
// its iteration leaves in formal/ad_xu_isqrt, formal/ad_xu_divider): takes
// start when idle, finishes after a free number of cycles (anyseq) and
// returns a fixed function of its operand.
module ad_xu_engine (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [2:0] op,
    input wire [31:0] x,
    output wire busy,
    output reg done,
    output reg [31:0] y
);
    (* anyseq *) reg fin;
    reg on;
    reg [31:0] r;
    assign busy = on;
    always @(posedge clk) begin
        if (!rst_n) begin
            on <= 1'b0;
            done <= 1'b0;
            r <= 32'd0;
            y <= 32'd0;
        end else begin
            done <= 1'b0;
            if (!on) begin
                if (start) begin
                    on <= 1'b1;
                    r <= {x[15:0], x[31:16]} ^ {29'd0, op};
                end
            end else if (fin) begin
                on <= 1'b0;
                done <= 1'b1;
                y <= r;
            end
        end
    end
endmodule
