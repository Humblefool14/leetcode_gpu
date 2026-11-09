"""gen_su_sys.py PROG [--packed] [--subgroup] [--lanes N] -- whole-SU vectors for sim/tb/ad_su_tb.v.

Assembles sim/tb/su/PROG.s with tools/gsi1asm.py, builds a 64 KiB byte image (program at
CS_BASE 0x1000, a random data image of 4096 words at DATA_BASE 0x8000, which is also what
LOAD_CONST reads), runs tools/gsi1model.py for the expected registers and memory, and writes
sim/vec/su_PROG_{img,regs,mem}.hex and su_PROG.cfg (lanes, flags)."""
import os, random, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import gsi1asm as A

prog = sys.argv[1]
packed = "--packed" in sys.argv
subgroup = "--subgroup" in sys.argv
lanes = int(sys.argv[sys.argv.index("--lanes") + 1]) if "--lanes" in sys.argv else 64
root = os.path.join(here, "..")
src = os.path.join(root, "sim", "tb", "su", prog + ".s")
out = os.path.join(root, "sim", "vec")
CS_BASE, DATA_BASE, MEM = 0x1000, 0x8000, 0x10000

words = A.encode(open(src).read())
rnd = random.Random(prog)
data = [rnd.getrandbits(32) for _ in range(4096)]
img = bytearray(MEM)
for i, w in enumerate(words):
    img[CS_BASE + 8 * i: CS_BASE + 8 * i + 8] = w.to_bytes(8, "little")
for i, w in enumerate(data):
    img[DATA_BASE + 4 * i: DATA_BASE + 4 * i + 4] = w.to_bytes(4, "little")
dpath = os.path.join(out, "su_%s_data.hex" % prog)
open(dpath, "w").write("".join("%08x\n" % w for w in data))
args = [sys.executable, "-I", os.path.join(here, "gsi1model.py"), src, "--lanes", str(lanes),
        "--data", dpath, "-o", os.path.join(out, "su_%s_regs.hex" % prog),
        "--mem-out", os.path.join(out, "su_%s_mexp.hex" % prog)]
if packed: args.append("--packed")
if subgroup: args.append("--subgroup")
subprocess.run(args, check=True)
open(os.path.join(out, "su_%s_img.hex" % prog), "w").write("".join("%02x\n" % b for b in img))
print("%s: %d instructions, lanes %d" % (prog, len(words), lanes))
