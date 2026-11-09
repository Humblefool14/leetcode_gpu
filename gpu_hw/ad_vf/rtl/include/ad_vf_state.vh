// ad_vf_state.vh: STATE indices and fields used by the vertex fetcher (ad_vf).
//
// The design document's STATE table (design section 2.3) was not provided.  The specs give the
// VF ranges (0x020-0x04F, 0x1C0-0x1CF), the words read at kick (0x021-0x027), ATTR_LIMIT at
// 0x1D0 + k and PROVOKING at RX 0x05D.  Every other index and field position below is
// ASSUMED (marked) and recorded in docs/ARCHITECTURE.md.
`ifndef AD_VF_STATE_VH
`define AD_VF_STATE_VH

`define AD_S_TOPOLOGY        9'h020  // ASSUMED. [2:0] Vulkan VkPrimitiveTopology 0..5; 6, 7 reserved (points)
`define AD_S_INDEX_BASE      9'h021  // ASSUMED. byte address of the index buffer, aligned to the index size
`define AD_S_INDEX_FORMAT    9'h022  // ASSUMED. [1:0] 0 non-indexed, 1 u16, 2 u32, 3 reserved (= u32)
`define AD_S_FIRST           9'h023  // ASSUMED. firstVertex (non-indexed) / firstIndex (indexed)
`define AD_S_COUNT           9'h024  // ASSUMED. vertexCount / indexCount
`define AD_S_FIRST_INSTANCE  9'h025  // ASSUMED.
`define AD_S_INSTANCE_COUNT  9'h026  // ASSUMED.
`define AD_S_VERTEX_OFFSET   9'h027  // ASSUMED. added (mod 2^32) to the index of an indexed draw
`define AD_S_PRIM_RESTART    9'h028  // ASSUMED. [0] primitive restart enable

// Attribute k = 0..15
`define AD_S_ATTR_BASE(k)    (9'h030 + 9'd2*(k))   // ASSUMED. byte address of element 0
`define AD_S_ATTR_DESC(k)    (9'h031 + 9'd2*(k))   // ASSUMED. fields below
`define AD_S_ATTR_DST(k)     (9'h1C0 + (k))        // ASSUMED (in the VF range 0x1C0-0x1CF). fields below
`define AD_S_ATTR_LIMIT(k)   (9'h1D0 + (k))        // spec: [31] enable, [30:0] byte limit

`define AD_S_PROVOKING       9'h05D  // spec (RX STATE): [0] 0 first vertex, 1 last vertex

// ATTR_DESC[k] fields (ASSUMED except [19:16], [20], [31:24] named by the specs)
`define AD_DESC_STRIDE       15:0    // byte stride
`define AD_DESC_FMT          19:16   // legacy format (AD_LF_*)
`define AD_DESC_INST         20      // 1 per-instance
`define AD_DESC_DIV          31:24   // instance divisor (0: every instance reads FIRST_INSTANCE's)

// ATTR_DST[k] fields: the attribute is enabled when the whole word is not 0
`define AD_DST_REG           5:0     // first register
`define AD_DST_CNT           7:6     // components - 1
`define AD_DST_VKFMT         31:24   // VkFormat (0: use ATTR_DESC's legacy format)

// Legacy formats, ATTR_DESC[19:16] (ASSUMED codes; sizes 4/8/12/16 and fp16 = 6, 7 per the specs)
`define AD_LF_R32F      4'd0   // 4 bytes, 1 comp, float
`define AD_LF_RG32F     4'd1   // 8, 2, float
`define AD_LF_RGB32F    4'd2   // 12, 3, float
`define AD_LF_RGBA32F   4'd3   // 16, 4, float
`define AD_LF_R32UI     4'd4   // 4, 1, uint
`define AD_LF_RG32UI    4'd5   // 8, 2, uint
`define AD_LF_RG16F     4'd6   // 4, 2, fp16 -> fp32
`define AD_LF_RGBA16F   4'd7   // 8, 4, fp16 -> fp32
`define AD_LF_RGBA8UN   4'd8   // 4, 4, unorm8 -> float
`define AD_LF_RGBA8UI   4'd9   // 4, 4, uint8 -> int
// 10..15 reserved: read 4 bytes, no data components (all filled 0, 0, 0, 1.0)

`endif
