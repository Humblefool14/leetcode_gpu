// fv_ad_mem_lsu_wbe -- formal harness of the LSU store byte-enable leaf.
// Symbolic word w of the line: enabled (4 bytes) iff a selected lane's
// address falls in it; its data are the highest such lane's; 0 otherwise.
module fv_ad_mem_lsu_wbe;
    localparam NP = 8, AW = 12, LB = 32, LS = 5;
    (* anyconst *) reg [NP-1:0]    lanes;
    (* anyconst *) reg [NP*AW-1:0] addr;
    (* anyconst *) reg [NP*32-1:0] data;
    (* anyconst *) reg [2:0]       w;
    wire [LB-1:0] be; wire [LB*8-1:0] wdata;
    ad_lsu_wbe #(.NPHYS(NP), .ADDR_W(AW), .LINE_BYTES(LB), .LINE_SHIFT(LS)) dut (
        .lanes(lanes), .addr(addr), .data(data), .be(be), .wdata(wdata));
    integer i; reg hit; reg [31:0] d;
    always @(*) begin
        hit = 1'b0; d = 32'd0;
        for (i = 0; i < NP; i = i + 1)
            if (lanes[i] && addr[i*AW+2 +: LS-2] == w) begin hit = 1'b1; d = data[i*32 +: 32]; end
        assert (be[w*4 +: 4] == {4{hit}});
        assert (wdata[w*32 +: 32] == d);
    end
endmodule
