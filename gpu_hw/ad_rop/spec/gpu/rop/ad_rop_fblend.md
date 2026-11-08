# ad_rop_fblend

RTL: `rtl/gpu/rop/ad_rop_fblend.v`.  Parent: ad_rop_wpix (in ad_rop_wb, beside ad_rop_blend; ad_rop_wpix chooses the path).  Children: `ad_fmt_comp` (16), `am_fp_add` (48), `am_fp_mul` (32), `ad_fmt_f2unorm` (16), `ad_fmt_f2h` (16), `ad_fmt_pack` (4), `srgb_encode_comb`.

## 1. Purpose and place

The fp32 blend path of the render output: blending, write mask application, and packing for colour formats that the 8-bit path (ad_rop_blend) does not handle:
- sRGB formats: R8G8B8A8_SRGB (43), B8G8R8A8_SRGB (50), A8B8G8R8_SRGB_PACK32 (57)
- UNORM10: A2B10G10R10_UNORM_PACK32 (64)
- 16-bit float formats: R16_SFLOAT (76), R16G16_SFLOAT (83), R16G16B16A16_SFLOAT (97)

Processes one beat (four pixels of a quad row pair for one attachment) at a time in a high-throughput 5-stage streaming pipeline.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `i_valid` | in | 1 | A beat input. |
| `i_ready` | out | 1 | Ready to accept next beat (`!pipe_stall`). |
| `i_lanes` | in | 4 | Active pixels to write (lane k = pixel k). |
| `i_src` | in | 512 | Source colours, fp32 RGBA per lane (lane 0 R in [31:0]). |
| `i_dst` | in | 256 | Destination pixels as stored, 64 bits per lane. |
| `i_fmt` | in | 8 | The attachment's VkFormat. |
| `i_blend` | in | 23 | BLEND word [22:0]: [0] enable, [4:1] src factor, [8:5] dst factor, [11:9] colour op, [15:12] src alpha factor, [19:16] dst alpha factor, [22:20] alpha op. |
| `i_const` | in | 128 | Blend constant, fp32 RGBA. |
| `i_wm` | in | 4 | Write mask (R, G, B, A). |
| `o_valid` | out | 1 | Result beat valid. |
| `o_ready` | in | 1 | Result taken by consumer. |
| `o_raw` | out | 256 | Pixels to write, 64 bits per lane. |
| `o_keep` | out | 256 | Per bit: 1 = keep stored bit (masked components, inactive lanes, unused format bits). |

15 ports.

## 4. Behaviour

For each lane in i_lanes:
- Unpack destination `d` using `ad_fmt_comp` (sRGB R, G, B decoded to linear fp32; formats without alpha read alpha = 1.0).
- Clamping: Fixed-point targets (UNORM, sRGB) clamp source, destination, constant, and factors to [0.0, 1.0] before blending (Vulkan requirement).
- Blend operations (when `i_blend[0]` enabled):
  - Factors (VkBlendFactor 0-14): ZERO, ONE, SRC_COLOR, ONE_MINUS_SRC_COLOR, DST_COLOR, ONE_MINUS_DST_COLOR, SRC_ALPHA, ONE_MINUS_SRC_ALPHA, DST_ALPHA, ONE_MINUS_DST_ALPHA, CONSTANT_COLOR, ONE_MINUS_CONSTANT_COLOR, CONSTANT_ALPHA, ONE_MINUS_CONSTANT_ALPHA, SRC_ALPHA_SATURATE. Factor 15 reads as ZERO. "One minus x" computed via `am_fp_add`.
  - Ops (VkBlendOp 0-4):
    - 0: ADD: $P + Q = s \cdot F_s + d \cdot F_d$
    - 1: SUBTRACT: $P - Q = s \cdot F_s - d \cdot F_d$
    - 2: REVERSE_SUBTRACT: $Q - P = d \cdot F_d - s \cdot F_s$
    - 3: MIN: $\min(s, d)$
    - 4: MAX: $\max(s, d)$
    - 5-7: Treated as ADD.
