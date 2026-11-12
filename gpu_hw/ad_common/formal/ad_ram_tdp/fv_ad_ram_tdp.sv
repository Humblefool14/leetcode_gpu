// fv_ad_ram_tdp: for a symbolic address A: a port-A read (read-first) or port-B read of A
// returns the value of mem[A] before the cycle's write; rdata holds while en is low.
module fv_ad_ram_tdp #(parameter DEPTH = 16, parameter AW = 4, parameter DW = 32) (
    input wire clk, input wire a_en, input wire a_we, input wire [AW-1:0] a_addr, input wire [DW-1:0] a_wdata,
    input wire b_en, input wire [AW-1:0] b_addr
);
    (* anyconst *) reg [AW-1:0] A;
    always @(*) assume (A < DEPTH);
    wire [DW-1:0] a_rdata, b_rdata;
    ad_ram_tdp #(.DEPTH(DEPTH), .AW(AW), .DW(DW)) dut (.clk(clk), .a_en(a_en), .a_we(a_we), .a_addr(a_addr),
        .a_wdata(a_wdata), .a_rdata(a_rdata), .b_en(b_en), .b_addr(b_addr), .b_rdata(b_rdata));
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    reg sv = 1'b0; reg [DW-1:0] sval;
    reg ca = 1'b0, cb = 1'b0; reg [DW-1:0] exp;
    reg pa = 1'b1, pb = 1'b1; reg [DW-1:0] pra, prb;
    always @(posedge clk) begin
        ca <= a_en && a_addr == A && sv; cb <= b_en && b_addr == A && sv; exp <= sval;
        pa <= a_en; pb <= b_en; pra <= a_rdata; prb <= b_rdata;
        if (a_en && a_we && a_addr == A) begin sv <= 1'b1; sval <= a_wdata; end
    end
    always @(*) if (!init) begin
        if (ca) assert (a_rdata == exp);
        if (cb) assert (b_rdata == exp);
        if (!pa) assert (a_rdata == pra);
        if (!pb) assert (b_rdata == prb);
    end
endmodule
