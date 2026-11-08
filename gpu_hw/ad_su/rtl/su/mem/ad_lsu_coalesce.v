// ad_lsu_coalesce -- the LSU's coalescer (spec ad_su_lsu.md §4, design §3.5).
// Combinational.  From the pending lanes and their byte addresses: the line of
// the first (lowest) pending lane, and every pending lane whose address is in
// that line.  any = 0 when no lane is pending (line and lanes 0 then).
module ad_lsu_coalesce #(
    parameter NPHYS      = 8,
    parameter ADDR_W     = 32,
    parameter LINE_SHIFT = 5
) (
    input  wire [NPHYS-1:0]           pend,
    input  wire [NPHYS*ADDR_W-1:0]    addr,
    output reg                        any,
    output reg  [ADDR_W-LINE_SHIFT-1:0] line,
    output reg  [NPHYS-1:0]           lanes
);
    integer i;
    always @(*) begin
        any  = |pend;
        line = {(ADDR_W-LINE_SHIFT){1'b0}};
        for (i = NPHYS - 1; i >= 0; i = i - 1)
            if (pend[i]) line = addr[i*ADDR_W+LINE_SHIFT +: ADDR_W-LINE_SHIFT];
        for (i = 0; i < NPHYS; i = i + 1)
`ifdef MUT_CO_ALL
            lanes[i] = pend[i];
`else
            lanes[i] = pend[i] && (addr[i*ADDR_W+LINE_SHIFT +: ADDR_W-LINE_SHIFT] == line);
`endif
    end
endmodule
