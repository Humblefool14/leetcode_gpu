#!/usr/bin/env python3
"""Reference fp32 model of the ad_rx fp units (exact, via Fraction).

Rules: RNE; denormal inputs read as zero (sign kept); results rounded to a
24-bit significand with an unbounded exponent, then flushed to signed zero
when below 2^-126; canonical NaN 0x7FC00000; x + (-x) = +0.
Writes sim/fp_vec.txt: op a b expected (hex), op 0 add, 1 sub, 2 mul, 3 div.
"""
import random, sys
from fractions import Fraction

QNAN = 0x7FC00000

def unpack(x):
    s = x >> 31; e = (x >> 23) & 0xFF; f = x & 0x7FFFFF
    if e == 0xFF:
        return ('nan', s) if f else ('inf', s)
    if e == 0:
        return ('zero', s)
    return ('num', s, Fraction((1 << 23) | f, 1 << 23) * Fraction(2) ** (e - 127))

def pack(v, s_hint=0):
    if v == 0:
        return s_hint << 31
    s = 1 if v < 0 else 0
    a = -v if v < 0 else v
    e = 0
    while a >= 2: a /= 2; e += 1
    while a < 1: a *= 2; e -= 1
    m = a * (1 << 23)
    fl = m.numerator // m.denominator
    rem = m - fl
    if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and fl & 1):
        fl += 1
    if fl == 1 << 24:
        fl >>= 1; e += 1
    E = e + 127
    if E <= 0:
        return s << 31
    if E >= 255:
        return (s << 31) | 0x7F800000
    return (s << 31) | (E << 23) | (fl & 0x7FFFFF)

def fadd(a, b, sub=0):
    if sub: b ^= 0x80000000
    A, B = unpack(a), unpack(b)
    if A[0] == 'nan' or B[0] == 'nan': return QNAN
    if A[0] == 'inf' and B[0] == 'inf':
        return QNAN if A[1] != B[1] else a
    if A[0] == 'inf': return a
    if B[0] == 'inf': return b
    if A[0] == 'zero' and B[0] == 'zero': return (A[1] & B[1]) << 31
    if A[0] == 'zero': return b
    if B[0] == 'zero': return a
    va = A[2] * (-1 if A[1] else 1); vb = B[2] * (-1 if B[1] else 1)
    v = va + vb
    if v == 0: return 0
    return pack(v)

def fmul(a, b):
    A, B = unpack(a), unpack(b)
    s = (a ^ b) >> 31
    if A[0] == 'nan' or B[0] == 'nan': return QNAN
    if (A[0] == 'inf' and B[0] == 'zero') or (B[0] == 'inf' and A[0] == 'zero'): return QNAN
    if A[0] == 'inf' or B[0] == 'inf': return (s << 31) | 0x7F800000
    if A[0] == 'zero' or B[0] == 'zero': return s << 31
    return pack(A[2] * B[2] * (-1 if s else 1), s)

def fdiv(a, b):
    A, B = unpack(a), unpack(b)
    s = (a ^ b) >> 31
    if A[0] == 'nan' or B[0] == 'nan': return QNAN
    if (A[0] == 'zero' and B[0] == 'zero') or (A[0] == 'inf' and B[0] == 'inf'): return QNAN
    if A[0] == 'inf' or B[0] == 'zero': return (s << 31) | 0x7F800000
    if A[0] == 'zero' or B[0] == 'inf': return s << 31
    return pack(A[2] / B[2] * (-1 if s else 1), s)

def rnd32(r):
    k = r.random()
    if k < 0.08:
        return r.choice([0, 0x80000000, 0x7F800000, 0xFF800000, QNAN, 0x7FA00001,
                         0x00000001, 0x807FFFFF, 0x00800000, 0x3F800000, 0x7F7FFFFF,
                         0x80800000, 0xBF800000])
    if k < 0.5:
        e = r.randint(100, 154)
        return (r.getrandbits(1) << 31) | (e << 23) | r.getrandbits(23)
    return r.getrandbits(32)

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    out = sys.argv[2] if len(sys.argv) > 2 else 'fp_vec.txt'
    r = random.Random(7)
    with open(out, 'w') as f:
        for i in range(n):
            op = i % 4
            a, b = rnd32(r), rnd32(r)
            if op < 2 and r.random() < 0.3:      # near-cancellation cases
                b = (a ^ (0x80000000 if op == 0 else 0)) ^ r.getrandbits(3)
            if op == 2 and r.random() < 0.2:     # products near the underflow edge
                a = (r.getrandbits(1) << 31) | (r.randint(1, 20) << 23) | r.getrandbits(23)
                b = (r.getrandbits(1) << 31) | (r.randint(100, 126) << 23) | r.getrandbits(23)
            exp = fadd(a, b, 0) if op == 0 else fadd(a, b, 1) if op == 1 else fmul(a, b) if op == 2 else fdiv(a, b)
            f.write(f"{op:x} {a:08x} {b:08x} {exp:08x}\n")

if __name__ == '__main__':
    main()