- Without `i_blend[0]`, the blended colour is simply the source colour.
- Packing:
  - sRGB targets encode R, G, B components using combinational unrolled 8-step binary search (`srgb_encode_comb`).
  - UNORM components converted via `ad_fmt_f2unorm`.
  - Float components converted via `ad_fmt_f2h`.
  - Formats packed via `ad_fmt_pack`, with write mask applied.

## 5. Pipeline Architecture

The sequential 12-state FSM is replaced by a fully pipelined 5-stage streaming datapath:

- **Stage 1 (Unpack & Clamp)**:
  - Destination channels unpacked across all 4 lanes and 4 components via 16 instances of `ad_fmt_comp`.
  - Source and constant inputs clamped to [0.0, 1.0] if fixed-point format.
- **Stage 2 (Factor Generation)**:
  - Evaluates $F_s$ and $F_d$ factors for each component.
  - Computes `1.0 - x` terms and `min(A_s, 1.0 - A_d)` using `am_fp_add #(.LAT(0))`.
- **Stage 3A (Multiplication)**:
  - Computes products $P = s \cdot F_s$ and $Q = d \cdot F_d$ across all 16 channels via 32 instances of `am_fp_mul #(.LAT(0))`.
- **Stage 3B (Accumulation & Min/Max)**:
  - Computes $P \pm Q$ or $\min/\max(s, d)$ across all 16 channels via 16 instances of `am_fp_add #(.LAT(0))`.
- **Stage 4 (Encode & Pack)**:
  - Combinational sRGB encoding via `srgb_encode_comb`.
  - Component formatting via `ad_fmt_f2unorm` and `ad_fmt_f2h`.
  - Final pixel assembly and write-mask application via 4 instances of `ad_fmt_pack`.
- **Stage 5 (Output Registration)**:
  - Registers `o_raw`, `o_keep`, and manages handshake (`o_valid`, `o_ready`, `pipe_stall`, `pipe_en`).

## 6. Latency and Throughput

- **Throughput**: 1 beat / cycle (continuous streaming when `o_ready` is asserted).
- **Latency**: 5 cycles from `i_valid` to `o_valid`.
- **Backpressure**: When downstream asserts backpressure (`o_valid && !o_ready`), `pipe_stall` freezes the pipeline registers and deasserts `i_ready`.
- Peak cycles per beat reduced from 638 cycles in the sequential implementation to 5 cycles latency (1 cycle / beat sustained).

## 7. Corner cases and errors

- `i_fmt` outside supported formats: nothing is written (`o_keep` set to all ones).
- Float targets pass infinities and NaNs according to IEEE fp32 arithmetic rules.
- Write mask: masked components preserve stored destination bits bit-by-bit.

## 8. What the TB checks

`sim/tb/ad_rop_fblend_tb.v` verifies:
- `PASS ad_rop_fblend.ops`: 5 ops × 15 factors × supported formats with randomized colours, constants, and write masks against golden model.
- `PASS ad_rop_fblend.srgb`: sRGB decode, linear blend, and encode round-trip accuracy.
- `PASS ad_rop_fblend.burst`: 16-beat back-to-back burst streaming test verifying 1 beat/cycle throughput under pipelined execution.
- `PASS ad_rop_fblend` final summary.

## 9. References

- Vulkan 1.3 Specification: Blending, VkBlendFactor, VkBlendOp, VkFormat.
- `docs/ghci.md` §8.5 (ROP range, per-sample operations).
- `spec/gpu/rop/ad_rop_blend.md`, `spec/gpu/fmt/ad_fmt.md`.

## 10. Status

- Completed 2026-10-26 (Phase 015): Replaced sequential FSM with 5-stage streaming pipeline.
- Verified with `sim/run.sh ad_rop_fblend` (ops, srgb, burst all PASS).
- Passes RTL lint and arith-lint (0 non-library operators). All 7 Verilator integration scenes PASS.

### 2026-11-08 rebuild (rtl/rop/ad_rop_fblend.v, leaves in rtl/rop/fblend/)

