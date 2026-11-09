# ad_su_exp_mesh

RTL: `rtl/su/ad_su_exp_mesh.v` (new).  Parent: ad_su_exp.  Children: `ad_gfx_skid` (rtl/su/gfx/).  Implemented in: ws004-p002.

## 1. Purpose and place

The meshlet export sequencer (ws004-p002, ad_su_exp.md §4 "Unified Meshlet Export"): exp target 0x200 (`emitprim` / `exp.mesh`) kicks it with a meshlet's address in the shared memory (LDS); it reads the meshlet's primitive topology and vertex data through the LDS's port B, skips the culled primitives, packs each remaining triangle into a 702-bit package and streams the packages through a two-stage skid buffer to the rasterizer's setup (`ad_rx_setup`).  A child of ad_su_exp: the exp unit decodes the kick, owns `x_ready` and passes the mesh ports of ad_su_exp straight through.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `LDS_AW` | `10` | LDS word-address width (LDS_BYTES / 4 = 1024 words). ASSUMPTION: ad_su_exp gets the same parameter (not in its table). |
| `NVW` | `7` | Words per vertex (4 position + 3 varying words).  Only the formal harness changes it (NVW 1: three vertex reads a primitive). |
| `PW` | `3 NVW 32 + 30` | Package width (702). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, reset. |
| **Kick (from ad_su_exp)** | | | |
| `kick_valid` | in | 1 | Start a meshlet (taken only while idle; ad_su_exp holds exp groups while `mesh_busy`). |
| `kick_base` | in | LDS_AW | The meshlet's LDS word address B. |
| **LDS port B (ad_su_lds)** | | | |
| `mesh_lds_rd_en` | out | 1 | Read one word this cycle. |
| `mesh_lds_rd_addr` | out | LDS_AW | Its word address (wraps modulo the LDS). |
| `mesh_lds_rd_data` | in | 32 | The word read in the previous cycle (one-cycle latency). |
| **Triangles to ad_rx_setup** | | | |
| `mesh_valid` | out | 1 | A package; held with its data until `mesh_ready`. |
| `mesh_ready` | in | 1 | Taken. |
| `mesh_tri` | out | PW | The package (§4; 702 bits). |
| `mesh_last` | out | 1 | The meshlet's last unculled primitive. |
| `mesh_id` | out | 16 | The meshlet's id (its header). |
| `mesh_busy` | out | 1 | The sequencer is not idle (until its last package has been taken). |

13 ports.

## 4. Behaviour

ASSUMPTION (the meshlet layout in LDS; not given elsewhere), word addresses from B = `kick_base`, modulo 2^LDS_AW:

