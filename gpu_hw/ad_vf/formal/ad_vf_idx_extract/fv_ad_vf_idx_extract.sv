// fv_ad_vf_idx_extract -- the index at byte offset off of a line, byte by byte (little endian,
// u16 zero-extended), for LINE_BYTES 32 (tasks bmc / prove) and 64 (bmc64 / prove64).
// The offset is aligned to the index size (INDEX_BASE aligned, spec section 4).
module fv_ad_vf_idx_extract #(
    parameter LB = 32,
    parameter LS = 5
) (input wire clk);
    (* anyconst *) reg [LB*8-1:0] line;
    (* anyconst *) reg [LS-1:0]   off;
    (* anyconst *) reg            u32;
    wire [31:0] idx;
    ad_vf_idx_extract #(.LINE_BYTES(LB), .LINE_SHIFT(LS)) dut (.line(line), .off(off), .u32(u32), .idx(idx));
    reg [7:0] b0, b1, b2, b3; integer k;
    always @(*) begin
        b0 = 8'd0; b1 = 8'd0; b2 = 8'd0; b3 = 8'd0;
        for (k = 0; k < LB; k = k + 1) begin
            if (k == off)     b0 = line[8*k +: 8];
            if (k == off + 1) b1 = line[8*k +: 8];
            if (k == off + 2) b2 = line[8*k +: 8];
            if (k == off + 3) b3 = line[8*k +: 8];
        end
        assume (u32 ? (off[1:0] == 2'b00) : (off[0] == 1'b0));
        a_idx: assert (idx == (u32 ? {b3, b2, b1, b0} : {16'd0, b1, b0}));
    end
endmodule
