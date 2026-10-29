# generate one .sby per formal target
import sys
RTL = ["atg_mmu_ram.v","atg_mmu_arb.v","atg_mmu_ifc.v","atg_mmu_flt.v",
       "atg_tlb_l1.v","atg_tlb_l2.v","atg_mmu_walker.v","atg_mmu.v"]
T = {  # name: (harness, prove engine, prove depth, cover depth)
 "arb":    ("fv_arb.sv",    "smtbmc z3", 20, 12),
 "ifc":    ("fv_ifc.sv",    "smtbmc z3", 20, 16),
 "flt":    ("fv_flt.sv",    "smtbmc z3", 20, 8),
 "l1":     ("fv_l1.sv",     "smtbmc z3", 20, 16),
 "l2":     ("fv_l2.sv",     "smtbmc z3", 6, 16),
 "walker": ("fv_walker.sv", "smtbmc z3", 20, 12),
 "top":    ("fv_top.sv",    "smtbmc z3", 8, 30),
 "topw":   ("fv_topw.sv",   "smtbmc z3", 12, 30),
}
DEF={"arb":"-DAMU_FVA","ifc":"-DAMU_FVI","l1":"-DAMU_FV1","l2":"-DAMU_FV2"}
for n,(h,eng,pd,cd) in T.items():
    files = "\n".join("../rtl/"+f for f in RTL)
    open(f"{n}.sby","w").write(f"""[tasks]
prove
cover
bmc

[options]
prove: mode prove
prove: depth {pd}
bmc: mode bmc
bmc: depth {pd}
cover: mode cover
cover: depth {cd}

[engines]
prove: {eng}
bmc: smtbmc z3
cover: smtbmc z3

[script]
read_verilog -formal -I. {DEF.get(n,"")} {" ".join(RTL)}
read_verilog -sv -formal {h}
prep -top fv_{n}

[files]
{files}
../rtl/atg_mmu_pkg.vh
{h}
""")
