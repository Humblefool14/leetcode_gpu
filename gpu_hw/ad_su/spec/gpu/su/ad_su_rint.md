# ad_su_rint

RTL: `rtl/su/fp/ad_su_rint.v`.  Parents: ad_su_fpu_op.

## 1. Purpose and place

The integer nearest to an fp32 under a rounding mode, as sign and magnitude: the shared rounding of fround, fract (RDN) and fcvt.w(u).s of ad_su_fpu.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `x` | in | 32 | fp32 (a denormal is a zero). |
| `rm` | in | 3 | 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 5–7 RNE. |
| `neg` | out | 1 | Sign of x. |
| `mag` | out | 32 | \|rint(x)\| when !big (0 for a zero or denormal x). |
| `big` | out | 1 | \|x\| ≥ 2^32 (biased exponent ≥ 159), inf or NaN: mag is not meaningful. |

5 ports.

## 4. Behaviour

tools/gsi1fp.py `rint(F32.value(x), rm)` (magnitude): exponent ≥ 150 (integral) → m << (e − 150); otherwise the integer part of m >> (150 − e) with the half bit and the sticky bit, incremented when RNE (half and (sticky or odd)), RMM (half), RDN (negative and inexact), RUP (positive and inexact).  RTZ never increments.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

NaN is reported only through big (the caller checks NaN); the largest magnitude below big is 2^32 − 256; |x| < 2^23 rounds to at most 2^23.

## 8. What the TB checks

`sim/tb/ad_su_fp_leaf_tb.v` prints `PASS ad_su_fp_leaf.rint`: 200,000 vectors (`sim/vec/fpu_rint.hex`; exponents 110–164 with exact halves, every rm 0–7) against gsi1fp.rint (neg, big, and mag when !big).

## 9. References

tools/gsi1fp.py (rint, fround, fcvt_ws), ad_su_fpu_op.md.

## 10. Status

2026-11-08: implemented; leaf TB 0 differences.  Formal `formal/ad_su_rint/` (combinational): |rint(x) − x| < 1 on an exact 181-bit fixed point, an integral x unchanged, RTZ toward zero, RDN/RUP of positives down/up, monotonic (value(x1) ≤ value(x2) ⇒ rint(x1) ≤ rint(x2), same rm), and fround's value (the magnitude through ad_su_i2f) integral: bmc abc bmc3 depth 1 PASS, prove abc pdr PASS.  Mutation (RTZ rounding up on the half bit, a copy in /tmp) fails the formal bmc.
- ASSUMPTION: the leaf does not detect NaN; callers (ad_su_fpu_op, ad_su_f2i's `nan`) do.
