# ad_su_hrnd

RTL: `rtl/su/pk/ad_su_hrnd.v`.  Parents: ad_su_pk_half (one per half: the fma's rounding and packh's).

## 1. Purpose and place

The fp16 rounding of a normalised mantissa and exponent: one rounding to 11 significant bits under rm, then the overflow and flush rules of `Fmt.round` for F16 (tools/gsi1fp.py).

## 2. Parameters

None.

## 3. Ports

`s` (1: sign), `e` (10, signed: the biased exponent of the leading bit, value = 1.f × 2^(e−15)), `m` (13: [12] the leading 1, [11:2] the fraction, [1] the round bit, [0] the sticky bit, the OR of every lower bit), `r` (3: rm) / `y` (16): 5 ports.

## 4. Behaviour

- rm 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 5-7 RNE.  Increment: RNE round & (sticky | lsb), RMM round, RDN s & (round | sticky), RUP ~s & (round | sticky), RTZ never.
- The 11-bit mantissa plus the increment; a carry out gives mantissa 1.0 and e + 1.
- Exponent after rounding ≥ 31: RTZ, RDN of a positive and RUP of a negative give the largest finite (0x7BFF with the sign), the others the infinity of the sign.
- Exponent after rounding ≤ 0: a zero of the sign (no denormal output).
- Otherwise {s, e, fraction}.
- `m[12]` is not checked (the callers give a normalised mantissa).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

The rounding is done at the normal precision before the flush test, as `Fmt.round` (a value just below 2^-14 that rounds up to it is the smallest normal).

## 8. What the TB checks

Through ad_su_pk_half (`sim/tb/ad_su_pk_half_tb.v`: every fma and packh vector).  Formal (`formal/ad_su_hrnd`): the output is never a denormal, never a NaN; RTZ never increases the magnitude; with round = sticky = 0 the result is exact ({s, e, f}) for 1 ≤ e ≤ 30.

## 9. References

tools/gsi1fp.py (`Fmt.round`), spec/gpu/su/ad_su_pk_half.md.

## 10. Status

2026-11-08: implemented (rtl/su/pk/ad_su_hrnd.v), mutation `MUT_HRND_DENORM` (denormal output instead of the flush) fails ad_su_pk_half_tb and the formal checks of ad_su_hrnd and ad_su_pk_half.
ASSUMPTION: ports `s`, `e` (10-bit signed biased exponent), `m` (13: lead, 10 fraction, round, sticky), `r`, `y` (no spec existed; ad_su_fpu's spec names this leaf for its packed halves: an FPU using it must use these ports).
