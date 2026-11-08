# ad_su_exp

RTL: `rtl/gpu/su/ad_su_exp.v`.  Parent: ad_su.  Child: `ad_su_exp_drain`, `ad_su_exp_mesh`.  Implemented in: p009, ws004-p002.

## 1. Purpose and place

The fragment export buffer: fragment colour (CAPS[30]: four attachments) and depth exports into the warp's buffer that the ROP drains after the warp's end, in sequence-number order, as one beat per exported attachment of each quad (`ad_su_exp_drain`); the slot release of every ended warp.  The PT and its allocator are `ad_su_pt` (split off in WS288 p009 part B, as §5 of the earlier text foresaw).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= AD_UOP_W of include/ad_su_uop.vh). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Issued instruction, one lane group per cycle (from ad_su_opd, shared by all units)** | | | |
| `x_valid` | in | 1 | A lane group of an instruction; this unit acts only when the uop's unit field is its own. |
| `x_warp` | in | WARP_W | Warp slot. |
| `x_grp` | in | GRP_W | Lane group (lanes x_grp*NPHYS .. +NPHYS-1). |
| `x_last` | in | 1 | Last group of the instruction. |
| `x_sbe` | in | (SBE_W)+1 | Scoreboard entry of the instruction (all ones = none). |
| `x_pc` | in | 16 | Instruction index (branches, faults). |
| `x_uop` | in | UOP_W | The decoded instruction (include/ad_su_uop.vh). |
| `x_a` | in | NPHYS*32 | Operand rs1 per lane (modifiers applied). |
| `x_b` | in | NPHYS*32 | Operand rs2 (exp: the data). |
| `x_c` | in | NPHYS*32 | Operand rs3 (or rs1+1 for the PAIR instructions). |
| `x_mask` | in | 2*NPHYS | [NPHYS-1:0] EXEC lanes of the group, [2*NPHYS-1:NPHYS] side-effect lanes (EXEC & coverage & ~KILLED). |
| `x_info` | in | 32 | x_info [15:0] fragment sequence number, [17:16] warp kind (0 vertex, 1 fragment, 2 compute), [18] front facing, [31:19] 0. |
| `x_ready` | out | 1 | Always 1 (exp takes one group per cycle). |
| **Export to the ROP (ad_rop)** | | | |
| `ex_valid` | out | 1 | One beat: a quad's fragment output for one colour attachment (or without colour). |
| `ex_ready` | in | 1 | Taken (the ROP keeps primitive order). |
| `ex_seq` | out | 16 | Fragment warp sequence number. |
| `ex_xy` | out | 32 | {y, x} of the quad's top-left pixel. |
| `ex_mask` | out | 4 | Covered lanes that exported (see §4). |
| `ex_color` | out | 512 | 4 lanes × the beat's attachment's RGBA × fp32 (lane i at [128i+127:128i], component c at +32c). |
| `ex_depth` | out | 128 | 4 lanes × depth (fp32; 0x104 written, else the rasterized z). |
| `ex_last` | out | 1 | Last beat of the warp's last quad (the ROP retires the sequence number). |
| `ex_next` | in | 16 | The ROP's next sequence number: only the ended warp with this sequence is drained (so the ROP never waits on a later warp, design §3.8). |
| **Fragment warps from the RX (snooped from the ad_su ports fl_*)** | | | |
| `fl_we` | in | 1 | Register write of the RX (r3 = z, r4 = x + 0.5, r5 = y + 0.5 are taken). |
| `fl_slot` | in | WARP_W | Its warp slot (ad_su's fl_slot). |
| `fl_reg` | in | 6 | Register. |
| `fl_lane` | in | 5 | Lane. |
| `fl_data` | in | 32 | Data. |
| `fl_go` | in | 1 | The warp starts (slot fl_slot). |
| `fl_info` | in | 64 | [31:0] coverage, [47:32] sequence number, [48] front. |
| `fl_pw_we` | in | 1 | The RX's primitive table write (snooped). |
| `fl_pw_addr` | in | 12 | Its address: 0xFF8-0xFFB are the samples' depth slopes d_0..d_3 of the warp. |
| `fl_pw_data` | in | 32 | Its data. |
| `ex_aux` | out | 154 | With the beat: {rt[1:0] (its attachment), qlast, qfirst (its place in the quad), nocol (no colour: the warp exported none), front (CAPS[30]: the warp's facing, fl_info[48] at fl_go), d_s[127:0] (sample s at 32 s; 0 when the warp has none), zexp[3:0] (the lanes that exported DEPTH, of ex_mask's), smask[15:0] (lane l's sample mask at 4 l)}; every beat of a quad has the same [147:0]. |
| **Slot release (ad_su_sched)** | | | |
| `xr_valid` | out | 1 | A warp's exports are drained (one-cycle pulse). |
| `xr_warp` | out | WARP_W | Warp. |
| `wc_end` | in | 1 | ad_su_exec ended a warp (with wc_warp). |
| `wc_warp` | in | WARP_W | Warp. |
| **Meshlet Primitive Export (to ad_rx_setup via ad_su_exp_mesh)** | | | |
| `mesh_valid` | out | 1 | Mesh triangle stream valid. |
| `mesh_ready` | in | 1 | RX setup ready (backpressure). |
| `mesh_tri` | out | 702 | Triangle package (3 vertices positions & varyings, control flags, indices). |
| `mesh_last` | out | 1 | Last primitive of the meshlet. |
| `mesh_id` | out | 16 | Meshlet ID. |
| `mesh_busy` | out | 1 | Sequencer active. |
| **LDS Port B (Memory Interface to ad_su_lds)** | | | |
| `mesh_lds_rd_en` | out | 1 | LDS Port B read enable. |
| `mesh_lds_rd_addr` | out | LDS_AW | LDS Port B word address. |
| `mesh_lds_rd_data` | in | 32 | LDS Port B read data (1-cycle latency). |

## 4. Behaviour

- Fragment warp (x_info kind 1): exp targets 0x100 + 16 k + c (colour attachment k = 0-3, component c), 0x104 (DEPTH) and 0x105 (SAMPLE_MASK) write
  the side-effect lanes of the group into the warp's buffer; other targets are ignored here (vertex
  warps' exports are ad_su_pt's).  A lane is *exported* once any such exp ran for it; ex_mask = the
  quad's covered and exported lanes.  Colour components never exported keep the buffer's old
  contents (the compiler exports all four).
- The quads of the warp are the quads with coverage in fl_info[31:0] (the RX packs them from lane
  0); quad q's position is floor(r4), floor(r5) of lane 4q as the RX wrote them (fl_*); the depth of
  a lane is its exp 0x104 if any, else its r3 (the rasterized z) as written by the RX.
- The warp's attachments (rtw) are those some colour exp wrote with a non-empty side-effect mask (cleared at fl_go).  After wc_end of a fragment warp, when its sequence number equals ex_next, its quads go to the ROP in order, each as one beat per attachment of rtw (ascending) or, with rtw 0, one beat with nocol, one beat per ex_ready, ex_last on the last beat of the last quad; then xr_valid releases the slot.  Every beat of a quad carries the same ex_mask (an attachment some lane did not export has that lane's undefined values, as Vulkan leaves them).  0x108-0x10B (SECOND_COLOR) are ignored.  A warp with no
  covered quad is not made by the RX (ad_rop_order §7: quad 0 would be sent with mask 0 and ex_last).
- Vertex and compute warps: xr_valid the cycle after wc_end (their exports, if any, are already in
  the PT).  If that coincides with a drain's release, the drain's release waits one cycle.
- Unified Meshlet Export (ws004-p002): target 0x200 (`emitprim` / `exp.mesh`) kicks the meshlet export
  sequencer (`ad_su_exp_mesh`).  The sequencer autonomously reads culled primitive topology and corresponding
  vertex coordinates/varyings from Local Data Share (LDS) via Port B, formats them into 702-bit triangle packages
  (compatible with `ad_rx_setup`'s `cl_tri`), and streams them through a 2-stage Skid Buffer directly
  to the rasterizer.  Hardware culling skip discards culled primitives (flag bit 7 set) in a single cycle.
- Exports are asynchronous (not scoreboarded); end waits for the buffer via the slot release
  (design §3.4.1).

## 5. State machine

In `ad_su_exp_drain`: IDLE →(an ended fragment warp whose sequence number is ex_next)→ FIRST → DRAIN (one beat per ex_ready) →(last beat taken)→ RET (xr_valid) → IDLE.  Per warp only flags (fragment, ended).

In `ad_su_exp_mesh`: IDLE →(kick_valid)→ PRIM_REQ → PRIM_WAIT → PRIM_LATCH →(culled? next/DRAIN_WAIT : VERT_REQ)→ VERT_REQ (burst 21 words) → VERT_WAIT → SKID_WAIT →(last primitive? DRAIN_WAIT : PRIM_REQ)→ DRAIN_WAIT (wait for skid empty) → IDLE.

## 6. Latency and throughput

One group per cycle in; one beat per cycle to the ROP (and one cycle per warp before its first beat).  Storage: NPHYS lane banks × 18 words (R, G, B, A of 4 attachments, exported depth, rasterized z) × NWARPS×32/NPHYS rows, written one word per bank per cycle, read asynchronously (a quad's 4 lanes are 4 banks of one row): distributed RAM.

Meshlet Export: 21 words per active primitive burst-read from LDS Port B (1 word/cycle), assembled into 702-bit triangle and emitted through 2-stage Skid Buffer at wire speed (1 cycle per handshake with `mesh_ready`).  Culled primitives skip vertex reads and take 1 cycle.  Zero additional Block RAMs.

## 7. Corner cases and errors

- A kill after the warp's last exp does not discard the lane (GSI1: exp has no side effect only for lanes killed before it; the compiler places kill before the exports).
- Unwritten colour components: undefined (the previous warp's values).

## 8. What the TB checks

`sim/tb/ad_su_exp_tb.v` prints, in this order:

- `PASS ad_su_exp.frag` — fragment exports drain to the ROP after end, in sequence-number order, with the quads' positions, masks, colours and depths (exported or rasterized)
- `PASS ad_su_exp.release` — vertex warps release the cycle after their end, fragment warps once after their drain
- `PASS ad_su_exp.ms` — the RX's r6 in half the warps (others 1111), d_s words in half (others 0; the map and a varying word are not d_s), SAMPLE_MASK exported twice in half (the last value counts): ex_aux[147:0] and ex_mask without the lanes whose mask is 0; `-DMUT_SMASK_AND` fails it
- `PASS ad_su_exp.mrt` — (CAPS[30]) the beats: one per attachment the warp exported (a random set per warp, attachment 0 alone in half), rt, qfirst and qlast, one nocol beat for a warp without colour, the beat's colours, the warp's facing (random) in ex_aux[148], SECOND_COLOR ignored; `-DMUT_EXP_FRONT` fails it
- `PASS ad_su_exp` at the end.

## 9. References

design §3.4.3 (inputs/outputs), §3.5, §3.8 (ROP order); spec ad_su_pt.md (the PT), ad_rx_scan.md (the RX's register writes).

## 10. Status

Implemented in WS288 p009 part B1 (P1, branch p1-su-gfx).  Spec changes in p009 (proposed to Q1 with the commit): the PT and its allocator moved to the new module `ad_su_pt` (ports `pt_*`, `pt_ok`, `pt_take`, `pt_base` and the parameters `PT_ENTRIES`, `VARY_WORDS` left this module); new snoop ports `fl_we`, `fl_slot`, `fl_reg`, `fl_lane`, `fl_data`, `fl_go`, `fl_info` (the quads' positions, the rasterized z, the coverage and the sequence number come from the RX's writes: fl_info has no room for 8 positions).  Readings: r4/r5 are the pixel centre (x + 0.5, y + 0.5, Vulkan FragCoord); ex_mask = covered and exported lanes; point size (0x004) and SECOND_COLOR (0x108+c) are not stored in v1.

Multisampling (the MSAA work, docs/ghci.md §12.11): exp 0x105 (SAMPLE_MASK, lane banks of 4 bits, the last value written and a per-lane flag cleared at fl_go), the RX's r6 snooped like r3 (lane banks of 4 bits and a per-lane flag cleared at the slot's release: a lane the RX did not write takes 1111), the d_s words snooped from fl_pw_* (per slot, cleared at the release); the quad's sample mask = r6 & SAMPLE_MASK; ex_mask leaves out the lanes whose mask is 0; ex_ms.  New ports fl_pw_*, ex_ms (39).  323 lines.

2026-10-25 (CAPS[30], colour attachments): COLOR1-3 (0x110-0x133), rtw, the beats and `ex_aux` (was `ex_ms`, 154 bits); the drain moved to the child `ad_su_exp_drain` (39 ports still; the design's text had it as a sibling).  The checks of `.frag` now follow the beats.

Session protection (2026-10-25): `scrub` writes 0 to every word through the write port, one word per cycle (`ad_su_scrub`), `scrub_busy` meanwhile; the RAM's declaration and read are unchanged.  Checked by `sim/tb/ad_su_scrub_tb.v`.

2026-11-08 (graphics-side rebuild in this repository, rtl/su/ad_su_exp.v, children ad_su_exp_drain, ad_su_exp_mesh, leaves rtl/su/gfx/ad_gfx_floor16.v, ad_gfx_skid.v).  Checked by `sim/tb/ad_su_exp_tb.v` (NPHYS 8 and 4 side by side, 40 batches of `tools/gen_gfx_vectors.py` run through `tools/gsi1model.py --warps --exp-out --ms-out`: every beat equals write_exports()) and `sim/tb/ad_su_exp_mesh_tb.v`; formal `formal/ad_su_exp` (NPHYS 4, NWARPS 2, LDS_AW 4: abc bmc3 depth 14 for every property incl. ex_* held while not taken and the beats of a quad sharing mask/xy/depth/aux[147:0]; abc pdr proven for the control part: beats only of the ended fragment warp whose number is ex_next, releases only of ended warps, x_ready = !mesh_busy; the data properties over the memory_map'ed buffer did not close in 10 minutes), `formal/ad_su_exp_drain`, `formal/ad_su_exp_mesh`, `formal/ad_gfx_skid`, `formal/ad_gfx_floor16`.  Mutations: `-DMUT_SMASK_AND` fails `.ms` (and `.frag`), `-DMUT_EXP_FRONT` fails `.mrt`, `-DMUT_DRAIN_SEQ` fails `.frag/.ms/.mrt` and formal ad_su_exp_drain, `-DMUT_MESH_CULL` fails `ad_su_exp_mesh.stream`.
- ASSUMPTION: UOP_W is 108 (AD_UOP_W); new parameter `LDS_AW` (10) for the mesh LDS port; ports `scrub`/`scrub_busy` as ad_su.md §10 says.
- ASSUMPTION: the rasterized z (RX r3) is kept in its own NPHYS banks of NWARPS×32/NPHYS words instead of word 17 of the 18-word row, so an RX write and an exp write never meet on one bank's write port in the same cycle; the 17 colour/depth words keep one write port per bank (address {word, row}).
- ASSUMPTION: ex_color, ex_depth and ex_aux's smask are 0 for lanes outside ex_mask (the spec leaves them undefined; write_exports() writes 0), zexp is ANDed with ex_mask; a nocol beat has rt 0.
- ASSUMPTION: colour targets are 0x100-0x13F with bits 3:2 = 0 (0x100 + 16 k + c, c < 4), as gsi1model.py decodes them; 0x104 DEPTH, 0x105 SAMPLE_MASK (bits 3:0); every other target, and every target of a non-fragment warp, is ignored here (0x200 kicks the meshlet sequencer from any warp kind).
- ASSUMPTION: the quad position is the floor of r4/r5 of lane 4q as a 16-bit unsigned integer (negative or below 1: 0; ad_gfx_floor16).
- ASSUMPTION: cleared at fl_go: coverage, front, rtw, the exported / DEPTH-exported / SAMPLE_MASK-exported lane flags; cleared at the slot's release: the r6-written flags and d_s; positions, z, r6 values and SAMPLE_MASK values are plain data qualified by those flags.  d_s words are taken from fl_pw_* with fl_slot.
- ASSUMPTION: x_ready = !mesh_busy (was "always 1"): no exp group is taken while a meshlet streams (registered, no path from x_uop).  The kick rules are in ad_su_exp_mesh.md §4.
- ASSUMPTION: scrub zeroes the colour/depth banks (DEPTH 17 × NWARPS × 32/NPHYS cycles) and the z banks in its first NWARPS × 32/NPHYS cycles; the per-lane flags and sample-mask values are not scrubbed (they are reset per warp).
