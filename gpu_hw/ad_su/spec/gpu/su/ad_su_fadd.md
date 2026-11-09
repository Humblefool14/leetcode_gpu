# ad_su_fadd

RTL: `rtl/su/fp/ad_su_fadd.v`.  Parents: ad_su_lane (qd: two per quad).

## 1. Purpose and place

A small fp32 adder, RNE only, for ad_su_lane's quad differences (qdx = v[lane|1] − v[lane&~1], qdy likewise): a − b is a + (b ⊕ 0x80000000), equal to tools/gsi1fp.py fpu(FSUB, a, b, 0, RNE).

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `a` | in | 32 | fp32. |
| `b` | in | 32 | fp32 (negate the sign bit for a subtraction). |
| `y` | out | 32 | a + b. |

3 ports.

## 4. Behaviour

tools/gsi1fp.py fpu(FADD, a, b, 0, RNE) = fma(a, 1, b, RNE): denormals flushed in and out (a biased exponent ≤ 0 after rounding is a zero of the result's sign), NaN operands and inf + (−inf) give 0x7FC00000, overflow gives ±inf, an exact zero sum is +0 except −0 + −0 = −0, x + ±0 = x.  Datapath: the larger magnitude at W[50:27] of a 51-bit window, the smaller shifted right by the exponent difference (clamped to 51, lost bits ORed into W[0]), add or subtract, leading-one count, RNE at 24 bits.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

As §4.

## 8. What the TB checks

`sim/tb/ad_su_fp_leaf_tb.v` prints `PASS ad_su_fp_leaf.fadd`: 200,000 vectors (`sim/vec/fpu_fadd.hex`; random, near-cancellation, near the bottom of the normal range, near overflow; b of either sign so a − b is covered) against gsi1fp.fpu(FADD, a, b, 0, RNE).

## 9. References

tools/gsi1fp.py, ad_su_lane.md §4 (qd), ad_su_ffma_p.md.

## 10. Status

2026-11-08: implemented; leaf TB 0 differences.  Formal `formal/ad_su_fadd/` (combinational): commutativity, a − a = +0 for every finite a, x ± 0 = x for normal x, the zero + zero sign, NaN cases, canonical NaN, never a denormal: bmc abc bmc3 depth 1 PASS, prove abc pdr PASS; task `equiv` (abc bmc3 depth 1, a complete check of a combinational harness): ad_su_fadd(a, b) = ad_su_ffma_p(a, 1.0, b, RNE) for all 2^64 inputs, PASS.  Mutation `MUT_FADD_ZERO` (tiny results kept as denormals) fails the formal bmc.
