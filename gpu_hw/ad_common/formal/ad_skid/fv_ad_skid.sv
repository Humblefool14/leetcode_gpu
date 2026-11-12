// fv_ad_skid: occupancy model (0..2): in_ready = room, out_valid = not empty, empty flag; a
// watched accepted item leaves after the items ahead of it, with its value (in order, no loss,
// no duplicate).
module fv_ad_skid #(parameter W = 8) (
    input wire clk, input wire in_valid, input wire [W-1:0] in_data, input wire out_ready,
    input wire watch
);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire in_ready, out_valid, empty; wire [W-1:0] out_data;
    ad_skid #(.W(W)) dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_ready(in_ready),
        .in_data(in_data), .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data), .empty(empty));
    wire in_fire = in_valid && in_ready, out_fire = out_valid && out_ready;
    reg [1:0] occ; reg armed, done; reg [W-1:0] wval; reg [1:0] ahead;
    always @(posedge clk) begin
        if (!rst_n) begin occ <= 0; armed <= 0; done <= 0; end
        else begin
            occ <= occ + in_fire - out_fire;
            if (armed && out_fire) begin
                if (ahead == 0) begin armed <= 0; done <= 1; end else ahead <= ahead - 1'b1;
            end
            if (!armed && !done && watch && in_fire) begin armed <= 1; wval <= in_data; ahead <= occ - out_fire; end
        end
    end
    always @(*) if (rst_n) begin
        assert (occ <= 2);
        assert (in_ready == (occ < 2));
        assert (out_valid == (occ != 0));
        assert (empty == (occ == 0));
        if (armed) assert (ahead < occ);
        if (armed && ahead == 0) assert (out_valid && out_data == wval);
    end
    always @(*) if (rst_n) cover (done && occ == 2);
endmodule
