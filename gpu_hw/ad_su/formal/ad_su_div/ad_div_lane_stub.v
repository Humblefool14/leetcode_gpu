// ad_div_lane_stub: stands in for rtl/su/div/ad_div_lane.v in the block
// protocol proof (the arithmetic is proven in formal/ad_div_lane): takes
// start when idle, finishes after a free number of cycles (anyseq), and
// returns a fixed function of its operands so the harness can check that
// every EXEC lane's result reaches its lane of the beat.
module ad_div_lane #(parameter W = 32) (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [1:0] op,
    input wire [W-1:0] a,
    input wire [W-1:0] b,
    output wire busy,
    output reg done,
    output reg [W-1:0] res
);
    (* anyseq *) reg fin;
    reg on;
    reg [W-1:0] r;
    assign busy = on;
    always @(posedge clk) begin
        if (!rst_n) begin
            on <= 1'b0;
            done <= 1'b0;
            r <= {W{1'b0}};
            res <= {W{1'b0}};
        end else begin
            done <= 1'b0;
            if (!on) begin
                if (start) begin
                    on <= 1'b1;
                    r <= a ^ {b[W/2-1:0], b[W-1:W/2]} ^ {{(W-2){1'b0}}, op};
                end
            end else if (fin) begin
                on <= 1'b0;
                done <= 1'b1;
                res <= r;
            end
        end
    end
endmodule
