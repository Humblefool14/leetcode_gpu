# ad_rop_hazard

RTL: `rtl/gpu/rop/ad_rop_hazard.v`.  Parent: `ad_rop_wb`.  Implemented in: ws001-p016.

## 1. Purpose and place

Pixel Lock CAM and RAW Hazard Tracker for the ROP write-back pipeline (`ad_rop_wb`).
Tracks in-flight quad coordinates `{RT[1:0], Y[15:1], X[15:1]}` across pipeline stages.
Prevents read-after-write hazards when multiple overlapping quads target the same screen coordinates, while allowing non-conflicting quads to stream through the pipeline with 1 cycle/quad throughput.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NUM_ENTRIES` | `16` | Number of tracking CAM entries (maximum in-flight quads). |
| `TAG_W` | `32` | Tag width: `{RT[1:0], Y[15:1], X[15:1]}`. |

## 3. Ports

Clock/reset domain: `clk` (gclk), synchronous reset `rst_n` (active low).

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Allocation interface** | | | |
| `alloc_valid` | in | 1 | Request to allocate and lock a quad coordinate. |
| `alloc_ready` | out | 1 | Asserted when CAM has an empty entry and no RAW hazard matches `alloc_tag`. |
| `alloc_tag` | in | TAG_W | Coordinate tag `{RT[1:0], Y[15:1], X[15:1]}`. |
| `alloc_id` | out | 4 | Allocated CAM entry ID for tracking. |
| **Release interface** | | | |
| `release_valid` | in | 1 | Request to release a locked entry on commit. |
| `release_id` | in | 4 | CAM entry ID being released. |

6 ports.

## 4. Behaviour

- **Parallel CAM Matching**: Every cycle, `alloc_tag` is compared against all valid entries in the 16-entry CAM.
- **Hazard Detection**: If an in-flight entry has the same coordinate tag, `hazard_hit` is asserted and `alloc_ready` is deasserted (stalling upstream until the matching entry is committed and released).
- **Zero-Wait Issue**: If no in-flight entry matches and at least one entry is free, `alloc_ready` is asserted. The lowest-index free entry is allocated (`alloc_id`).
- **Simultaneous Release & Allocate**: When an entry is released in the same cycle as an allocation targeting the same coordinate or slot, release is processed combinational-forwarded so that the stalling quad can be accepted without dead cycles.

## 5. What the TB checks

`sim/tb/ad_rop_hazard_tb.v` prints:
- `PASS ad_rop_hazard.burst`: 16 continuous non-conflicting quad allocations without stall, followed by full-CAM backpressure and entry restoration.
- `PASS ad_rop_hazard.raw`: RAW hazard stall on identical coordinate `{X, Y}`, immediate un-stall upon release, non-collision of distinct attachments (`RT=0` vs `RT=1`).
- `PASS ad_rop_hazard` at the end.

## 10. Status

2026-11-08: implemented in `rtl/rop/ad_rop_hazard.v` with leaves `rtl/rop/hazard/ad_hazard_cam.v` (parallel compare) and `rtl/rop/hazard/ad_hazard_prienc.v` (lowest set bit).  `sim/tb/ad_rop_hazard_tb.v` prints `PASS ad_rop_hazard.burst`, `.raw`, `.random` (40000 random cycles against a scoreboard: outputs checked every cycle, never two in-flight entries with equal tags, every allocation released) and `PASS ad_rop_hazard`.  Formal `formal/ad_rop_hazard/` (TAG_W reduced to 4, 16 entries): unique tags, alloc_ready exact, alloc_id lowest free, allocate/release effects, full CAM stalls: bmc (abc bmc3, 20) PASS, prove (abc pdr) PASS, cover PASS; `formal/ad_hazard_prienc/` prove PASS.  Mutations `-DMUT_HAZ_CAM` (no hazard check) and `-DMUT_HAZ_FWD` (no release forwarding) fail TB and bmc.
ASSUMPTION: 8 ports (the "6 ports" of §3 does not count clk/rst_n).  `alloc_id` is 4 bits as §3 says, so NUM_ENTRIES <= 16.
ASSUMPTION: alloc_ready does not depend on alloc_valid.  An entry released this cycle counts as free and non-matching (forwarding, §4); the lowest free entry after forwarding is allocated, so a released entry may be reused in the same cycle.  Releasing an invalid entry, or an id >= NUM_ENTRIES, is ignored.
ASSUMPTION: TAG_W default 32 as §2 (ad_rop.md mentions a 33-bit tag for 8 RTs: set TAG_W=33 at the instance).
ASSUMPTION: tags are not reset (qualified by the valid bits).  Formal-only observation ports `fv_valid`/`fv_tags` exist under `-DAD_FV_HAZARD` only.
