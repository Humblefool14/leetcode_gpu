// fv_ad_delay: out_valid(t) == in_valid(t - N) (a reference shift register), and a watched input
// comes out exactly N cycles later with its data.
module fv_ad_delay #(parameter N = 6, parameter W = 8) (
    input wire clk, input wire in_valid, input wire [W-1:0] in_data, input wire watch
);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire out_valid; wire [W-1:0] out_data;
    ad_delay #(.N(N), .W(W)) dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_data(in_data),
        .out_valid(out_valid), .out_data(out_data));
    reg [N-1:0] rv;
    reg armed; reg [W-1:0] wval; reg [7:0] age;
    always @(posedge clk) begin
        if (!rst_n) begin rv <= 0; armed <= 0; end
        else begin
            rv <= {rv, in_valid};
            if (armed) age <= age + 1'b1;
            if (armed && age == N - 1) armed <= 1'b0;
            if (!armed && watch && in_valid) begin armed <= 1'b1; wval <= in_data; age <= 0; end
        end
    end
    always @(*) if (rst_n) begin
        assert (out_valid == rv[N-1]);
        if (armed) assert (age < N);
        if (armed && age == N - 1) assert (out_valid && out_data == wval);
    end
endmodule
