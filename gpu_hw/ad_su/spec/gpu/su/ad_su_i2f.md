# ad_su_i2f

RTL: `rtl/su/fp/ad_su_i2f.v`.  Parents: ad_su_fpu_op.

## 1. Purpose and place

int32 / uint32 to fp32 under a rounding mode: fcvt.s.w and fcvt.s.wu of ad_su_fpu, and fround's integral value (the magnitude of ad_su_rint, exact below 2^24).

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `a` | in | 32 | The integer. |
| `uns` | in | 1 | 1: a is unsigned (fcvt.s.wu); 0: two's complement (fcvt.s.w). |
| `rm` | in | 3 | 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 5–7 RNE. |
| `y` | out | 32 | fp32. |

4 ports.

## 4. Behaviour

tools/gsi1fp.py `fcvt_sw(a, rm, uns)`: 0 gives +0; otherwise the magnitude is normalized by a leading-one count and rounded to 24 bits (guard and sticky) under rm with the integer's sign; the biased exponent is 158 − lz (+1 when the rounding carries, at most 159 for a uint32 near 2^32).  Never a denormal, never an overflow.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

0x80000000 signed is −2^31 exactly; 0xFFFFFFFF unsigned rounds to 2^32 under RNE/RUP/RMM.

## 8. What the TB checks

`sim/tb/ad_su_fp_leaf_tb.v` prints `PASS ad_su_fp_leaf.i2f`: 200,000 vectors (`sim/vec/fpu_i2f.hex`; full-range, short, negative and near-tie integers, uns 0/1, rm 0–7) against gsi1fp.fcvt_sw.

## 9. References

tools/gsi1fp.py (fcvt_sw), ad_su_fpu_op.md.

## 10. Status

2026-11-08: implemented; leaf TB 0 differences.  Formal `formal/ad_su_i2f/` (combinational, with ad_su_rint and ad_su_f2i): f2i(i2f(i)) = i for |i| < 2^24 (signed and unsigned) under every rm; exact below 2^24; correct rounding for every rm on the whole input range (|V − |i|| < ulp, directed modes on the right side, RNE/RMM within half an ulp, ties to even / away); +0 for 0, sign, exponent range, no denormal: bmc abc bmc3 depth 1 PASS, prove abc pdr PASS.  Mutation (sticky bit dropped, a copy in /tmp) fails the formal bmc.
