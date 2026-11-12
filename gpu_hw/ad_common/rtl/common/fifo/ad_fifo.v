// ad_fifo -- synchronous FIFO, show-ahead (common library).
//   DEPTH must be a power of two (>= 2).  push while full is ignored (the parent
//   reports it if it cares); pop while empty is ignored.  dout is the head, valid
//   while !empty; count = number of entries (0..DEPTH).  Pointers reset; the
//   storage is datapath (not reset).  push and pop in one cycle on a non-empty,
//   non-full FIFO do both.
//   Replaces ad_su_fifo (ad_su) and ad_gfx_fifo (ad_su, ports d/q).
module ad_fifo #(
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
`ifdef AD_FV_FIFO
    // formal-only observation ports (formal/ad_fifo: induction invariants)
    ,output wire [AW:0]          fv_wp
    ,output wire [AW:0]          fv_rp
    ,output wire [DEPTH*W-1:0]   fv_mem
`endif
);
    // synopsys translate_off
    initial if (DEPTH < 2 || (1 << AW) != DEPTH) $error("ad_fifo: DEPTH must be a power of two >= 2");
    // synopsys translate_on
    reg [W-1:0] mem [0:DEPTH-1];
    reg [AW:0]  wp, rp;
    wire do_push = push && !full;
    wire do_pop  = pop && !empty;
    assign count = wp - rp;
    assign empty = wp == rp;
`ifdef MUT_FIFO_NOFULL
    assign full  = 1'b0;                          // mutation: a push while full overwrites
`else
    assign full  = count == DEPTH[AW:0];
`endif
    assign dout  = mem[rp[AW-1:0]];
`ifdef AD_FV_FIFO
    assign fv_wp = wp; assign fv_rp = rp;
    genvar g;
    generate for (g = 0; g < DEPTH; g = g + 1) begin : g_fv
        assign fv_mem[g*W +: W] = mem[g];
    end endgenerate
`endif
    always @(posedge clk) begin
        if (!rst_n) begin
            wp <= {(AW+1){1'b0}};
            rp <= {(AW+1){1'b0}};
        end else begin
            if (do_push) wp <= wp + 1'b1;
            if (do_pop)  rp <= rp + 1'b1;
        end
        if (do_push) mem[wp[AW-1:0]] <= din;
    end
endmodule
