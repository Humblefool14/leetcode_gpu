// fv_ad_ram_sp_be: for a symbolic address A and byte B: a read of A returns byte B as last
// written with we[B] (read and write of one address in one cycle are not used: not checked);
// rdata holds while re is low.
module fv_ad_ram_sp_be #(parameter DEPTH = 8, parameter AW = 3, parameter NBYTES = 4) (
    input wire clk, input wire [AW-1:0] addr, input wire re, input wire [NBYTES-1:0] we,
    input wire [NBYTES*8-1:0] wdata
);
    localparam BW = (NBYTES > 1) ? $clog2(NBYTES) : 1;
    (* anyconst *) reg [AW-1:0] A;
    (* anyconst *) reg [BW-1:0] B;
    always @(*) begin assume (A < DEPTH); assume (B < NBYTES); end
    wire [NBYTES*8-1:0] rdata;
    ad_ram_sp_be #(.DEPTH(DEPTH), .AW(AW), .NBYTES(NBYTES)) dut (.clk(clk), .addr(addr), .re(re), .we(we),
        .wdata(wdata), .rdata(rdata));
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    reg sv = 1'b0; reg [7:0] sval; reg chk = 1'b0; reg [7:0] exp; reg pr = 1'b1; reg [NBYTES*8-1:0] prd;
    always @(posedge clk) begin
        chk <= re && addr == A && sv && !(|we); exp <= sval; pr <= re; prd <= rdata;
        if (we[B] && addr == A) begin sv <= 1'b1; sval <= wdata[8*B +: 8]; end
    end
    always @(*) if (!init) begin
        if (chk) assert (rdata[8*B +: 8] == exp);
        if (!pr) assert (rdata == prd);
    end
endmodule
