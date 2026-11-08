# ad_rop_wpix

RTL: `rtl/gpu/rop/ad_rop_wpix.v` (new).  Parent: ad_rop_wb.  Child: `ad_rop_fblend`.

## 1. Purpose and place

The pixels of `ad_rop_wb` (CAPS[30], docs/ghci.md §8.5): the colour attachments' state, the place of each pixel of a beat in the lines, the choice of the blend path and the new pixel bytes.  No state machine of its own; it holds `ad_rop_fblend`.  Split off `ad_rop_wb` for the line limit (design §16.7).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, reset. |
| `st_we`, `st_idx`, `st_wdata` | in | 1, 9, 32 | STATE; the module keeps RT_BASE, RT_STRIDE, RT_FORMAT, BLEND, BLEND_CONST, WRITE_MASK, RT_FORMATS, RT1-3_BASE/STRIDE, BLEND1-3, BLEND_CONST_R-A, ROP_CTRL[1], MS_CTRL. |
| `i_xy`, `i_rt`, `i_smask`, `i_color` | in | 32, 2, 16, 512 | The beat (ad_rop_wb's copy): position, attachment, surviving samples (bit 4 l + s), colours. |
| `i_r`, `i_j`, `i_g` | in | 1, 2, 2 | The place: row, line of the row (several lines), pass (one line: the sample). |
| `i_line0`, `i_line1` | in | LINE_BYTES*8 each | The two entries' lines. |
| `i_off0`, `i_off1` | in | LINE_SHIFT each | The quad's first byte in each row's line. |
| `b_pix` | in | 128 | ad_rop_blend's result (path 0). |
| `f_go` | in | 1 | Start ad_rop_fblend on the current slots (path 1; it is idle). |
| `f_done` | out | 1 | ad_rop_fblend's result is there. |
| `f_take` | in | 1 | ad_rop_wb takes it (ad_rop_fblend's o_ready). |
| `o_addr` | out | 32 | The row's address (r = i_r), plus i_j lines with several lines. |
| `o_nl`, `o_np`, `o_multi` | out | 2, 2, 1 | Lines of a row − 1 (several), passes − 1 (one line), several lines. |
| `o_drop`, `o_read`, `o_path` | out | 1, 1, 2 | Nothing to write; the old pixels needed; the path (0 ad_rop_blend, 1 ad_rop_fblend, 2 the packing). |
| `o_lw`, `o_mask` | out | 1, 4 | The row (one line) or the line (several) has a surviving slot; the pass's slots. |
| `o_bsrc`, `o_bdst` | out | 512, 128 | The slots' sources and 32-bit destinations (to ad_rop_blend). |
| `o_res` | out | 512 | Slot k's new pixel at [128 k], ps bytes. |
| `o_ent`, `o_soff`, `o_ps` | out | 4, 4*LINE_SHIFT, 5 | Slot k's entry, its byte in the line, the pixel's bytes. |

35 ports.

## 4. Behaviour

- **Format**: RT_FORMATS byte i_rt, or for attachment 0 with that byte 0 the earlier RT_FORMAT code (0 B8G8R8A8_UNORM, 1 R8G8B8A8_UNORM, 2 and 3 R5G6B5_UNORM_PACK16).  ps = 1, 2, 4, 8 or 16 bytes (`ad_fmt_info`).  o_drop: the format lacks the colour-attachment feature (an absent attachment's 0 included), or the write mask has no channel of the format.  o_read: blend enabled for a blending format, or a write mask without every channel of the format.
- **Places**: S = 4 with MS_CTRL[3:0] = 2, else 1; sample s of pixel x at (S x + s) ps of the row, the row at RTk_BASE + y RTk_STRIDE.  A quad's row is 2 S ps bytes: one line when 2 S ps ≤ LINE_BYTES, else (o_multi) 2 S ps / LINE_BYTES whole lines (only with S = 4).
  - One line: pass g's slot k is lane k, sample g, in entry k >> 1 at i_off + (S (k & 1) + g) ps.
  - Several lines: line j of row r holds the slots n = E j + k for k < E = LINE_BYTES / ps (lane 2 r + n / 4, sample n mod 4) at byte k ps of entry r; one pass.
  - A slot is in o_mask when its sample survived (i_smask).
- **Paths**: 0 ad_rop_blend: B8G8R8A8, R8G8B8A8, A8B8G8R8, R5G6B5, R8, R8G8, A1R5G5B5 (UNORM); its result is the slot's 32-bit lane (the bytes above ps unused).  1 ad_rop_fblend: R8G8B8A8_SRGB, B8G8R8A8_SRGB, A8B8G8R8_SRGB, A2B10G10R10_UNORM, R16, R16G16, R16G16B16A16_SFLOAT; the constant is BLEND_CONST_R-A with ROP_CTRL[1], else BLEND_CONST's bytes / 255; o_res = raw where written, the old bits where kept.  2 the packing (`ad_fmt_pack` of the 24 formats, one a lane; no conversion) of the source alone: the integer formats and R32, R32G32, R32G32B32A32_SFLOAT (Vulkan does not blend them; BLEND's enable is ignored); the same merge.

## 5. State machine

None (ad_rop_fblend has its own).

## 6. Latency and throughput

Combinational from the inputs to o_* (the paths' results come from their units).

## 7. Corner cases and errors

- `-DMUT_WPIX_LINE` (several lines: the line index left out of o_addr) and `-DMUT_WPIX_KEEP` (the packing's kept bits not merged) fail `ad_rop_mrt`.

## 8. What the TB checks

Through `sim/tb/ad_rop_mrt_tb.v` (spec ad_rop_wb.md §8).

## 9. References

docs/ghci.md §8.5 (ROP range, the colour formats), design §16.7; spec ad_rop_wb.md, ad_rop_blend.md, ad_rop_fblend.md, ad_fmt.md.  Values referenced: Vulkan specification, Blending (formats without blending), Fixed-Point Data Conversions, Required Format Support.

## 10. Status

Implemented 2026-10-25 (CAPS[30], colour attachments).  The design's text had wpix without a child; ad_rop_fblend sits here so that ad_rop_wb stays within 40 ports.

2026-10-25 (area): the old pixel of a slot (o_bdst, the fblend destination, the kept bits of path 2) is read from the 16-byte block of its offset and then its ps bytes there, the offset being a multiple of ps as docs/ghci.md section 8.5 requires (as ad_rop_wb, whose merge ignores the low bits of an offset that is not); the bytes above ps are 0 (before, the next bytes of the line; no path uses them).

WS288 p037 (2026-10-25): path 2's packing is one ad_fmt_pack a lane (the former function, one call a lane); the behaviour is unchanged (equal to the former module on random cycles, scratch harness).

2026-11-08 (rebuilt in this repository: `rtl/rop/ad_rop_wpix.v`; leaves `rtl/rop/ad_fmt_info.v` (format table), `rtl/rop/ad_fmt_pack.v` (path 2), `rtl/rop/wpix/ad_wpix_place.v` (places), `rtl/rop/wpix/ad_wpix_old.v` (old pixels)).  TB `sim/tb/ad_rop_wpix_tb.v` (PASS places, pack) against `tools/wb_model.py` `wpix_eval` for every path-2 format, S = 1 and 4, LINE_BYTES 32 and 64.  Formal: `formal/ad_fmt_info/`, `formal/ad_fmt_pack/`, `formal/ad_rop_wpix/` (ad_rop_fblend black-boxed).  `-DMUT_WPIX_LINE` is in ad_wpix_place, `-DMUT_WPIX_KEEP` in ad_rop_wpix.
- ASSUMPTION: o_addr = RTk_BASE + (y + i_r) RTk_STRIDE + S x ps (+ i_j LINE_BYTES with o_multi), the quad row's first byte, modulo 2^32.
- ASSUMPTION: o_res holds all three paths: path 0 = b_pix's 32-bit lane k (zero-extended), path 1 = (o_raw & ~o_keep) | (old & o_keep) of ad_rop_fblend's lane k (64 bits), path 2 = the packing merged the same way; ad_rop_wb merges o_res whatever the path.
- ASSUMPTION: o_path = 3 for an unsupported format; o_mask, o_lw, o_ent, o_soff do not depend on o_drop.  o_nl = 0 with one line a row; o_np = S − 1 in both cases; with several lines the slots k >= E have mask 0, offset 0 and entry i_r.
- ASSUMPTION: with one sample (MS_CTRL[3:0] != 2) only i_smask bits 4 l count.
- ASSUMPTION: RT_FORMAT codes above 3 (attachment 0 with RT_FORMATS byte 0) are unsupported (dropped).
- ASSUMPTION: f_go is raised only when ad_rop_fblend is idle (ad_rop_wb waits for f_done), so ad_rop_fblend's i_ready is not used.
- ASSUMPTION: the fblend destination (i_dst) is the slot's old pixel (ps bytes, zero-extended to 64 bits); its i_lanes = o_mask, i_src = the slots' sources (o_bsrc).
- Formal status (2026-11-08): `formal/ad_fmt_info` and `formal/ad_fmt_pack` (abc bmc3 depth 1, abc pdr: proven) — table consistency, ps in {1,2,4,8,16}, keep/raw beyond ps, R32 raw = source, write mask 0 keeps all, per-channel keep/raw.  `formal/ad_rop_wpix` (abc bmc3 depth 4; abc pdr at LINE_BYTES 32 and 64: proven; ad_rop_fblend black-boxed): unsupported format => o_drop, ps legal, o_multi exactly when 2 S ps > LINE_BYTES, o_np, masked slots' offsets multiples of ps inside the line and inside the quad row (aligned rows), slots of a pass in one entry distinct, o_mask a subset of i_smask's samples, entries.

2026-11-08 (design review): o_read is also set when a logic op is enabled for the attachment on path 0 (ROP_CTRL[2] or LOGIC_OP byte k bit 0); before, a logic op with blending off and a full write mask combined the source with a stale line entry.  wpix now keeps ROP_CTRL[2] and LOGIC_OP.  Checked by `sim/tb/ad_rop_lop_tb.v`.  LIMITATION: logic ops apply only to the path-0 formats; the integer formats (path 2) and A2B10G10R10_UNORM (path 1) are written as a plain copy (roadmap).
