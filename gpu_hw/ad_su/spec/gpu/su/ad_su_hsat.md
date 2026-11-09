# ad_su_hsat

RTL: `rtl/su/pk/ad_su_hsat.v`.  Parents: ad_su_pk_half (sat of the float results).

## 1. Purpose and place

Clamp an fp16 to [0, 1]: `sat(F16, x)` of tools/gsi1fp.py.

## 2. Parameters

None.

## 3. Ports

`x` (16) / `y` (16): 2 ports.

## 4. Behaviour

NaN, any value with the sign bit set (negatives, −0, −inf) gives +0; a positive x above 0x3C00 (1.0; +inf included) gives 0x3C00; otherwise x unchanged (a positive denormal passes, as the model; ad_su_pk_half never feeds one).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/ad_su_pk_half_tb.v` (`.other`): all 65536 inputs.  Formal (`formal/ad_su_hsat`): y is +0 or a positive value ≤ 1.0 (never NaN, never negative), y = x for 0 ≤ x ≤ 1.0, NaN and sign bit give +0.

## 9. References

tools/gsi1fp.py.

## 10. Status

2026-11-08: implemented; mutation `MUT_HSAT_NEG` (negatives pass) fails the TB and the formal range check.
ASSUMPTION: ports `x` / `y` (no spec existed).
