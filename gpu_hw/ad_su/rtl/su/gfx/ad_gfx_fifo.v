// ad_gfx_fifo -- small synchronous FIFO (the am_fifo of spec ad_su_tex_ret.md §1; no am_*
// library here).  DEPTH a power of two; the head is read combinationally (q valid while
// !empty); push while full and pop while empty are ignored.
module ad_gfx_fifo #(
    parameter W = 8,
    parameter DEPTH = 4,
    parameter AW = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         push,
    input  wire [W-1:0] d,
    input  wire         pop,
    output wire [W-1:0] q,
    output wire         full,
    output wire         empty
);
    reg [W-1:0] mem [0:DEPTH-1];
    reg [AW-1:0] wp, rp;
    reg [AW:0] cnt;
    wire do_push = push && !full;
    wire do_pop = pop && !empty;

`ifdef MUT_FIFO_FULL
    assign full = 1'b0;                        // mutation: pushes while full overwrite
`else
    assign full = (cnt == DEPTH);
`endif
    assign empty = (cnt == 0);
    assign q = mem[rp];

    always @(posedge clk) begin
        if (!rst_n) begin
            wp <= {AW{1'b0}};
            rp <= {AW{1'b0}};
            cnt <= {(AW+1){1'b0}};
        end else begin
            if (do_push) wp <= wp + 1'b1;
            if (do_pop) rp <= rp + 1'b1;
            cnt <= cnt + {{AW{1'b0}}, do_push} - {{AW{1'b0}}, do_pop};
        end
    end

    always @(posedge clk) begin
        if (do_push) mem[wp] <= d;
    end
endmodule
