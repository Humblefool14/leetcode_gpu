# ad_su_hcmp

RTL: `rtl/su/pk/ad_su_hcmp.v`.  Parents: ad_su_pk_half (fcmplt2/fcmpge2/fcmpeq2/fcmpne2).

## 1. Purpose and place

fp16 compare, `fcmp(F16, a, b, op)` of tools/gsi1fp.py, as a 16-bit mask.

## 2. Parameters

None.

## 3. Ports

`a`, `b` (16), `op` (2: 0 eq, 1 lt, 2 le, 3 ne) / `y` (16: 0xFFFF true, 0 false): 4 ports.

## 4. Behaviour

Denormals are flushed (equal to the zeros), −0 == +0.  A NaN operand (unordered): every compare false except ne (true).  Ordered: the IEEE order of the values.  (ad_su_pk_half gives fcmpge2 as le with the operands swapped.)

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/ad_su_pk_half_tb.v` (`.other`): the four ops on every pair of 27 special values (zeros, denormals, normals around 1 and the extremes, infinities, NaNs) and 1,000,000 random pairs (equal, negated, neighbouring and random).  Formal (`formal/ad_su_hcmp`): for ordered operands exactly one of lt(a,b), eq(a,b), lt(b,a); le = lt | eq; le(a,b) & le(b,a) → eq; eq symmetric; ne = !eq; unordered: eq, lt, le false and ne true; y is 0 or 0xFFFF.

## 9. References

tools/gsi1fp.py.

## 10. Status

2026-11-08: implemented; mutation `MUT_HCMP_NAN` (unordered ne false) fails the TB and the formal check.
ASSUMPTION: ports `a`, `b`, `op` (fcmp's op numbering), `y` (no spec existed).
