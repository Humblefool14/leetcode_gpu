# ad_rop_ds

RTL: `rtl/gpu/rop/ad_rop_ds.v`.  Parent: ad_rop.  Implemented in: p007.

## 1. Purpose and place

ROP depth and stencil: reads the depth/stencil line of the quad (DS_BASE/STRIDE, D32F or D24S8), tests (DEPTH func, STENCIL_* front/back), updates and writes it back, and passes the surviving lanes.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `STENCIL` | `0` | Stencil present (ROP_STENCIL). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from ad_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| **From ad_rop_order** | | | |
| `q_valid` | in | 1 | A quad in primitive order. |
| `q_ready` | out | 1 | Taken. |
| `q_xy` | in | 32 | Position. |
| `q_smask` | in | 16 | Samples: bit 4 l + s (one sample: bit 4 l). |
| `q_color` | in | 512 | Colour (fp32 RGBA × 4). |
| `q_sdepth` | in | 512 | The samples' depths: sample s of lane l at 32 (4 l + s). |
| `q_dbg` | in | 1 | From the direct path: use DEBUG_COLOR. |
| `q_front` | in | 1 | (CAPS[30]) The quad's facing (the direct path reads as front). |
| `q_beat` | in | 4 | (CAPS[30]) {rt, nocol, first} of the beat (ad_rop_ms's o_beat). |
| **To ad_rop_wb** | | | |
| `d_valid` | out | 1 | A quad after depth/stencil. |
| `d_ready` | in | 1 | Taken. |
| `d_xy` | out | 32 | Position. |
| `d_smask` | out | 16 | Samples that passed. |
| `d_color` | out | 512 | Colour (DEBUG_COLOR expanded for q_dbg). |
| `d_beat` | out | 4 | The beat's {rt, nocol, first}. |
| `busy` | out | 1 | Work outstanding. |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

33 ports; 22 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Depth test off: pass all.  A quad's 2×2 pixels lie in two rows: two reads (or one line per row), compare, write if DEPTH[1] and any lane passed.  Read-after-write order: the next quad touching the same line waits for the write response (small address match).

**CAPS[30]**: the module keeps DEPTH[9:0], STENCIL_FRONT, STENCIL_OPS, STENCIL_BACK and DEPTH_BOUNDS_MIN/MAX; each covered (lane, sample) entry goes through `ad_rop_dtest` (bounds, stencil with the quad's facing, depth; spec ad_rop_dtest.md), and its byte enables say which bytes of the line are written.  The line is read when exactly one format bit is set and the depth test, the stencil test (D24S8) or the bounds test is on.  D16 pixels are 2 bytes: sample s of pixel x at byte 2 (S x + s) of the row.

## 5. State machine

IDLE → READ → TEST → WRITE → IDLE.

## 6. Latency and throughput

One quad per AMB round trip (v1); a depth line cache is p015.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/ad_rop_ds_tb.v` prints, in this order:

- `PASS ad_rop_ds.funcs` — all 8 depth functions
- `PASS ad_rop_ds.stencil` — (CAPS[30], `sim/vec/rop_ds2.txt` from `tools/rop-vectors.py`) D24S8 runs with the stencil test and ops, random faces per quad, the buffer at the end
- `PASS ad_rop_ds.raw` — overlapping quads in order
- `PASS ad_rop_ds.d16` — D16 runs (2-byte pixels)
- `PASS ad_rop_ds.bounds` — the depth bounds of the three formats
- `PASS ad_rop_ds` at the end.

## 9. References

design §2.3 (ROP STATE 0x070-0x07C).

## 10. Status

2026-10-24 Q1 (P3's p007 decisions, ACKed; ghci.md to follow): stencil ops are not implemented in v1 (the ROP gets no facing bit; a port change belongs to p009). STATE bits: SCISSOR_MIN/MAX `{y, x}` (MAX 0 = none), RT_SIZE `{h, w}`, CULL [1:0] 1 front/2 back/3 both and [2] front = CCW, DEBUG_COLOR and BLEND_CONST RGBA8 (R in [7:0]), BLEND [0] enable, [4:1] src colour, [8:5] dst colour, [11:9] colour op, [15:12] src alpha, [19:16] dst alpha, [22:20] alpha op (VkBlendFactor/VkBlendOp numbers), WRITE_MASK [3:0] RGBA (0 writes nothing), DEPTH func = VkCompareOp and no test without a depth format bit; DS_BASE/RT_BASE/stride aligned to 8 bytes (4 for RGB565). The CP sequencer holds a SET_REG into the RX range (0x050–0x06F) while RX or ROP is busy and into the ROP range (0x070–0x08F) while the ROP is busy.

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.

2026-10-24 (p009 part E, P3): the depth conversion and compare functions moved to `include/ad_depth.vh`, shared with the TU's compare samplers (ad_tu_filter); the behaviour is unchanged.

Multisampling (the MSAA work): MS_CTRL[3:0] = 2 makes the row's address base + y stride + 16 x and the test runs per sample (8 entries per row: sample s of pixel x at word 4 x + s); one sample: as before (2 entries).  `q_mask`/`q_depth`/`d_mask` became `q_smask`/`q_sdepth`/`d_smask` (the same port count).  The 4-sample cases are in `sim/tb/ad_rop_ms_tb.v`; this TB drives the one-sample masks as bit 4 l and checks that no other bit of d_smask is set.

2026-10-25 (CAPS[30]): ad_rop_dtest per entry, q_front, D16, the stencil and the bounds (§4); every PASS of §8 (`-DMUT_STENCIL_FACE` fails `.stencil` and `.bounds`).  The earlier vectors are unchanged.

2026-10-25 (CAPS[30], colour attachments): `q_beat`, `d_beat`.  The first beat of a quad is tested and written as before; a later beat goes to OUT with the first's surviving samples (no memory access) and is dropped when none survived.  A beat without colour goes on to ad_rop_wb (which drops it), so ad_rop counts the samples of every quad's first beat once (occlusion).  Checked by `sim/tb/ad_rop_beat_tb.v` (`-DMUT_DS_BEAT`, testing every beat, fails `.colour`).

2026-10-25 (area): the entry's stored value and its new bytes are the 32-bit word of the line that holds the entry (D16: its half), the entry's offset being a multiple of ps as docs/ghci.md section 8.5 requires (bases multiples of 64, strides of 2 x S x ps); the low bits of an offset that is not are ignored (before, the bytes at the unaligned offset).  Aligned rows are unchanged.

2026-11-08 (ad_rop rebuild, `rtl/rop/ad_rop_ds.v`): leaves `rtl/rop/ds/ad_ds_addr.v` (row addresses), `ad_ds_row.v` (8 ad_rop_dtest per row, the merge with byte enables), `ad_ds_dbgcol.v` (DEBUG_COLOR through ad_unorm2f #(8)).  States IDLE → DEC → RD → TST (row 0, row 1) → WR → OUT → IDLE (DEC → OUT directly for a later beat or with the tests off).  `sim/tb/ad_rop_ds_tb.v` with ad_amb_mem (70 % ready, latency 2-12) against `tools/ds_model.py` (`sim/vec/ds_{cmd,exp,mem}.hex` from `tools/gen_ds_vectors.py`, 75 runs, 1, 4 samples): every PASS of §8 plus `PASS ad_rop_ds.beats` (later beats, the direct path, passthrough), at LINE_BYTES 32 (default) and 64 (`-Pad_rop_ds_tb.LB=64`); the TB also checks d_* stability and that no line is read while a write of it is outstanding (`-DMUT_DS_NORAW`, no read-after-write wait, fails it; ad_amb_mem being in order, the data alone would not show it).  Formal `formal/ad_rop_ds` (ADDR_W 10, LINE_BYTES 32, ad_rop_dtest abstracted): bmc 24 (abc bmc3), prove (abc pdr) and cover (smtbmc z3) pass; `formal/ad_ds_row` bmc/prove pass.
ASSUMPTION: bases are multiples of 64 and strides multiples of 2 × S × ps (docs/ghci.md §8.5), so each row's 2 × S × ps bytes lie in one line (LINE_BYTES 32 or 64).  Not checked by the hardware: with other values an entry's offset is rounded down to a multiple of ps and taken modulo LINE_BYTES within the line of the row's first byte.  Strides below 2 × S × ps (rows overlapping) give row 0's writes before row 1's test when both rows are in one line; the model does the same.
ASSUMPTION: entry (lane l, sample s) at DS_BASE + (y + (l >> 1)) DS_STRIDE + (S (x + (l & 1)) + s) ps, modulo 2^ADDR_W; S = 4 when MS_CTRL[3:0] = 2, else 1 (only q_smask bit 4 l counts for the test with one sample; a passthrough quad keeps q_smask as given).
ASSUMPTION: a line is read only for a row with at least one covered entry; a first beat with no covered entry (tests on) does no memory access, gives d_smask = 0 and is dropped.  Both rows in one line: one read and one write.  A line is written (one AMB write, req_be = the enabled bytes) only when some wbe was set.
ASSUMPTION: a later beat (q_beat[0] = 0) gets d_smask = the surviving samples of the most recent first beat (its own q_smask is ignored), no memory access; any quad with d_smask = 0 is not sent.  The survivors register is 0 after reset.
ASSUMPTION: read-after-write: a read waits while a write of the same line (of the previous quad) is outstanding; the writes of a quad wait until the previous quad's writes have completed (at most two writes outstanding).  The quad goes to OUT once its writes are accepted (not completed).  Tags {6'b0, write, slot}; responses are matched by tag (any order).
ASSUMPTION: rsp_error: a read gives an all-zero line (the test proceeds on it); a write counts as completed.
ASSUMPTION: STATE writes are expected only while busy is low (CP rule); DEBUG_COLOR is sampled when the quad is taken (d_color stays stable while d_valid), the other words are used live.  With STENCIL = 0, DEPTH[8] reads as 0.  q_color lane l at [128 l +: 128], R G B A at +0, +32, +64, +96 (DEBUG_COLOR expanded the same way).
Limitations: STENCIL = 0 is not exercised by the TB (the TB instantiates STENCIL = 1); misaligned bases/strides are not supported; one quad per AMB round trip (two when the rows are in different lines: the reads are issued back to back).
