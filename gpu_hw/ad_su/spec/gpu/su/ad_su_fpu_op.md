# ad_su_fpu_op

RTL: `rtl/gpu/su/ad_su_fpu_op.v`.  Parents: ad_su_fpu (one per lane).

## 1. Purpose and place

One lane's operation of ad_su_fpu, given its multiplier's product; it replaces the function `fpu` of ad_su_fpu (tools/gsi1fp.py).  Written with the shared arithmetic (docs/style.md, "Arithmetic").

## 2. Parameters

None.

## 3. Ports

`o` (5: AD_FPU_*), `ia`, `ib`, `ic` (32 each), `irm` (3), `ist` (sat), `pr` (64: the low bits of the lane's 33 × 33 product, ad_su_fpu's mulops) / `res` (32): 8 ports.

## 4. Behaviour

The operations share one ad_su_rint (fround, fract under RDN, fcvt.w*), one ad_su_i2f (fround and fract with RNE from the rounded integer, fcvt.s.w* with the uop's rm from the magnitude, 0 − a by am_sub for a negative fcvt.s.w) and one ad_su_ffma_p: fadd = a × 1 + b, fsub = a × 1 − b, fmul = a × b without an addend, the fmadd family with the negations of a and c, fract = a × 1 − fround(a, RDN) with RNE.  ad_su_f2i gives fcvt.w(u).s from the shared rounded integer.  fmin, fmax, fsgnj, the compares (all ones or 0) and mul, mulh* (pr) are as ad_su_fpu's spec says; sat clamps the float results.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

As ad_su_fpu.

## 8. What the TB checks

Through ad_su_fpu: `sim/tb/ad_su_fpu_tb.v` and `ad_su_pk_tb.v` (PK_SHARED), and ad_su_fpu against the former version (the function) for 200,000 cycles of random FPU and packed operations, with and without PK_SHARED, every output compared, 0 differences (2026-10-25).

## 9. References

design §3.1 (precision), tools/gsi1fp.py.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).

2026-11-08 (rebuild in ad_su, rtl/su/ad_su_fpu_op.v): equal to tools/gsi1fp.py fpu(o, ia, ib, ic, irm, ist) bit for bit (ad_su_fpu_tb: 67,648 lane vectors, 0 differences).  Datapath: ad_su_ffma_p with a = ia (negated for fnmsub/fnmadd), b = 1.0 for fadd/fsub/fract else ib, c = ib / −ib / ic / −ic / −fround(ia, RDN), noc for fmul, rm = RNE for fract else irm, pm = pr[47:0]; ad_su_rint on ia (rm RDN for fract, else irm); ad_su_i2f on ia (fcvt.s.w/wu, irm) or on the rounded magnitude (uns, RNE: exact below 2^24) whose sign is then that of ia (fround keeps the sign of a zero result; fround of a NaN is 0x7FC00000, of zero, inf and |x| ≥ 2^23 the flushed x); ad_su_f2i from the same rint outputs; fmin/fmax/compares on the flushed operands with the key {s ? ~x : x | 2^31} (−0 < +0 for min/max, ±0 equal for compares); sat on the float-result ops (FLOAT_RESULT of gsi1fp: fadd..fmax, fcvt.s.w*, fround, fract) only.
- ASSUMPTION: `pr` is the low 64 bits of `$signed(ma) * $signed(mb)` with ma/mb from ad_su_fpu_mulops (spec ad_su_fpu.md §10); the fused datapath reads only pr[47:0].
- ASSUMPTION: o = 24..31 gives 0 (not a float result).
Formal `formal/ad_su_fpu_op/`: see ad_su_fpu.md §10 (bmc abc bmc3 depth 1 PASS, prove abc pdr PASS).
