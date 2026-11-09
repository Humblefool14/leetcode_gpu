// fv_ad_vf_idx_restart -- restart marker iff PRIM_RESTART[0] and the index is all ones for its
// size (u16 0xFFFF zero-extended, u32 0xFFFFFFFF); spec section 4.
module fv_ad_vf_idx_restart (input wire clk);
    (* anyconst *) reg [31:0] idx;
    (* anyconst *) reg u32, en;
    wire hit;
    ad_vf_idx_restart dut (.idx(idx), .u32(u32), .en(en), .hit(hit));
    always @(*) begin
        if (!u32) assume (idx[31:16] == 16'd0);          // a u16 index is zero-extended
        a_hit: assert (hit == (en && (u32 ? (&idx) : (&idx[15:0]))));
    end
endmodule