| Words | Content |
| --- | --- |
| B | Header: [31:16] meshlet id, [15:8] vertex count (informative, not checked), [7:0] primitive count P (0-255). |
| B + 1 + p, p < P | Primitive p: [31:24] flags (bit 7 = culled, set by the mesh shader's culling), [23:16] i2, [15:8] i1, [7:0] i0 (vertex indices). |
| VB + 7 i + w, VB = B + 1 + P | Vertex i: w = 0-3 position x, y, z, w (clip space, fp32), w = 4-6 varying words 0-2. |

ASSUMPTION (the 702-bit package, `mesh_tri`): [223:0] vertex i0's words 0-6 (word w at 32 w), [447:224] vertex i1's, [671:448] vertex i2's, [695:672] {i2, i1, i0}, [701:696] flags[5:0] (flag bit 7 is 0 for every package sent, bit 6 is not carried).  21 words × 32 = 672 data bits + 24 index bits + 6 flag bits.

- The kick: ad_su_exp kicks on the first lane group of an exp 0x200 instruction that has a side-effect lane; B = rs2 of the lowest such lane (bits LDS_AW-1:0).  ASSUMPTION: one kick per instruction (the groups of an instruction are consecutive on the execution bus); exp 0x200 from any warp kind.  ASSUMPTION: ad_su_exp's `x_ready` is `!mesh_busy` (registered; no exp group, of any target, is taken while a meshlet streams).
- The header is read, then each primitive word in turn.  A culled primitive costs one cycle (the next primitive word is read in the same cycle) and no vertex read.  For an unculled one the 21 vertex words are read one per cycle (i0's words 0-6, i1's, i2's) into the package.
- A finished package is held until the sequencer knows whether it is the last: it is pushed into the skid buffer (with `mesh_last` 0) when the next unculled primitive is found, or with `mesh_last` 1 when the primitives end.  So `mesh_last` is on the last unculled primitive even when culled primitives follow it.  ASSUMPTION: a meshlet with no unculled primitive (P = 0 or all culled) sends nothing (no package carries its `mesh_last`).
- `mesh_id` and `mesh_last` travel with the package through the skid buffer.  `mesh_busy` stays 1 until the skid buffer is empty.

## 5. State machine

IDLE →(kick_valid)→ HREQ (read B) → HDR (the header; P = 0: DRAIN_WAIT) → PRIM_LATCH (primitive p's word; culled: read p + 1 in the same cycle or END) →(unculled)→ SKID_WAIT (only while the held package cannot enter the skid buffer) → VERT (21 reads, the data one cycle later) →(the last word in; more primitives)→ PRIM_REQ (read p + 1) → PRIM_LATCH … →(no more)→ END (push the held package with mesh_last) → DRAIN_WAIT (the skid buffer empties) → IDLE.

## 6. Latency and throughput

Header 2 cycles; per unculled primitive 1 (PRIM_REQ) + 1 (PRIM_LATCH) + 22 (VERT) cycles, plus SKID_WAIT while the setup back-pressures; per culled primitive 1 cycle.  One package per cycle out of the skid buffer while `mesh_ready`.  Storage: one 672-bit package register and the skid buffer's two 719-bit registers; no block RAM.

## 7. Corner cases and errors

- Addresses wrap modulo the LDS (a meshlet near the top of the LDS continues at word 0).
- Vertex indices are not checked against the vertex count.
- A kick while busy is ignored (it cannot happen: x_ready is 0).

## 8. What the TB checks

`sim/tb/ad_su_exp_mesh_tb.v` (through ad_su_exp, NPHYS 8) prints:

- `PASS ad_su_exp_mesh.stream` — 15 meshlets of `tools/gen_gfx_vectors.py` (`mesh_ref()`, sim/vec/gfx_mesh_*.hex) kicked by exp 0x200 instructions (the kick in group 0 or 1, other lanes and groups carrying other addresses): every package, `mesh_last`, `mesh_id` in order, with culled primitives, a meshlet whose last primitive is culled, one with every primitive culled, P = 0, one wrapping around the LDS; random `mesh_ready`; the package held while not taken; `x_ready` 0 while `mesh_busy`; LDS reads only while busy.  `-DMUT_MESH_CULL` (culled primitives sent) fails it.
- `PASS ad_su_exp_mesh` at the end.

## 9. References

spec ad_su_exp.md §3-§6 (the mesh ports), ad_su_lds.md (port B), ad_rx_setup (its `cl_tri`, not in this repository).

## 10. Status

2026-11-08: written for ws004-p002 from ad_su_exp.md §3-§6 (no spec existed).  ASSUMPTION: the LDS meshlet layout and the 702-bit package of §4; one kick per instruction from the lowest side-effect lane of its first group with one; x_ready = !mesh_busy; nothing is sent for a meshlet without unculled primitives; the HREQ/HDR and END states added to the FSM of ad_su_exp.md §5 (a header read and the deferred mesh_last).  Formal: `formal/ad_su_exp_mesh` (NVW 1, an LDS of 8 free constant words, at most two primitives; abc bmc3 depth 30: per meshlet exactly its unculled primitives in order with the header's id, mesh_last on the last only, the primitive's indices and flags, the vertex words, nothing left when mesh_busy falls; abc pdr proven: LDS reads only while busy, the package held while not taken, nothing valid while idle; the per-meshlet properties did not close with pdr in 10 minutes), `formal/ad_gfx_skid` (proven: no loss, duplication or reordering).  `-DMUT_MESH_CULL` fails the TB.
