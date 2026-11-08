// fv_ad_mem_lsu_coalesce -- formal harness of the LSU coalescer leaf.
// Free pending mask and lane addresses (anyconst).  Properties: any = some
// lane pending; the chosen line is the first pending lane's line (so a
// pending lane's line); every pending lane in that line is chosen and no lane
// outside it (nor a lane that is not pending).
module fv_ad_mem_lsu_coalesce;
    localparam NP = 8, AW = 12, LS = 5;
    (* anyconst *) reg [NP-1:0]    pend;
    (* anyconst *) reg [NP*AW-1:0] addr;
    wire any; wire [AW-LS-1:0] line; wire [NP-1:0] lanes;
    ad_lsu_coalesce #(.NPHYS(NP), .ADDR_W(AW), .LINE_SHIFT(LS)) dut (
        .pend(pend), .addr(addr), .any(any), .line(line), .lanes(lanes));
    integer i, j;
    reg first_ok;
    always @(*) begin
        a_any: assert (any == (|pend));
        for (i = 0; i < NP; i = i + 1) begin
            // served iff pending and in the chosen line
            assert (lanes[i] == (pend[i] && addr[i*AW+LS +: AW-LS] == line));
            // the first pending lane is served (its line is the chosen one)
            first_ok = pend[i];
            for (j = 0; j < i; j = j + 1) if (pend[j]) first_ok = 1'b0;
            if (first_ok) assert (lanes[i]);
        end
        if (any) assert (|lanes);
    end
endmodule
