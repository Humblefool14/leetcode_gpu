# ad_su_h2f

RTL: `rtl/su/pk/ad_su_h2f.v`.  Parents: ad_su_pk (one per lane: unpackh).

## 1. Purpose and place

fp16 to fp32 conversion, `f16_to_f32` of tools/gsi1fp.py.

## 2. Parameters

None.

## 3. Ports

`h` (16) / `f` (32): 2 ports.

## 4. Behaviour

- Exponent 0 (zero, denormal): a zero of the sign (denormals flushed).
- Exponent 31: mantissa 0 the infinity of the sign, otherwise the canonical NaN 0x7FC00000.
- Otherwise exact: {s, e + 112, m, 13 zeros}.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/ad_su_pk_half_tb.v` (`.other`): all 65536 inputs against gsi1fp.f16_to_f32.  Formal (`formal/ad_su_h2f`): packh's conversion of the result (ad_su_pk_half, o = packh) is the input for every non-NaN fp16 after the flush (f2h(h2f(h)) == h for every non-NaN, non-denormal h), and a NaN gives 0x7FC00000.

## 9. References

tools/gsi1fp.py, spec/gpu/su/ad_su_pk.md.

## 10. Status

2026-11-08: implemented; mutation `MUT_H2F_BIAS` (bias 111) fails ad_su_pk_half_tb and the round-trip proof.
ASSUMPTION: ports `h` / `f` (no spec existed).
