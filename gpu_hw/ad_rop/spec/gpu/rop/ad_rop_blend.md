# ad_rop_blend

RTL: `rtl/gpu/rop/ad_rop_blend.v`.  Parent: ad_rop.  Children: `ad_rop_f2u8` (fp32 to unorm8), `ad_rop_div255` (round(x / 255)).  Implemented in: p007.

## 1. Purpose and place

ROP blend: converts fp32 colour to the render-target format, blends with the destination pixels (BLEND factors and ops, BLEND_CONST), applies WRITE_MASK; a fixed pipeline used by ad_rop_wb.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `LAT` | `3` | Pipeline cycles from b_valid to b_rvalid. |

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
| `b_valid` | in | 1 | Blend 4 pixels. |
| `b_src` | in | 512 | Source colours (fp32). |
| `b_src1` | in | 512 | Secondary source colours for dual-source blending (fp32). |
| `b_has_src1`| in | 1 | Dual-source blend active for this beat. |
| `b_dst` | in | 128 | Destination pixels (RT_FORMAT). |
| `b_mask` | in | 4 | Lanes. |
| `b_rt` | in | 2 | (CAPS[30]) The colour attachment of the beat: its format, BLEND word and write mask. |
| `b_rvalid` | out | 1 | Result LAT cycles later. |
| `b_pix` | out | 128 | Result pixels (RT_FORMAT; masked lanes keep b_dst). |

14 ports (12 before ws002-p002, 11 before CAPS[30]).

## 4. Behaviour

