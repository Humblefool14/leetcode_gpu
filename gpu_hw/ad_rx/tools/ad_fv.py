#!/usr/bin/env python3
"""FPV runner for ad_rx: yosys -> SMT2 -> yosys-smtbmc (BMC, then k-induction).

Usage: tools/ad_fv.py [module ...]      (no argument: every job)
Each job: harness top, RTL files, BMC depth, induction depth, defines.
A job PASSES when BMC finds no failing trace up to its depth and k-induction
proves every assertion (mode 'prove'), or BMC alone passes (mode 'bmc').
Equivalent SymbiYosys .sby files are written next to each harness.
"""
import subprocess, sys, os, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
R = lambda *f: [os.path.join(ROOT, 'rtl', x) for x in f]
PKG = 'ad_rx_pkg.sv'

JOBS = {
  # name            harness top          rtl files                                            bmc ind  mode
  'fadd':   ('ad_rx_fadd_fv',   R(PKG, 'ad_rx_fadd.sv'),                                1, 1, 'prove'),
  'fmul':   ('ad_rx_fmul_fv',   R(PKG, 'ad_rx_fmul.sv'),                                1, 1, 'prove'),
  'fdiv':   ('ad_rx_fdiv_fv',   R(PKG, 'ad_rx_fdiv.sv'),                                32, 32, 'prove'),
  'f2fix':  ('ad_rx_f2fix_fv',  R(PKG, 'ad_rx_f2fix.sv'),                               1, 1, 'prove'),
  'i2f':    ('ad_rx_i2f_fv',    R(PKG, 'ad_rx_i2f.sv'),                                 1, 1, 'prove'),
  'f2un':   ('ad_rx_f2un_fv',   R(PKG, 'ad_rx_f2un.sv'),                                1, 1, 'prove'),
  'order':  ('ad_rx_order_fv',  R(PKG, 'ad_rx_order.sv'),                               8, 2, 'prove'),
  'cov':    ('ad_rx_cov_fv',    R(PKG, 'ad_rx_cov.sv'),                                 4, 2, 'prove'),
  'coarse': ('ad_rx_coarse_fv', R(PKG, 'ad_rx_coarse.sv'),                              20, 0, 'bmc'),
  'hiz':    ('ad_rx_hiz_fv',    R(PKG, 'ad_rx_hiz.sv'),                                 15, 0, 'bmc'),
  'cpoly':  ('ad_rx_cpoly_fv',  R(PKG, 'ad_rx_fadd.sv', 'ad_rx_fmul.sv', 'ad_rx_fdiv.sv', 'ad_rx_cpoly.sv'), 36, 0, 'bmc', ['AD_FPABS']),
  'state':  ('ad_rx_state_fv',  R(PKG, 'ad_rx_state.sv'),                               6, 2, 'prove'),
  'clip':   ('ad_rx_clip_fv',   R(PKG, 'ad_rx_fadd.sv', 'ad_rx_fmul.sv', 'ad_rx_fdiv.sv', 'ad_rx_cpoly.sv', 'ad_rx_clip.sv'), 40, 0, 'bmc', ['AD_FPABS']),
  'edge':   ('ad_rx_edge_fv',   R(PKG, 'ad_rx_f2fix.sv', 'ad_rx_i2f.sv', 'ad_rx_edge.sv'), 34, 0, 'bmc'),
  'setup':  ('ad_rx_setup_fv',  R(PKG, 'ad_rx_fadd.sv', 'ad_rx_fmul.sv', 'ad_rx_fdiv.sv', 'ad_rx_f2fix.sv', 'ad_rx_i2f.sv', 'ad_rx_edge.sv', 'ad_rx_setup.sv'), 40, 0, 'bmc', ['AD_FPABS']),
  'scan':   ('ad_rx_scan_fv',   R(PKG, 'ad_rx_fadd.sv', 'ad_rx_fmul.sv', 'ad_rx_i2f.sv', 'ad_rx_f2un.sv', 'ad_rx_cov.sv', 'ad_rx_coarse.sv', 'ad_rx_hiz.sv', 'ad_rx_scan.sv'), 16, 0, 'bmc', ['AD_FPABS']),
  'bary':   ('ad_rx_bary_fv',   R(PKG, 'ad_rx_fadd.sv', 'ad_rx_fmul.sv', 'ad_rx_fdiv.sv', 'ad_rx_i2f.sv', 'ad_rx_bary.sv'), 52, 0, 'bmc', ['AD_FPABS']),
  'frag':   ('ad_rx_frag_fv',   R(PKG, 'ad_rx_fadd.sv', 'ad_rx_fmul.sv', 'ad_rx_fdiv.sv', 'ad_rx_i2f.sv', 'ad_rx_bary.sv', 'ad_rx_frag.sv'), 40, 0, 'bmc', ['AD_FPABS']),
  'rx':     ('ad_rx_fv',         None,                                                   12, 0, 'bmc', ['AD_FPABS']),
}
ALL_RTL = R(PKG, 'ad_rx_fadd.sv', 'ad_rx_fmul.sv', 'ad_rx_fdiv.sv', 'ad_rx_f2fix.sv', 'ad_rx_i2f.sv',
            'ad_rx_f2un.sv', 'ad_rx_order.sv', 'ad_rx_cov.sv', 'ad_rx_coarse.sv', 'ad_rx_hiz.sv',
            'ad_rx_cpoly.sv', 'ad_rx_clip.sv', 'ad_rx_edge.sv', 'ad_rx_setup.sv', 'ad_rx_scan.sv',
            'ad_rx_bary.sv', 'ad_rx_frag.sv', 'ad_rx_state.sv', 'ad_rx.sv')

