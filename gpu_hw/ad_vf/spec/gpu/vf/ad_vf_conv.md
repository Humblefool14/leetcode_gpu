# ad_vf_conv

RTL: `rtl/gpu/vf/ad_vf_conv.v`.  Parent: ad_vf.  Implemented in: p009.

## 1. Purpose and place

VF format conversion: turns raw attribute bytes (R32F … RGBA16F, RGBA8 UNORM/UINT, R32/RG32 UINT) into 32-bit words and writes them into the SU's registers at ATTR_DST[k].

## 2. Parameters

None.

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
| **Attribute data (ad_vf_fetch → ad_vf_conv)** | | | |
| `af_valid` | in | 1 | One attribute of one vertex. |
| `af_ready` | out | 1 | Taken. |
| `af_attr` | in | 4 | Attribute k. |
| `af_lane` | in | 5 | Lane. |
| `af_raw` | in | 128 | Raw bytes (up to 16), byte 0 in [7:0]. |
| `af_oob` | in | 1 | (CAPS[30]) The attribute is outside its ATTR_LIMIT: write (0, 0, 0, 1). |
| `af_last` | in | 1 | Last attribute of the last lane of the warp. |
| **Register writes to the SU (ad_su vl_*)** | | | |
| `vl_we` | out | 1 | Attribute word. |
| `vl_reg` | out | 6 | Register (ATTR_DST[k] + component). |
| `vl_lane` | out | 5 | Lane. |
| `vl_data` | out | 32 | Data (converted to 32 bits). |
| `conv_done` | out | 1 | One-cycle pulse after the warp's last word. |

16 ports.

## 4. Behaviour

An af is taken whole, with ATTR[k]_DESC[19:16] (format) and ATTR_DST[k] as they are then; its ATTR_DST count of words go out one per cycle on vl_* (registered), register ATTR_DST[5:0] + c (mod 64), and the next af is taken in the cycle of the current one's last word.  Formats of design §2.3 ATTR_DESC[19:16]: fp32 and uint32 words as they are; fp16 → fp32 exactly (denormals become normal fp32, NaN → 0x7FC00000); UNORM8 → float (x/255, round to nearest even, include/ad_rop_unorm8.vh); UINT8 → integer.  Components beyond the format's count and up to ATTR_DST's count are filled with (0, 0, 0, 1) (1.0 for the float formats, 1 for RGBA8_UINT, R32_UINT and RG32_UINT); the reserved formats 10-15 have no data components (all filled).  ATTR_DST's count below the format's writes the first components only.  An attribute whose ATTR_DST word is 0 is disabled (ad_vf_fetch §4) and writes nothing.

With CAPS[30] and ATTR_DST[k][31:24] ≠ 0 the VkFormat decides instead of ATTR_DESC[19:16]: `ad_fmt_comp` (every format with the vertex-buffer feature: 8-, 16- and 32-bit UNORM, SNORM, UINT, SINT and SFLOAT, B8G8R8A8_UNORM, A2B10G10R10_UNORM; integer formats write their integer bits); a value without the feature reads (0, 0, 0, 1.0).  An attribute with `af_oob` (outside its ATTR_LIMIT) writes (0, 0, 0, 1) in the format's kind (integer 1 for integer formats).  The new input `af_oob` (1 bit, with af_*).

## 5. State machine

IDLE → WRITE (components) → IDLE; the next af enters WRITE in the cycle of the last word.

## 6. Latency and throughput

One register word per cycle.

## 7. Corner cases and errors