Leaves (combinational, each with its own formal/<leaf>/): ad_fblend_unpack, ad_fblend_srgb_lut (generated), ad_fblend_h2f, ad_fblend_clamp, ad_fblend_factor, ad_fblend_minmax, ad_fblend_combine, ad_fblend_srgb_enc (generated), ad_fblend_f2h, ad_fblend_pack; shared ad_fp_add, ad_fp_mul, ad_fp_cmp, ad_f2unorm, ad_unorm2f.  Pipeline: S1 unpack+clamp, S2 factors, S3 multiply, S4 blend op, S5 encode+pack into the output registers; latency 5 (accepted beat in cycle n -> o_valid in cycle n+5 with o_ready high), 1 beat/cycle, stall = o_valid && !o_ready freezes all stages, i_ready = !stall.  Tests: `scripts/run_sim.sh ad_rop_fblend_tb` (vectors: `python3 -I tools/gen_fblend_vectors.py`, model tools/fblend_model.py).

- ASSUMPTION: file is rtl/rop/ad_rop_fblend.v (repository layout) and the children are the ad_fblend_* leaves above, not the ad_fmt_* / am_fp_* names of the header.
- ASSUMPTION: the RTL path's actual stage split (S3 multiply, S4 add/min/max, S5 encode+pack+output register) differs from §5's wording; latency and throughput are as §6.
- ASSUMPTION: dst is not clamped (its decode is already in [0,1] for fixed-point formats); factors are not clamped separately (with clamped s, d, c they are already in [0,1]).
- ASSUMPTION: clamp to [0,1] (fixed-point formats): NaN and every negative (-0 included) -> +0, > 1.0 (+inf included) -> 1.0, positive fp32 denormals pass unchanged (the multiplier flushes them).
- ASSUMPTION: MIN/MAX and SRC_ALPHA_SATURATE's min: one NaN operand -> the other operand, both NaN -> 0x7FC00000; min = (a<b) ? a : b, max = (a<b) ? b : a in ad_fp_cmp order (equal operands, e.g. +0/-0: MIN returns d, MAX returns s); operand bits pass unchanged (no denormal flush).
- ASSUMPTION: blending disabled: result = clamped src (fixed-point) / src (float), no arithmetic.
- ASSUMPTION: sRGB decode LUT[c] = fp32 RNE of the exact EOTF at c/255; encode = number of k in 1..255 with v >= T[k], T[k] = fp32 RNE of EOTF((k-0.5)/255) (NaN/negative -> 0, >= T[255] -> 255).  The power segment is evaluated with Python decimal at 60 digits and the generator asserts no value is within 1e-22 (relative) of an fp32 rounding midpoint, so the tables are correctly rounded.  encode(LUT[c]) == c for all c (proved).  sRGB alpha uses unorm2f(8) / f2unorm(8).
- ASSUMPTION: fp16 -> fp32: NaN -> 0x7FC00000 (sign and payload dropped); fp32 -> fp16: NaN -> 0x7E00, fp32 denormal inputs -> signed zero, overflow (>= 65520 after RNE) -> +-inf.
- ASSUMPTION: formats with no alpha read dst alpha 1.0 (DST_ALPHA factors use it); src alpha always comes from i_src.  R16/R16G16: dst G, B read 0.0.
- ASSUMPTION: o_raw is 0 wherever o_keep is 1 (inactive lanes, masked channels, bits beyond the format, unsupported formats).  Unsupported i_fmt values are still accepted and produce an all-keep beat.
- ASSUMPTION: VkBlendFactor values >= 15 read as ZERO (the 4-bit fields of i_blend carry 0..15, dual-source factors are not reachable here).
- Status 2026-11-08: `scripts/run_sim.sh ad_rop_fblend_tb` PASS (sections leaf_h2f, leaf_f2h, leaf_srgb_enc, ops, srgb, burst; ~75 s).  Formal (`scripts/run_formal.sh <dir>`), all bmc (abc bmc3) and prove (abc pdr) PASS: ad_fblend_{h2f,f2h,srgb_lut,srgb_enc,clamp,minmax,combine,factor,unpack,pack} (combinational, depth 2) and ad_rop_fblend (handshake with reduced datapath fv_stubs.v, bmc depth 16, pdr unbounded, cover PASS).  Mutation MUT_STALL (output stage ignores back-pressure): TB FAIL (ops, burst), formal bmc FAIL (a_tag, step 7).
