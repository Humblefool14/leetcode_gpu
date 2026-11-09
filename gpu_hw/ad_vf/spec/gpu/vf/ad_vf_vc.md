# ad_vf_vc

RTL: `rtl/gpu/vf/ad_vf_vc.v`. Parent: `ad_vf`. Implemented in: Phase 033.

## 1. Purpose and place

The Post-Transform Vertex Cache (PT-VC) eliminates redundant vertex shader executions for shared vertices in indexed meshes (e.g. triangles sharing vertices).
It maintains a 32-entry fully-associative cache of transformed vertex clip positions and varying attributes.
When an incoming index matches a cached entry, the vertex shader invocation is bypassed and the cached vertex attributes are directly routed, achieving 0-cycle shading latency for reused vertices.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NENTRIES` | 32 | Number of cache entries (fully associative). |
| `VDATA_W` | 512 | Shaded vertex data width (clip position + varyings). |
| `SLOT_W` | 5 | Slot index width (log2(`NENTRIES`)). |

## 3. Ports

Clock/reset domain: `clk`. Synchronous reset `rst_n` (active low).

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous active-low reset. |
| `flush` | in | 1 | Synchronous cache invalidate (e.g. draw call kick). |
| **Lookup Port** | | | |
| `lookup_valid` | in | 1 | Index lookup query valid. |
| `lookup_index` | in | 32 | Vertex index to search in CAM. |
| `hit` | out | 1 | High when `lookup_index` exists in a valid cache entry. |
| `hit_vdata` | out | VDATA_W | Transformed vertex data associated with the hit entry. |
| `hit_slot` | out | SLOT_W | Matching cache slot index. |
| **Commit Port** | | | |
| `commit_valid` | in | 1 | Shader completion commit valid. |
| `commit_index` | in | 32 | Shaded vertex index to register. |
| `commit_vdata` | in | VDATA_W | Shaded vertex attribute payload. |

## 4. Behaviour

- **CAM Lookup**: 32 entries are checked in parallel combinationally against `lookup_index`. If a valid entry matches, `hit` asserts immediately (0-cycle combinational response) along with `hit_vdata` and `hit_slot`.
- **Commit**: When the shader completes a vertex, `commit_valid` writes the index and payload into the cache. If the index is already present, its entry is updated. Otherwise, an unused entry is allocated, or the FIFO victim pointer entry is replaced.
- **Flush**: Asserting `flush` invalidates all entries and resets the victim pointer to 0.

## 5. Latency and Throughput

- **Lookup latency**: 0 cycles (combinational CAM).
- **Throughput**: 1 lookup per cycle sustained.
- **Vertex reuse benefit**: 50% to 75% reduction in vertex shader workload on typical indexed triangle meshes.

## 6. Status

Implemented in Phase 033 (2026-10-27). Verified with `sim/tb/ad_vf_vc_tb.v`.

## 10. Status

2026-11-09 (rebuild in /home/claude/ad_vf, rtl/vf/ad_vf_vc.v; this spec had no sections 7-10, the status is added here).  Leaves in rtl/vf/vc/: `ad_vf_vc_match` (CAM compare, one per port), `ad_vf_vc_penc` (lowest-set-bit priority encoder: hit slot, lowest unused entry), `ad_vf_vc_victim` (FIFO victim pointer).  TB `sim/tb/ad_vf_vc_tb.v` against an in-TB reference model written another way (allocation-order list), 80,000 random cycles; it prints (no section 8 in this spec, lines chosen here) `PASS ad_vf_vc.lookup` (directed: lookup_valid 0, same-cycle lookup + commit, update, flush + commit), `PASS ad_vf_vc.commit` (hits, updates, allocation within capacity), `PASS ad_vf_vc.replace` (FIFO replacement), `PASS ad_vf_vc.flush` (random flushes), `PASS ad_vf_vc`; passes with the defaults (32, 512, 5) and with (4, 16, 2) and (5, 32, 3).  Formal (NENTRIES 4 / 5 / 8, VDATA_W 4, 32-bit index): reference-model equivalence of hit / hit_slot / hit_vdata, no two valid entries with the same index, hit iff a valid entry matches, flush empties and zeroes the pointer: proven by k-induction (smtbmc z3) with DUT == model helper invariants; abc pdr does not converge on the 32-bit tags (task prove_pdr_open).  Mutation MUT_VC_NOUPD (a present index allocated again): TB and formal FAIL.
ASSUMPTION: hit = lookup_valid && a valid entry holds lookup_index; hit_slot and hit_vdata are 0 when there is no hit.
ASSUMPTION: a lookup and a commit (or flush) in the same cycle: the lookup sees the cache as it was at the start of the cycle (no bypass).  A lookup of the index being committed misses if the index is new and returns the old data if it is an update; the commit is visible from the next cycle.
ASSUMPTION: flush and commit_valid in the same cycle: the flush wins and the commit is dropped (the entry would belong to the previous draw).
ASSUMPTION: a commit of an index already present updates its data in place: same slot, same FIFO position, the victim pointer does not move.
ASSUMPTION: a new index takes the lowest unused entry; only when all entries are valid is the entry the victim pointer names replaced, and only then does the pointer advance (NENTRIES-1 wraps to 0).  Since entries are only invalidated all at once (flush, reset), entries fill 0, 1, 2 ... and the pointer always names the oldest allocation (true FIFO).
ASSUMPTION: NENTRIES <= 2^SLOT_W (any NENTRIES >= 2, not only powers of two); reset clears the valid bits and the pointer, tags and data are not reset (qualified by valid).
