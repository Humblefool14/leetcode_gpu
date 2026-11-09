// fv_ad_ctl_spipe -- out at t + N equals in at t (valid and data), N = 6.
module fv_ad_ctl_spipe (input wire clk, input wire in_valid, input wire [3:0] in_data);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire ov; wire [3:0] od;
    ad_ctl_spipe #(.N(6), .W(4)) dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_data(in_data), .out_valid(ov), .out_data(od));
    reg [5:0] hv; reg [3:0] hd [0:5]; reg [2:0] age = 0;
    integer i;
    always @(posedge clk) begin
        hv <= rst_n ? {hv[4:0], in_valid} : 6'd0;
        hd[0] <= in_data; for (i = 1; i < 6; i = i + 1) hd[i] <= hd[i-1];
        if (age != 7) age <= age + 1'b1;
    end
    always @(*) if (rst_n) begin
        a_v: assert (ov == hv[5]);
        if (ov) a_d: assert (od == hd[5]);
    end
endmodule
