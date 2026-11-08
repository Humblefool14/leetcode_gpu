// fv_ad_mem_tdpram -- formal harness of the two-port RAM leaf.  Symbolic
// address x with a shadow of its word (initialised from the first read):
// port A reads return the word before the write of the same cycle
// (read-first), port B reads the stored word, both one cycle later.
module fv_ad_mem_tdpram (
    input wire clk,
    input wire a_en, input wire a_we, input wire [1:0] a_addr, input wire [7:0] a_wdata,
    input wire b_en, input wire [1:0] b_addr
);
    wire [7:0] a_rdata, b_rdata;
    ad_mem_tdpram #(.DEPTH(4), .AW(2), .DW(8)) dut (
        .clk(clk), .a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata), .a_rdata(a_rdata),
        .b_en(b_en), .b_addr(b_addr), .b_rdata(b_rdata));
    (* anyconst *) reg [1:0] x;
    reg [7:0] sh; reg known = 1'b0;
    reg pa = 1'b0, pb = 1'b0; reg [7:0] ea, eb;
    always @(posedge clk) begin
        pa <= a_en && a_addr == x && known;
        pb <= b_en && b_addr == x && known;
        ea <= sh; eb <= sh;
        if (a_en && a_we && a_addr == x) begin sh <= a_wdata; known <= 1'b1; end
        if (pa) assert (a_rdata == ea);
        if (pb) assert (b_rdata == eb);
    end
endmodule
