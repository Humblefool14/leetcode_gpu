# ad_su_hminmax

RTL: `rtl/su/pk/ad_su_hminmax.v`.  Parents: ad_su_pk_half (fmin2/fmax2).

## 1. Purpose and place

fp16 minimum and maximum, `fminmax(F16, a, b, is_max)` of tools/gsi1fp.py.

## 2. Parameters

None.

## 3. Ports

`a`, `b` (16), `mx` (1: 0 min, 1 max) / `y` (16): 4 ports.

## 4. Behaviour

The operands are flushed first (a denormal becomes the zero of its sign, and is returned as such).  One NaN: the other (flushed) operand; both NaN: 0x7E00.  Otherwise the smaller (min) or larger (max) by value with −0 < +0.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/ad_su_pk_half_tb.v` (`.other`): min and max on every special pair and 1,000,000 random pairs.  Formal (`formal/ad_su_hminmax`): the result is one of the flushed operands (or 0x7E00 when both are NaN), min ≤ both and max ≥ both in the order with −0 < +0, min(a,b) = min(b,a), max(a,b) = max(b,a), min ≤ max, a NaN operand yields the other.

## 9. References

tools/gsi1fp.py.

## 10. Status

2026-11-08: implemented; mutation `MUT_HMINMAX_ORDER` (min returns the larger) fails the TB and the formal check.
ASSUMPTION: ports `a`, `b`, `mx`, `y` (no spec existed).
