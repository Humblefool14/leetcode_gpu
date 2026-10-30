#!/usr/bin/env python3
"""Check the ad_rx naming rules.

1. Every name declared in rtl/ad_rx_pkg.sv (localparam, typedef, function)
   is at most 7 characters.
2. No `define in rtl/ (all constants come from the package).
3. No atg_ prefix left anywhere in rtl/ or fpv/.
"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
pkg = (root / "rtl" / "ad_rx_pkg.sv").read_text()
bad = []
decl = re.compile(r"\b(?:localparam|parameter)\b[^=;]*?\b([A-Za-z_]\w*)\s*=")
for m in decl.finditer(pkg):
    if len(m.group(1)) > 7:
        bad.append(f"pkg name too long: {m.group(1)} ({len(m.group(1))})")
for m in re.finditer(r"\bfunction\s+automatic\s+[^;(]*?\b(\w+)\s*\(", pkg):
    if len(m.group(1)) > 7:
        bad.append(f"pkg function too long: {m.group(1)}")
for m in re.finditer(r"\}\s*(\w+)\s*;", pkg):
    if len(m.group(1)) > 7:
        bad.append(f"pkg typedef too long: {m.group(1)}")

for d in ("rtl", "fpv"):
    for f in sorted((root / d).rglob("*.sv")):
        txt = f.read_text()
        if re.search(r"^\s*`define", txt, re.M):
            bad.append(f"{f.name}: `define found (use ad_rx_pkg)")
        if "atg_" in txt:
            bad.append(f"{f.name}: leftover atg_ name")

names = len(decl.findall(pkg))
if bad:
    print("\n".join(bad))
    print(f"FAIL lint_pkg ({len(bad)} problems)")
    sys.exit(1)
print(f"PASS lint_pkg ({names} package constants, all <= 7 chars)")
