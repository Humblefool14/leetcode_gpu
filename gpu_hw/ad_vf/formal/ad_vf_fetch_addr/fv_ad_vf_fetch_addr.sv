// fv_ad_vf_fetch_addr -- address leaf against a reference written independently:
//   offset = stride * elem computed in 64 bits (no truncation in the reference)
//   addr = base + offset mod 2^32, end49 = offset + size (49 bits, exact: offset < 2^48),
//   line0/line1 = first/last byte's line (mod 2^ADDR_W), two = they differ, off = addr's low bits.
// size is 1..16 (the formats').  Note: Yosys normalises both products to the same $mul and merges
// them, so the product equality is closed by synthesis; the line / limit / wrap logic is SAT-checked.  Combinational: inputs anyconst.  LS = 5 (32-byte lines) or 6.
module fv_ad_vf_fetch_addr #(parameter LS = 5) (input wire clk);
    localparam AW = 32, LW = AW - LS;
    (* anyconst *) reg [31:0] base;
    (* anyconst *) reg [15:0] stride;
    (* anyconst *) reg [31:0] elem;
    (* anyconst *) reg [4:0]  size;
    always @(*) assume (size >= 5'd1 && size <= 5'd16);
    wire [31:0] addr; wire [48:0] end49; wire [LW-1:0] line0, line1; wire two; wire [LS-1:0] off;
    ad_vf_fetch_addr #(.ADDR_W(AW), .LINE_SHIFT(LS)) dut (.base(base), .stride(stride), .elem(elem), .size(size),
        .addr(addr), .end49(end49), .line0(line0), .line1(line1), .two(two), .off(off));
    // one state bit so that ABC accepts the (otherwise combinational) network
    reg tick = 1'b0, tock = 1'b0;
    always @(posedge clk) begin tick <= ~tick; tock <= tick; end
    always @(*) a_seq: assert (!(tick && tock));
    // reference product in 64 bits (the RTL's is 16 x 32 -> 48 bits)
    wire [63:0] r_off = {48'd0, stride} * {32'd0, elem};
    wire [31:0] r_addr = base + r_off[31:0];
    wire [31:0] r_last = r_addr + {27'd0, size} - 32'd1;
    always @(*) begin
        a_addr:  assert (addr  == r_addr);
        a_end:   assert ({15'd0, end49} == r_off + {59'd0, size});
        a_l0:    assert (line0 == r_addr[AW-1:LS]);
        a_l1:    assert (line1 == r_last[AW-1:LS]);
        a_two:   assert (two == (r_addr[AW-1:LS] != r_last[AW-1:LS]));
        a_off:   assert (off == r_addr[LS-1:0]);
        c_two:   cover (two && tick);
    end
endmodule
