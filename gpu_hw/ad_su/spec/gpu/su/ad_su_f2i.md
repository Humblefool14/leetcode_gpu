# ad_su_f2i

RTL: `rtl/su/fp/ad_su_f2i.v`.  Parents: ad_su_fpu_op.

## 1. Purpose and place

fcvt.w.s / fcvt.wu.s of ad_su_fpu: the saturation of the rounded integer that ad_su_rint gives (shared with fround and fract).

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `neg` | in | 1 | ad_su_rint neg (sign of x). |
| `mag` | in | 32 | ad_su_rint mag. |
| `big` | in | 1 | ad_su_rint big (\|x\| ≥ 2^32, inf, NaN). |
| `nan` | in | 1 | x is a NaN. |
| `uns` | in | 1 | fcvt.wu.s. |
| `y` | out | 32 | The integer. |

6 ports.

## 4. Behaviour

tools/gsi1fp.py `fcvt_ws(x, rm, uns)` (RISC-V): NaN → 0x7FFFFFFF / 0xFFFFFFFF; positive big → the same; signed: negative big → 0x80000000, rint above 2^31 − 1 → 0x7FFFFFFF, below −2^31 → 0x80000000, otherwise rint; unsigned: any negative (including −0 and values rounding to 0) → 0, otherwise mag.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

As §4.

## 8. What the TB checks

`sim/tb/ad_su_fp_leaf_tb.v` prints `PASS ad_su_fp_leaf.f2i`: 200,000 vectors (`sim/vec/fpu_f2i.hex`; x with exponents 120–161 and specials, uns 0/1, rm 0–7) through ad_su_rint + ad_su_f2i against gsi1fp.fcvt_ws.

## 9. References

tools/gsi1fp.py (fcvt_ws), ad_su_rint.md.

## 10. Status

2026-11-08: implemented; leaf TB 0 differences.  Formal `formal/ad_su_f2i/` (with ad_su_rint, combinational): NaN, ±big and inf, signed and unsigned saturation bounds, and the result equal to rint(x) inside the range: bmc abc bmc3 depth 1 PASS, prove abc pdr PASS.  Round trip with ad_su_i2f in `formal/ad_su_i2f/`.  Mutation (no positive signed saturation, a copy in /tmp) fails the formal bmc.
- ASSUMPTION: the input is ad_su_rint's output for the same x (mag meaningful only when !big).
