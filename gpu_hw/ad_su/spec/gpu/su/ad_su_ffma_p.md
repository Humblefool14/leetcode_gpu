# ad_su_ffma_p

RTL: `rtl/su/fp/ad_su_ffma_p.v`.  Parents: ad_su_fpu_op (one per lane of ad_su_fpu).

## 1. Purpose and place

The fused fp32 multiply-add of one lane, y = round(a × b + c) with one rounding, given the product of the significands from the parent's multiplier ("_p").  Every fp32 add/sub/mul/fma of ad_su_fpu and fract go through it.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `a` | in | 32 | Multiplicand (fp32, a denormal is a zero of its sign). |
| `b` | in | 32 | Multiplier. |
| `c` | in | 32 | Addend (ignored when noc). |
| `rm` | in | 3 | Rounding: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 5–7 RNE. |
| `noc` | in | 1 | No addend (fmul): y = round(a × b), the sign of a zero product kept under every rm. |
| `pm` | in | 48 | {ea ≠ 0, a[22:0]} × {eb ≠ 0, b[22:0]} (the parent's multiplier). |
| `y` | out | 32 | Result. |

7 ports.

## 4. Behaviour

Exactly tools/gsi1fp.py `fma(F32, a, b, c, rm, noc)`:
- operands flushed; a NaN operand (c only without noc), inf × 0 and inf × x + (−inf of the other sign) give 0x7FC00000; inf × x gives the inf of sa ⊕ sb; a finite product + inf c gives c;
- a zero product: noc → zero of sa ⊕ sb; zero c → zero of (sa ⊕ sb) ∧ sc, or ∨ under RDN; otherwise c;
- otherwise the exact sum, rounded once under rm at 24 bits with an unbounded exponent: an exact zero sum is +0 (−0 under RDN); a biased exponent ≥ 255 after rounding is ±inf (RNE, RMM and the rounding away from zero) or ±0x7F7FFFFF (RTZ and the rounding toward zero); a biased exponent ≤ 0 after rounding is a zero of the result's sign (no denormals).

Datapath: a 76-bit window, the product at W[48:1], the addend's 24-bit significand at W[74:51] shifted right by sh = ea + eb − ec − 100 (clamped to 0..76; bits shifted below W[0] ORed into W[0]).  When sh < 0 the product is below a quarter of the addend's ulp and only sets the rounding direction (two bits of gap); W[1]'s exponent is then ec − 200, otherwise ea + eb − 300.  Effective subtraction takes the magnitude of the difference and the sign of the larger; a leading-one count normalizes (cancellation of any depth is exact), then 24 bits + guard + sticky are rounded.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

As §4; a product of normals is never zero, so pm[47:46] ≠ 0 whenever a and b are normal (the leaf relies on that for the sign of a non-zero result only).

## 8. What the TB checks

`sim/tb/ad_su_fp_leaf_tb.v` prints `PASS ad_su_fp_leaf.ffma_p`: 200,000 vectors of `tools/gen_fpu_vectors.py` (`sim/vec/fpu_ffma.hex`: random operands, near-cancellation, products near the bottom and the top of the normal range, every rm 0–7, noc 20 %) against gsi1fp.fma; then the leaves' other lines and `PASS ad_su_fp_leaf`.

## 9. References

tools/gsi1fp.py (fma, Fmt.round), ad_su_fpu.md, ad_su_fpu_op.md.

## 10. Status

2026-11-08: implemented; leaf TB 200,000 vectors 0 differences; through ad_su_fpu_tb 0 differences.  Formal `formal/ad_su_ffma_p/` (combinational, anyconst): commutativity of a and b on the same free pm (with pm[47:46] ≠ 0), x × 1 ± 0 = x and x × 1 (noc) = x for normal x under every rm (pm the exact product), 0 × x + c = c for normal c, the zero-sign rule of 0 × x + 0, the sign of a × b for noc and for c = 0, canonical NaN, never a denormal: bmc abc bmc3 depth 1 PASS, prove abc pdr PASS.  `formal/ad_su_fadd/` task equiv proves ad_su_fadd(a, b) = ad_su_ffma_p(a, 1.0, b, RNE) for all inputs.  Mutation `MUT_FFMA_DENORM` (tiny results kept as denormals) fails the leaf TB (7,326 of 200,000) and the formal bmc.
- ASSUMPTION: the multiplier is outside (the parent's DSP); the commutativity proof therefore covers the alignment/sign/exponent logic with a shared product, not the multiplier (a multiplier commutativity proof at 24 × 24 is out of SAT reach here and is a property of `*`).
