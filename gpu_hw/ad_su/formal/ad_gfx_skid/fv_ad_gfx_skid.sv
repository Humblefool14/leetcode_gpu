// fv_ad_gfx_skid -- ad_gfx_skid (W 8): no loss, no duplication, order kept.  The pushed data are
// the push count (in_data = number of accepted pushes); every popped datum must equal the pop
// count, so each accepted datum leaves exactly once and in order.  At most two in flight,
// out_valid whenever one is, in_ready unless two are (registered: no path from out_ready), the
// output held while out_valid && !out_ready.
module fv_ad_gfx_skid (
    input wire clk,
    input wire rst_n,
    input wire in_valid,
    input wire out_ready
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    reg [7:0] pushes, pops;
    wire in_ready, out_valid, empty;
    wire [7:0] out_data;
    ad_gfx_skid #(.W(8)) dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_ready(in_ready),
        .in_data(pushes), .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .empty(empty));
    always @(posedge clk) begin
        if (!rst_n) begin
            pushes <= 8'd0;
            pops <= 8'd0;
        end else begin
            if (in_valid && in_ready) pushes <= pushes + 8'd1;
            if (out_valid && out_ready) pops <= pops + 8'd1;
        end
    end
    wire [7:0] infl = pushes - pops;
    reg pv; reg [7:0] pd;
    always @(posedge clk) begin
        pv <= rst_n && out_valid && !out_ready;
        pd <= out_data;
    end
    always @(*) if (rst_n && !init) begin
        assert (infl <= 8'd2);
        assert (out_valid == (infl != 8'd0));
        assert (in_ready == (infl != 8'd2));
        if (out_valid) assert (out_data == pops);
        assert (empty == (infl == 8'd0));
        if (pv) assert (out_valid && out_data == pd);
    end
endmodule
