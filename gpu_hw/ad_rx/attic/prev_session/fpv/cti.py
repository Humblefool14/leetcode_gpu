#!/usr/bin/env python3
"""Show the failing assertion of a proof and the signals it names, per step.

    python3 fpv/cti.py ad_rx_clip [extra signal names...]
"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent
mod = sys.argv[1]
d = root / f"{mod}_prv"
log = (d / "logfile.txt").read_text()
m = re.search(r"failed assertion .* at (\S+?):(\d+)\.\d+-(\d+)\.", log)
if not m:
    print("no failed assertion"); sys.exit()
src = (root.parent / "rtl" / m.group(1)).read_text().splitlines()
lines = src[int(m.group(2)) - 1:int(m.group(3))]
print("\n".join(lines))
names = set(re.findall(r"\b([a-z_][a-z0-9_]*)\b", " ".join(lines))) | set(sys.argv[2:]) | {"st"}
names -= {"assert", "if", "begin", "end", "ad_rx_pkg"}
vcd = d / "engine_0" / ("trace_induct.vcd" if "induction" in log.split("failed assertion")[0][-400:] or (d / "engine_0" / "trace_induct.vcd").exists() else "trace.vcd")
v = vcd.read_text()
ids = {}
for mm in re.finditer(r"\$var \w+ \d+ (\S+) (\S+)", v):
    if mm.group(2) in names and mm.group(1) not in ids and mm.group(2) not in ids.values():
        ids[mm.group(1)] = mm.group(2)
cur = {}
for line in v.split("\n"):
    if line.startswith("#"):
        if cur:
            print(line, " ".join(f"{k}={cur[k]}" for k in sorted(cur)))
    elif line and line[0] in "b01":
        val, i = (line[1:].split() if line[0] == "b" else (line[0], line[1:]))
        if i in ids:
            cur[ids[i]] = hex(int(val, 2)) if set(val) <= {"0", "1"} else val
