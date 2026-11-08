"""Write sim/vec/arith_*.hex for sim/tb/ad_arith_tb.v (one vector per line, hex fields)."""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from admodel import *

N_RAND = int(os.environ.get("N_RAND", "200000"))
out = os.path.join(os.path.dirname(__file__), "..", "sim", "vec")
os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(1)

def w(name, rows):
    with open(os.path.join(out, name), "w") as fh:
        for r in rows:
            fh.write(r + "\n")
    print(name, len(rows))

# f2u8 / f2unorm: input, u8, u16, u24 packed as 32+8+16+24 bits
rows = []
pats = [rand_f32(rng, 0.05) for _ in range(N_RAND)]
for e in range(110, 128):   # dense near the rounding region
    for _ in range(2000):
        pats.append((e << 23) | int(rng.integers(0, 1 << 23)))
for k in range(256):        # exact k/255 and the midpoints between codes
    pats.append(f2b(float(np.float32(k / 255))))
    pats.append(f2b(float(np.float32((k + 0.5) / 255))))
for p in pats:
    rows.append("%08x_%02x_%04x_%06x" % (p, f2u8(p), f2unorm(p, 16), f2unorm(p, 24)))
w("arith_f2unorm.hex", rows)

# fp add/sub and mul: a, b, sub, add result, mul result
rows = []
for _ in range(N_RAND):
    a, b = rand_f32(rng), rand_f32(rng)
    if rng.random() < 0.2:                       # near-cancellation pairs
        b = (a ^ 0x80000000) + int(rng.integers(-3, 4)) & 0xFFFFFFFF
    s = int(rng.integers(0, 2))
    lt, eq, un = fp_cmp(a, b)
    rows.append("%08x_%08x_%x_%08x_%08x_%x" % (a, b, s, fp_add(a, b, s), fp_mul(a, b), (lt << 2) | (eq << 1) | un))
w("arith_fp.hex", rows)

# unorm2f: N = 16 exhaustive, N = 24 random
rows = ["%06x_%08x" % (x, unorm2f(x, 16)) for x in range(1 << 16)]
w("arith_u2f16.hex", rows)
xs = [0, 1, (1 << 24) - 1, (1 << 24) - 2, 1 << 23] + [int(rng.integers(0, 1 << 24)) for _ in range(N_RAND // 2)]
rows = ["%06x_%08x" % (x, unorm2f(x, 24)) for x in xs]
w("arith_u2f24.hex", rows)
