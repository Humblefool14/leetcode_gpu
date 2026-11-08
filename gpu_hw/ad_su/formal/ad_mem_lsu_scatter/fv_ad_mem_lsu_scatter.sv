// fv_ad_mem_lsu_scatter -- formal harness of the LSU scatter leaf.
// Symbolic lane l: its word is the line's word at its address bits
// [LINE_SHIFT-1:2] (a shift of the line), 0 on error or when not selected.
module fv_ad_mem_lsu_scatter;
    localparam NP = 8, AW = 12, LB = 32, LS = 5;
    (* anyconst *) reg [LB*8-1:0]  rdata;
    (* anyconst *) reg             error;
    (* anyconst *) reg [NP*AW-1:0] addr;
    (* anyconst *) reg [NP-1:0]    lanes;
    (* anyconst *) reg [2:0]       l;
    wire [NP*32-1:0] words;
    ad_lsu_scatter #(.NPHYS(NP), .ADDR_W(AW), .LINE_BYTES(LB), .LINE_SHIFT(LS)) dut (
        .rdata(rdata), .error(error), .addr(addr), .lanes(lanes), .words(words));
    wire [AW-1:0] la = addr[l*AW +: AW];
    wire [LB*8-1:0] sh = rdata >> {la[LS-1:2], 5'd0};
    always @(*) begin
        if (lanes[l] && !error) assert (words[l*32 +: 32] == sh[31:0]);
        else assert (words[l*32 +: 32] == 32'd0);
    end
endmodule
