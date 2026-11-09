// ad_vf_idx_restart -- primitive restart compare (spec/gpu/vf/ad_vf_index.md section 4):
// with PRIM_RESTART[0], 0xFFFF (u16, zero-extended) or 0xFFFFFFFF (u32) is a restart marker.
// Only indexed draws restart (the parent passes en = PRIM_RESTART[0] && indexed).
module ad_vf_idx_restart (
    input  wire [31:0] idx,
    input  wire        u32,
    input  wire        en,
    output wire        hit
);
`ifdef MUT_IDX_RESTART_U16
    assign hit = en && (idx == 32'hFFFFFFFF);            // mutation: u16 restart never detected
`else
    assign hit = en && (u32 ? (idx == 32'hFFFFFFFF) : (idx == 32'h0000FFFF));
`endif
endmodule
