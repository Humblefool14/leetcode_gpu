// fv_ad_popcount: equal to a reference written another way (clear the lowest set bit until zero).
module fv_ad_popcount #(parameter W = 32, parameter OW = $clog2(W + 1)) (input wire [W-1:0] in);
    wire [OW-1:0] count;
    ad_popcount #(.W(W)) dut (.in(in), .count(count));
    reg [W-1:0] x; reg [OW-1:0] r; integer i;
    always @(*) begin
        x = in; r = 0;
        for (i = 0; i < W; i = i + 1) if (x != 0) begin x = x & (x - 1'b1); r = r + 1'b1; end
    end
    always @(*) assert (count == r);
endmodule
