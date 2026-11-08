# ad_rop_ms

RTL: `rtl/gpu/rop/ad_rop_ms.v`.  Parent: ad_rop.  Child: `ad_rx_fadd`.

## 1. Purpose and place

The render output's multisample coverage (docs/ghci.md §12.11), between `ad_rop_order` and `ad_rop_ds`: the samples of a quad that go on, the depth of every sample, alpha to coverage and alpha to one.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, reset |
| `st_we`, `st_idx`, `st_wdata` | in | 1, 9, 32 | STATE; this module keeps MS_CTRL (0x05E: [3:0] = 2 four samples, [8] alpha to coverage, [9] alpha to one) |
| `i_valid` / `i_ready` | in / out | 1, 1 | A quad from ad_rop_order |
| `i_xy`, `i_mask`, `i_color`, `i_depth`, `i_dbg` | in | 32, 4, 512, 128, 1 | Its position, lanes, colours, depths (exported or the RX's r3), the direct path |
| `i_aux` | in | 154 | {rt[1:0], qlast, qfirst, nocol, front, d_s[127:0], zexp[3:0], smask[15:0]} (the beat, CAPS[30]) |
| `o_valid` / `o_ready` | out / in | 1, 1 | The quad to ad_rop_ds |
| `o_xy`, `o_smask`, `o_color`, `o_sdepth`, `o_dbg`, `o_front` | out | 32, 16, 512, 512, 1, 1 | Its position, samples (bit 4 l + s), colours, the samples' depths (at 32 (4 l + s)), the direct path, the facing (i_aux[148]) |
| `o_beat` | out | 4 | {rt, nocol, first} of the beat (i_aux[153:152], [149], [150]) |
| `busy` | out | 1 | A quad held |

23 ports (21 before CAPS[30]).

## 4. Behaviour

- Four samples: smask = i_aux[15:0]'s & i_mask's lanes & (alpha to coverage, not for the direct path: n = the number of 0.125, 0.375, 0.625, 0.875 that COLOR0's alpha reaches (fp32 compares of the bits; NaN and negatives 0): n 0 none, 1 {0}, 2 {0, 3}, 3 {0, 1, 3}, 4 all — Amaterrace's table, Vulkan leaves it to the implementation).  The depth of sample s of lane l: the lane's depth when it exported DEPTH (zexp), else clamp01(z + d_s) (fadd RNE with denormals flushed; NaN and negatives 0, above 1 one).
- One sample: bit 4 l = i_mask[l] & i_aux[4 l] (& alpha ≥ 0.5 with alpha to coverage); the depth as given (no add); the other bits 0.
- Alpha to one (not for the direct path): COLOR0's alpha = 1.0.  A quad with no sample left is dropped.
- **CAPS[30]**: the module keeps DEPTH_CLAMP (0x059) and VIEWPORT's z scale and offset (0x054, 0x055).  With DEPTH_CLAMP[1] (the RX clips the depth) z + d_s is not clamped to [0, 1].  With DEPTH_CLAMP[0] every sample's depth, exported or not, one sample or four, is clamped to [min(n, f), max(n, f)] (n the z offset, f = n + z scale by the fadd the cycle after either is written, which happens while the ROP is idle; fp32 order; a NaN depth gives the minimum).  DEPTH_CLAMP 0 is the earlier behaviour bit for bit.

## 5. State machine

IDLE →(a quad with samples; four samples)→ Z (16 adds, one per cycle, results 4 cycles later: 20 cycles) → OUT; IDLE →(one sample)→ OUT; OUT →(o_ready)→ IDLE.  A quad without samples is taken in IDLE and dropped.

## 6. Latency and throughput

One quad at a time: 2 cycles with one sample, 22 with four.

## 7. Corner cases and errors

- `MUT_A2C_STEP` moves the first threshold to 0.25 (the TB's mutation check).

## 8. What the TB checks

`sim/tb/ad_rop_ms_tb.v` (the whole `ad_rop` against `sim/vec/rop_ms.txt` from `tools/rx-msaa-vectors.py` and `tools/msmodel.py`, LINE_BYTES 32 and 64; the RT and DS images word for word) prints:

- `PASS ad_rop_ms.depth` — four samples, D32F and D24S8, RGBA8, BGRA8, RGB565, the direct path among the quads
- `PASS ad_rop_ms.a2c` — alpha to coverage, and with alpha to one
- `PASS ad_rop_ms.blend` — blend per sample
- `PASS ad_rop_ms.bypass1x` — one sample (MS_CTRL 0x100 and 0)
- `PASS ad_rop_ms` at the end.

## 9. References

design §15.6; spec ad_rop.md, ad_rop_order.md, ad_rop_ds.md, ad_rop_wb.md, ad_su_exp.md (ex_aux).

## 10. Status

Implemented (the MSAA work).  2026-10-25 (CAPS[30]): the depth clamp and DEPTH_CLAMP[1] (§4), o_front; checked by `sim/tb/ad_rop_msz_tb.v` (`PASS ad_rop_msz.clamp`, `.legacy`, `ad_rop_msz`: the module alone against `ms_depth` of `tools/rop-vectors.py`, `sim/vec/rop_msz.txt`), the earlier TB unchanged.

2026-10-25 (CAPS[30], colour attachments): a quad comes as one beat per colour attachment (`i_aux`, was `i_ms`; new `o_beat`).  The first beat (qfirst) gives the coverage, the depths and alpha to coverage's alpha (the lowest attachment exported: attachment 0's when it is exported; Vulkan leaves the alpha undefined otherwise); a later beat goes IDLE → OUT with the first's o_smask and o_sdepth, or is dropped with it; alpha to one applies to every beat.  Checked by `sim/tb/ad_rop_beat_tb.v` (spec ad_rop.md §8); the earlier TBs drive single beats unchanged.

2026-11-08 (rebuild in this tree, `rtl/rop/ad_rop_ms.v` with leaves `rtl/rop/ms/ad_ms_a2c.v` (alpha to a 4-bit sample mask and the one-sample alpha >= 0.5 rule), `ad_ms_zclamp.v` (clamp01 then the [min, max] clamp of one fp32), `ad_ms_cov.v` (the sample mask)).  Checked by `sim/tb/ad_rop_ms_tb.v`, the module alone against `tools/ms_model.py` (`sim/vec/ms_in.hex`, `ms_exp.hex` from `tools/gen_ms_vectors.py`) with random input gaps and o_ready back-pressure: `PASS ad_rop_ms.depth`, `.a2c`, `.beats`, `.bypass1x`, `PASS ad_rop_ms` (the whole-ROP TB of §8 is the integrator's); `-DMUT_A2C_STEP` fails `.a2c`.  Formal: `formal/ad_ms_a2c`, `formal/ad_ms_zclamp`, `formal/ad_ms_cov` (bmc and prove) and `formal/ad_rop_ms` (control properties with ad_fp_add blackboxed; bmc 24, prove, cover).

- ASSUMPTION: d_s (i_aux[147:20]) holds four fp32 sample offsets shared by the four lanes: sample s's offset at d_s[32 s +: 32]; sample s of lane l = clamp01(fadd(i_depth[32 l +: 32], d_s[32 s +: 32])).
- ASSUMPTION: a lane with zexp takes its exported depth for all four samples with no clamp01 (only the DEPTH_CLAMP[0] clamp); with DEPTH_CLAMP[1] a NaN sum stays NaN (then the minimum if DEPTH_CLAMP[0]).
- ASSUMPTION: clamp01 maps NaN and every value with the sign bit set (-0 and negative denormals included) to +0, values above 1.0 (+inf included) to 1.0, and leaves the rest (positive denormals included, compares by ad_fp_cmp) unchanged.
- ASSUMPTION: min/max of the viewport: lo = (f < n) ? f : n, hi = (f < n) ? n : f (ad_fp_cmp).  With a NaN bound the compares against it are false, so only NaN depths get lo.  f has its own ad_fp_add (STATE writes never compete with Z); f is registered the cycle after the write of 0x054 or 0x055.
- ASSUMPTION: MS_CTRL[3:0] other than 2 is one sample.  In one-sample mode o_sdepth's words 4 l + s, s > 0, are 0; in four-sample mode all 16 words are computed whatever the mask.
- ASSUMPTION: alpha to coverage reads the first beat's i_color[128 l + 96 +: 32]; a later beat takes the first's o_smask unchanged (not and-ed with its own i_mask); alpha to one rewrites channel 3 of every lane of every beat (not i_dbg).  A later beat with no kept first beat (after reset, or after a dropped first) is dropped.  i_aux qlast is not used.
- ASSUMPTION: STATE writes come while the module is idle (busy = 0) and MS_CTRL does not change between the beats of a quad.
- Latency (actual): one sample and later beats 2 cycles (accept, OUT); four samples 19 cycles (accept, Z = 17 cycles: 16 adds one per cycle through one ad_fp_add, its result registered once, then the clamps, OUT), not 22.  i_ready only in IDLE: one idle cycle between beats.