Formats BGRA8, RGBA8, RGB565 (RT_FORMAT).  Blend equation per design §2.3 BLEND (the v1 bit layout of the blitter's blend for the factors; one/zero/src alpha/one minus src alpha/dst/const).

**Dual-Source Blending (ws002-p002)**:
Supports factors 15..18 for subpixel font anti-aliasing and dual-source color output:
- 15: `VK_BLEND_FACTOR_SRC1_COLOR` ($s1_c$ for RGB, $s1_a$ for alpha)
- 16: `VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR` ($1 - s1_c$ for RGB, $1 - s1_a$ for alpha)
- 17: `VK_BLEND_FACTOR_SRC1_ALPHA` ($s1_a$ for all channels)
- 18: `VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA` ($1 - s1_a$ for all channels)
When enabled in `ROP_CTRL[7]`, high factor bits are packed into `BLEND[26:23]` (bit 23 for src_color MSB, bit 24 for dst_color MSB, bit 25 for src_alpha MSB, bit 26 for dst_alpha MSB). Subpixel font rendering uses $C_{res} = C_{text} \cdot M + C_{dst} \cdot (1 - M)$ with factor 15 on source and factor 16 on destination.

**With CAPS[30]** (the 8-bit path of the render output; ad_rop_fblend takes the other blendable formats):

- The module keeps BLEND (0x07A) and BLEND1-BLEND3 (0x084-0x086), RT_FORMAT (0x072), RT_FORMATS (0x07D), BLEND_CONST (0x07B), BLEND_CONST_R-A (0x087-0x08A), ROP_CTRL (0x08D), and LOGIC_OP (0x08E); b_rt selects the attachment's BLEND word, format (RT_FORMATS byte b_rt, or RT_FORMAT's code when attachment 0's byte is 0), and logic op configuration.
- Formats (VkFormat): 37 R8G8B8A8_UNORM, 44 B8G8R8A8_UNORM, 51 A8B8G8R8_UNORM_PACK32 (37's memory), 9 R8_UNORM, 16 R8G8_UNORM, 4 R5G6B5_UNORM_PACK16, 8 A1R5G5B5_UNORM_PACK16; pixels of 1, 2 or 4 bytes in the low bytes of each 32-bit lane of b_dst and b_pix.  Formats without alpha (R8, R8G8, R5G6B5) read a destination alpha of 255 (1.0); A1R5G5B5's alpha reads 0 or 255 and writes RNE(a / 255), so 1 from 128 up.  The missing colour channels of R8 and R8G8 read 0 and are not written.
- The constant: with ROP_CTRL[1] = 1 the fp32 BLEND_CONST_R-A, each clamped to [0, 1] and rounded to 8 bits (RNE(c × 255)) when written; with 0 BLEND_CONST's bytes as before.
- Blend enable is ignored (no blending) for a format outside this list; ad_rop_wpix sends such beats to ad_rop_fblend or packs them.
- Logic Op (ws002-p001): When `logic_op_en` is set (via `ROP_CTRL[2]` or `LOGIC_OP[0]` globally, or byte-wise in `LOGIC_OP` per RT), blend math is bypassed and the bitwise logical operation between source $s$ and destination $d$ is applied per channel before write mask and formatting:
  - 0: `CLEAR` (`8'h00`)
  - 1: `AND` (`s & d`)
  - 2: `AND_REVERSE` (`s & ~d`)
  - 3: `COPY` (`s`)
  - 4: `AND_INVERTED` (`~s & d`)
  - 5: `NO_OP` (`d`)
  - 6: `XOR` (`s ^ d`)
  - 7: `OR` (`s | d`)
  - 8: `NOR` (`~(s | d)`)
  - 9: `EQUIV` (`~(s ^ d)`)
  - 10: `INVERT` (`~d`)
  - 11: `OR_REVERSE` (`s | ~d`)
  - 12: `COPY_INVERTED` (`~s`)
  - 13: `OR_INVERTED` (`~s | d`)
  - 14: `NAND` (`~(s & d)`)
  - 15: `SET` (`8'hFF`)

## 5. State machine

A pipeline.

## 6. Latency and throughput

4 pixels per cycle.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/ad_rop_blend_tb.v` prints, in this order:

- `PASS ad_rop_blend.formats` — format conversion
- `PASS ad_rop_blend.factors` — every factor and op against a C reference
- `PASS ad_rop_blend.r8rg8` — R8, R8G8 and A1R5G5B5 with every factor (CAPS[30])
- `PASS ad_rop_blend.const` — the fp32 constants' quantization (CAPS[30])
- `PASS ad_rop_blend` at the end.

`sim/tb/ad_rop_logicop_tb.v` prints:
- `PASS ad_rop_logicop.all16` — all 16 VkLogicOp truth tables
- `PASS ad_rop_logicop.masks` — channel write masks and lane masks with logic op
- `PASS ad_rop_logicop.independent_blend` — independent blend and logic op across RT 0..3
- `PASS ad_rop_logicop.formats` — formats BGRA8, RGBA8, R8, RG8 with logic op
- `PASS ad_rop_logicop` at the end.

`sim/tb/ad_rop_dualsrc_tb.v` prints:
- `PASS ad_rop_dualsrc.factors` — dual source blend factors 15..18
- `PASS ad_rop_dualsrc.subpixel_font` — subpixel font anti-aliasing
- `PASS ad_rop_dualsrc.masks` — channel write masks and lane masks with dual source
- `PASS ad_rop_dualsrc.formats` — formats RGBA8, BGRA8 with dual source
- `PASS ad_rop_dualsrc` at the end.

## 9. References

design §2.3 (BLEND, WRITE_MASK).

## 10. Status

2026-10-24 Q1 (P3's p007 decisions, ACKed; ghci.md to follow): stencil ops are not implemented in v1 (the ROP gets no facing bit; a port change belongs to p009). STATE bits: SCISSOR_MIN/MAX `{y, x}` (MAX 0 = none), RT_SIZE `{h, w}`, CULL [1:0] 1 front/2 back/3 both and [2] front = CCW, DEBUG_COLOR and BLEND_CONST RGBA8 (R in [7:0]), BLEND [0] enable, [4:1] src colour, [8:5] dst colour, [11:9] colour op, [15:12] src alpha, [19:16] dst alpha, [22:20] alpha op (VkBlendFactor/VkBlendOp numbers), WRITE_MASK [3:0] RGBA (0 writes nothing), DEPTH func = VkCompareOp and no test without a depth format bit; DS_BASE/RT_BASE/stride aligned to 8 bytes (4 for RGB565). The CP sequencer holds a SET_REG into the RX range (0x050–0x06F) while RX or ROP is busy and into the ROP range (0x070–0x08F) while the ROP is busy.

Implemented in p007 (the three RT_FORMAT codes).  2026-10-25: this spec adds the CAPS[30] form (b_rt, the VkFormat list, R8, R8G8, A1R5G5B5, the fp32 constants); implemented the same day: `.r8rg8` and `.const` from `sim/vec/rop_blend2.txt` (`tools/rop-vectors.py`, the model `blend_pixel8` in `tools/rxmodel.py`; a format outside the list writes nothing), the earlier vectors unchanged; ad_rop wires b_rt to 0 until the attachments' beats exist (S8 of the plan).  The pipeline carries the attachment's BLEND word, format, write mask and constant with the beat.

2026-10-26 (Phase 014): Stage 2 multiplier count halved from 32 to 16 (1 multiplier per channel). Standard alpha blend (SRC_ALPHA, ONE_MINUS_SRC_ALPHA) and related modes are optimized using linear interpolation (Lerp: $D + (S - D) \cdot \alpha = D \pm \text{div255}(|S - D| \cdot \alpha)$) with unsigned multiplication. Coupled with the single-stage `ad_rop_div255` adder, critical path delay is reduced by ~75%.

2026-10-27 (Phase ws002-p001): 16 `VkLogicOp` operations implemented in Stage 3, decoded from `GHCI_S_ROP_CTRL` (0x08D) and `GHCI_S_LOGIC_OP` (0x08E). Independent blend and logic op across RT 0..3 supported. Dedicated testbench `sim/tb/ad_rop_logicop_tb.v`.

2026-10-27 (Phase ws002-p002): Dual Source Blending (factors 15..18) implemented for subpixel font rendering and dual-source color blending. Secondary color output `b_src1` and `b_has_src1`. Dedicated testbench `sim/tb/ad_rop_dualsrc_tb.v`.

2026-11-08 (rebuild in this tree, `rtl/rop/ad_rop_blend.v`): leaf IPs in `rtl/rop/blend/`: `ad_blend_state` (STATE snooping, per-RT selection), `ad_blend_pipe` (3-stage datapath: stage 1 f2u8 + unpack, stage 2 factors + 8x8 products, stage 3 div255/VkBlendOp, logic op, pack, write/lane mask), `ad_blend_unpack8`, `ad_blend_pack8`, `ad_blend_factor8`, `ad_blend_op8`, `ad_blend_logicop`.  Blend terms are computed exactly as ts = div255(s*Fs), td = div255(d*Fd) with 32 multipliers (the Phase 014 lerp form is not used: it is not bit-identical to the integrator's equation).  Model `tools/blend_model.py`, vectors `tools/gen_blend_vectors.py` -> `sim/vec/blend_*.hex` (11644 random/directed beats over the three TBs, all PASS).  Formal: `formal/ad_blend_{unpack8,pack8,factor8,op8,logicop,state}` (bmc + prove) and `formal/ad_rop_blend` (whole block: bmc, abc pdr prove; pipeline with free state: k-induction).  Mutation `MUT_FACTOR_SWAP` (SRC_COLOR <-> DST_COLOR in ad_blend_factor8) fails ad_rop_blend_tb and formal/ad_blend_factor8.
- ASSUMPTION: LOGIC_OP byte k = {[7:5] ignored, [4:1] VkLogicOp, [0] enable}; logic op enabled for RT k by ROP_CTRL[2] | LOGIC_OP[8k] (§4's "LOGIC_OP[0] globally" read as the RT0 byte's enable only), op always from byte k.
- ASSUMPTION: logic op works on the packed pixel bits: p = pack(f2u8(src)) to the RT's format, result = LOGICOP(p, dst lane), then write mask / pixel size / lane mask keep b_dst (for R5G6B5/A1R5G5B5 the op is on the 16 packed bits, not per 8-bit channel).
- ASSUMPTION: RT_FORMAT legacy code (RT0 when RT_FORMATS byte 0 is 0) compares the whole word: 0 -> 44 B8G8R8A8, 1 -> 37 R8G8B8A8, 2 or 3 -> 4 R5G6B5, any other value -> not written (format outside the list).  It is decoded and stored as a VkFormat when written (reset value = 44, the decode of 0).
- ASSUMPTION: a STATE write in the same cycle as b_valid affects only later beats (the beat captures the registers' old values); state is captured with the beat, so later writes never affect beats in flight.
- ASSUMPTION: BLEND_CONST_R-A are converted by ad_rop_f2u8 when written and both those 8-bit values and BLEND_CONST are kept; ROP_CTRL[1] selects at use (write order does not matter).
- ASSUMPTION: factor = {BLEND MSB, 4 bits} only with ROP_CTRL[7], else {0, 4 bits}; 15..18 are SRC1_* only with ROP_CTRL[7]; 15 without it and 19..31 read ZERO.  s1 = 0 when b_has_src1 = 0 (so ONE_MINUS_SRC1_* read 255).  VkBlendOp 5..7 = ADD; MIN/MAX ignore the factors.
- ASSUMPTION: blend disabled -> result = f2u8(src) packed; a format outside the 7-format list writes nothing (b_pix lane = b_dst) whether blend / logic op is on or not.
- ASSUMPTION: LAT is fixed at 3 by the datapath; LAT > 3 adds output delay registers, LAT < 3 behaves as 3.
- Status: all three TBs PASS; all formal tasks PASS (see the formal directories).