def sby_text(top, files, bmc, ind, mode):
    base = [os.path.basename(f) for f in files] + [top + '.sv']
    return (f"[tasks]\n{'prove' if mode == 'prove' else 'bmc'}\n\n[options]\n"
            f"{'mode prove' if mode == 'prove' else 'mode bmc'}\ndepth {max(bmc, ind)}\n\n"
            f"[engines]\nsmtbmc yices\n\n[script]\nread -formal {' '.join(base)}\nprep -top {top}\n\n"
            f"[files]\n" + '\n'.join(files) + f"\n{top}.sv\n")

def run(name):
    top, files, bmc, ind, mode, *rest = JOBS[name]
    defs = ' '.join('-D' + d for d in (rest[0] if rest else []))
    files = files or ALL_RTL
    d = os.path.join(ROOT, 'fv', name)
    os.makedirs(d, exist_ok=True)
    harness = os.path.join(d, top + '.sv')
    with open(os.path.join(d, name + '.sby'), 'w') as f:
        f.write(sby_text(top, files, bmc, ind, mode))
    smt = os.path.join(d, top + '.smt2')
    ys = (f"read_verilog -formal -sv {defs} {' '.join(files)} {harness}; prep -top {top}; "
          f"async2sync; dffunmap; write_smt2 -wires {smt}")
    t0 = time.time()
    p = subprocess.run(['yosys', '-p', ys], capture_output=True, text=True, cwd=d)
    if p.returncode:
        return name, 'ERROR', p.stderr[-1500:] + p.stdout[-1500:]
    if 'implicitly declared' in p.stderr + p.stdout:
        return name, 'ERROR', 'implicit declaration (a hierarchical reference?):\n' + (p.stderr + p.stdout)[-1500:]
    res = []
    limit = int(os.environ.get('AD_FV_LIMIT', '1500'))      # seconds per solver run
    def smtbmc(args, tag):
        log = os.path.join(d, tag + '.log')
        with open(log, 'w') as lf:
            try:
                subprocess.run(['yosys-smtbmc', '-s', 'yices'] + args + ['--dump-vcd', os.path.join(d, tag + '.vcd'), smt],
                               stdout=lf, stderr=subprocess.STDOUT, cwd=d, timeout=limit)
            except subprocess.TimeoutExpired:
                pass
        out = open(log).read()
        steps = [int(x) for x in __import__('re').findall(r'Checking assertions in step (\d+)', out)]
        return out, ('Status: PASSED' in out), ('Status: FAILED' in out), (max(steps) if steps else 0)
    out, ok, bad, k = smtbmc(['--presat', '-t', str(bmc)], 'bmc')
    if ok:
        res.append(f"bmc {bmc}: PASS")
    elif bad:
        res.append(f"bmc {bmc}: FAIL at step {k}")
    else:
        res.append(f"bmc: steps 0-{k - 1} clean, step {k} unfinished at the {limit}s limit (asked {bmc})")
    log = out[-3000:]
    if ok and mode == 'prove':
        out, ok, bad, k = smtbmc(['-i', '-t', str(ind)], 'ind')
        res.append(f"induction {ind}: {'PROVEN' if ok else 'FAIL'}")
        log = out[-3000:]
    partial = (not ok) and not bad and mode == 'bmc'
    st = ('PROVEN' if mode == 'prove' else 'PASS (bmc)') if ok else ('BOUNDED' if partial else 'FAIL')
    with open(os.path.join(d, 'result.txt'), 'w') as f:
        f.write(f"{name}: {st} ({', '.join(res)}) {time.time() - t0:.1f}s\n")
    return name, st, ', '.join(res) + f"  [{time.time() - t0:.1f}s]" + ('' if ok or partial else '\n' + log)

if __name__ == '__main__':
    names = sys.argv[1:] or list(JOBS)
    for n in names:
        nm, st, info = run(n)
        print(f"{nm:8s} {st:12s} {info}", flush=True)
