// ad_su_fifo -- synchronous FIFO, DEPTH a power of two (leaf of ad_su_wb and
// ad_su_pipe).  push while full is ignored (the parent reports it); pop while
// empty is ignored.  dout is the head (valid while !empty).  Pointers reset;
// storage is datapath.
module ad_su_fifo #(
    parameter W     = 8,
    parameter DEPTH = 4,
    parameter AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         push,
    input  wire [W-1:0] din,
    input  wire         pop,
    output wire [W-1:0] dout,
    output wire         empty,
    output wire         full,
    output wire [AW:0]  count
);
    reg [W-1:0] mem [0:DEPTH-1];
    reg [AW:0]  wp, rp;
    wire do_push = push && !full;
    wire do_pop  = pop && !empty;
    assign count = wp - rp;
    assign empty = wp == rp;
    assign full  = count == DEPTH[AW:0];
    assign dout  = mem[rp[AW-1:0]];
    always @(posedge clk) begin
        if (!rst_n) begin
            wp <= 0;
            rp <= 0;
        end else begin
            if (do_push) wp <= wp + 1'b1;
            if (do_pop)  rp <= rp + 1'b1;
        end
        if (do_push) mem[wp[AW-1:0]] <= din;
    end
endmodule
