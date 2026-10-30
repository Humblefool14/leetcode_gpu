#!/usr/bin/env python3
"""Write sim/vec/fp_*.hex: random + corner vectors with expected results."""
import pathlib, random, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import fpref as M

N = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
r = random.Random(0xAD0)
out = pathlib.Path(__file__).parent / "vec"
out.mkdir(exist_ok=True)

with open(out / "fp_add.hex", "w") as f:
    for i in range(N):
        a, b = M.rand_fp(r), M.rand_fp(r)
        if i % 7 == 0:      # force near-cancellation
            b = (a ^ 0x80000000) ^ r.randint(0, 3)
        s = r.getrandbits(1)
        f.write(f"{a:08x}{b:08x}{s:01x}{M.fadd(a, b, s):08x}\n")

with open(out / "fp_mul.hex", "w") as f:
    for _ in range(N):
        a, b = M.rand_fp(r), M.rand_fp(r)
        f.write(f"{a:08x}{b:08x}{M.fmul(a, b):08x}\n")

with open(out / "fp_div.hex", "w") as f:
    for _ in range(N // 4):
        a, b = M.rand_fp(r), M.rand_fp(r)
        f.write(f"{a:08x}{b:08x}{M.fdiv(a, b):08x}\n")

with open(out / "fp_cvt.hex", "w") as f:
    for i in range(N):
        x = M.rand_fp(r)
        if i % 3 == 0:   # values in the snap range
            x = (r.getrandbits(1) << 31) | (r.randint(110, 145) << 23) | r.getrandbits(23)
        if i % 5 == 0:   # exact ties at 1/512
            x = M.rnd(r.getrandbits(1), M.Fr(2 * r.randint(0, 1 << 20) + 1, 512))
        v50 = r.getrandbits(50)
        if i % 4 == 0:
            v50 = r.getrandbits(r.randint(1, 50))
        v21 = r.getrandbits(21)
        v17 = r.getrandbits(17)
        f.write(f"{x:08x}{M.f2fix(x):06x}"
                f"{v50:013x}{M.i2f(v50, 50, 0):08x}"
                f"{v21:06x}{M.i2f(v21, 21, 3):08x}"
                f"{v17:05x}{M.i2f(v17, 17, 0):08x}\n")
print(f"wrote {N} add/mul/cvt and {N//4} div vectors")
