// fv_ad_su_scrub -- ad_su_scrub (DEPTH 12, not a power of two): after a start, on
// is 1 for exactly DEPTH cycles with a = 0, 1, ... DEPTH-1 (a start while on begins
// again), then 0; never on without a start since reset.
module fv_ad_su_scrub (input wire clk, input wire start);
    localparam DEPTH = 12;
    reg init = 1;
    always @(posedge clk) init <= 0;
    wire on; wire [3:0] a;
    ad_su_scrub #(.DEPTH(DEPTH)) dut (.clk(clk), .rst_n(!init), .start(start), .on(on), .a(a));
    reg [4:0] n = 0;     // cycles since the last start (saturating at DEPTH)
    reg any = 0;
    always @(posedge clk)
        if (init) begin n <= DEPTH; any <= 0; end
        else if (start) begin n <= 0; any <= 1; end
        else if (n < DEPTH) n <= n + 1;
    always @(*) if (!init) begin
        assert (on == (any && n < DEPTH));
        if (on) assert (a == n);
    end
endmodule
