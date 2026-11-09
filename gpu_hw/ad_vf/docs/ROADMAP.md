# ad_vf feature roadmap

Proposed plan for one engineer, starting 2026-11-16. Durations include each feature's own tests and
formal harnesses. The timeline chart is in the architecture document (Feature roadmap section).

| # | Feature | Why | Effort | Target |
|---|---|---|---|---|
| 1 | Out-of-order memory and fault injection in the whole-VF test | the review ran these only in scratch benches | 1 wk | Nov 2026 |
| 2 | Close the open proofs: asm at 32 lanes, vertex cache with pdr, index data values, top line-hold model issue | BMC only or reduced today | 2 wk | Nov 2026 |
| - | **v1 sign-off** | | | 2026-11-30 |
| 3 | Overlap warps: next warp's SEND while the current warp's PRIMS drain | v1 serializes them (asm section 6) | 2 wk | Dec 2026 |
| 4 | Pipelined fetch: several attributes and line reads in flight | one attribute at a time; the spec's 4x target | 4 wk | Dec 2026 - Jan 2027 |
| 5 | Reuse index lines across instances | each instance re-reads the index buffer | 1 wk | Jan 2027 |
| 6 | Performance counters | needed to tune 3-5 | 1 wk | Jan 2027 |
| 7 | Wire in the vertex cache (ad_vf_vc) with an instance tag | skip re-shading reused vertices; needs an SU commit path | 4 wk | Jan - Feb 2027 |
| 8 | More VkFormats: USCALED/SSCALED, SRGB, RGB8, B10G11R11_UFLOAT, A2B10G10R10 SNORM/UINT | read (0, 0, 0, 1.0) today | 2 wk | Feb 2027 |
| 9 | VertexIndex, InstanceIndex, DrawID written to registers | the shader computes them today | 2 wk | Mar 2027 |
| 10 | Indirect and multi-draw | vkCmdDrawIndirect / DrawIndexedIndirect | 3 wk | Mar - Apr 2027 |
| 11 | Adjacency and patch-list topologies | VkPrimitiveTopology 6-10 | 3 wk | Apr 2027 |

Later candidates: more than one warp in flight to the SU, a shared attribute cache across warps,
more than one VF memory client for wide configurations.