- conv_done pulses the cycle after the last word of the af with af_last, or two cycles after taking it when it writes nothing (a disabled attribute, ad_vf_fetch's dummy af).

## 8. What the TB checks

`sim/tb/ad_vf_conv_tb.v` prints, in this order:

- `PASS ad_vf_conv.formats` — every format against the reference of `tools/vf-vectors.py` (`sim/vec/vf_conv.txt`: all 256 UNORM8 values, fp16 zeros, denormals, infinities and NaNs), fewer words than components, disabled attributes
- `PASS ad_vf_conv.fill` — missing components get 0,0,0,1 (also the reserved formats)
- `PASS ad_vf_conv.vkformats` — every VkFormat value 0-255 against tools/fmtmodel.py (`sim/vec/vf_conv_vk.txt`, also from `tools/vf-vectors.py`: many texels of each vertex-buffer format, extreme field codes and float specials; values without the feature read (0, 0, 0, 1.0)) (CAPS[30])
- `PASS ad_vf_conv.oob` — af_oob writes (0, 0, 0, 1)
- `PASS ad_vf_conv` at the end.

The attributes of a batch go back to back; every word and the single conv_done after the batch's last word are checked.

## 9. References

design §2.3, §3.4.3 (ATTR_DST).

## 10. Status

Implemented in WS288 p009 part A (branch p1-vf).  Readings: the reference is the Python model `tools/vf-vectors.py` (the text said "a C reference"); fp16 converts exactly with denormals (the SU's `ad_su_h2f` flushes them; an attribute is data, not an fp16 operand); the reserved formats fill (0, 0, 0, 1.0).  Ports and parameters unchanged.  2026-10-25 (CAPS[30], spec first, the RTL follows): the VkFormat path through `ad_fmt_unpack` and the input `af_oob` (§3, §4); implemented the same day, every PASS of §8.  The attribute is enabled when ATTR_DST[31:24] or [7:0] is not 0 (as ad_vf_fetch).

2026-10-25 (area): the VkFormat path converts the one component of the cycle (ad_fmt_comp), not all four; the words are unchanged.

2026-10-25 (p037, P3): the component of the cycle is one ad_fmt_comp instance, which also converts the fp16 formats 6 and 7 (as R16G16B16A16_SFLOAT: the same exact fp16 to fp32; the two paths are never needed in the same cycle), in place of the function and the module's own fp16 converter; the words are unchanged (equal to the former module on 300,000 random cycles).

2026-11-09 (rebuild in /home/claude/ad_vf, rtl/vf/ad_vf_conv.v): leaves in rtl/vf/fmt/: `ad_vf_fmt_desc` (format -> {ncomp, kind, field width, B8G8R8A8 swizzle}; the spec's ad_fmt_unpack), `ad_vf_fmt_comp` (component i of the cycle; the spec's ad_fmt_comp), `ad_vf_fmt_h2f` (fp16 -> fp32 exact), `ad_vf_fmt_unorm #(N)` (N = 2, 8, 10, 16: c / (2^N - 1) RNE without a divider: the significand is c's bit pattern repeated from its leading one, round bit next, sticky always 1), `ad_vf_fmt_snorm #(N)` (N = 8, 16, through unorm N-1).  Reference: `tools/fmtmodel.py` (the spec's `tools/vf-vectors.py`); vectors `tools/gen_conv_vectors.py` -> `sim/vec/vf_conv.txt`, `vf_conv_vk.txt`, `vf_conv_<leaf>.hex`.  TB `sim/tb/ad_vf_conv_tb.v`: every PASS of section 8 (19,885 afs: all 256 UNORM8 codes, fp16 specials and a sweep, every legacy code x every count, every VkFormat 0-255 with 24+ random texels, extreme field codes, float specials, oob, disabled, back to back with random gaps; every word, af_ready in every cycle and every conv_done checked to the cycle) plus every leaf exhaustively (198,148 values).  Formal: leaves proven (abc pdr) against references written another way (multiply-check bracket for UNORM/SNORM, exact-value check for h2f, generated fmtmodel table for desc, shift-based extraction for comp); block: timing/count/conv_done proven (abc pdr), legacy 32-bit and fill/oob words proven (prove_data, abc pdr).  Mutations: MUT_CONV_RND (unorm truncates), MUT_CONV_SWZ (B8G8R8A8 not swizzled), MUT_CONV_CNT (one word short): TB and formal FAIL.
ASSUMPTION: timing. Word 0 is converted from the af_* inputs in the take cycle: an af taken in cycle T has its n words on vl_* (registered) in T+1 .. T+n; af_ready is high when idle and in the cycle the current af's last word is on vl_* ("the cycle of the last word"); a disabled af (n = 0) occupies the single cycle T+1 (af_ready high in it).  conv_done is high in T + max(n, 1) + 1: one cycle after the last word, two cycles after taking an af that writes nothing.  Back-to-back afs give one word per cycle with no bubble.
ASSUMPTION: every af with af_last gives its own conv_done pulse (two af_last afs in a row give two pulses); af_last on an af that writes nothing still gives conv_done.
ASSUMPTION: enabled = the whole ATTR_DST word != 0 (BRIEF_COMMON; the earlier text above says [31:24] or [7:0]): e.g. ATTR_DST = 0x0000_0100 is enabled and writes one word to register 0.
ASSUMPTION: STATE indices, ATTR_DST fields ([5:0] register, [7:6] count - 1, [31:24] VkFormat) and legacy codes as rtl/include/ad_vf_state.vh (ASSUMED there); the block keeps ATTR_DESC[k][19:16] and the 16 ATTR_DST words (reset 0), and latches the format and ATTR_DST at the take (STATE writes during a transfer do not affect it).
ASSUMPTION: af_oob on a format without data components (reserved legacy code, VkFormat without the feature) writes (0, 0, 0, 1.0), as tools/fmtmodel.py.
ASSUMPTION: vl_reg / vl_lane / vl_data are meaningful only with vl_we (they hold their last value otherwise, not reset).
ASSUMPTION: the block uses its own descriptor leaf ad_vf_fmt_desc (proven equal to fmtmodel's table) rather than ad_vf_fmt_info (another builder's size/ncomp/kind table, not present when this block was built).
