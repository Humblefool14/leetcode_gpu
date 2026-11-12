// fv_ad_ram_1r1w: for a symbolic address A, a read of A returns the last value written to A
// before the read's cycle (read-old on a same-cycle write); rq holds while re is low.
module fv_ad_ram_1r1w #(parameter DW = 32, parameter AW = 5, parameter DEPTH = 1 << AW) (
    input wire clk, input wire we, input wire [AW-1:0] wa, input wire [DW-1:0] wd,
    input wire re, input wire [AW-1:0] ra
);
    (* anyconst *) reg [AW-1:0] A;
    always @(*) assume (A < DEPTH);
    wire [DW-1:0] rq;
    ad_ram_1r1w #(.DW(DW), .AW(AW), .DEPTH(DEPTH)) dut (.clk(clk), .we(we), .wa(wa), .wd(wd), .re(re), .ra(ra), .rq(rq));
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    reg sv = 1'b0; reg [DW-1:0] sval;          // shadow of mem[A]
    reg chk = 1'b0; reg [DW-1:0] exp; reg p_re = 1'b1; reg [DW-1:0] p_rq;
    always @(posedge clk) begin
        chk <= re && ra == A && sv; exp <= sval; p_re <= re; p_rq <= rq;
        if (we && wa == A) begin sv <= 1'b1; sval <= wd; end
    end
    always @(*) if (!init) begin
        if (chk) assert (rq == exp);
        if (!p_re) assert (rq == p_rq);
    end
endmodule
