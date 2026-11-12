# ad_common: shared primitives for ad_rop, ad_su and ad_vf

One copy of every generic building block (arbiters, FIFOs, delay lines, skid buffers, RAMs,
popcount, the AMB client mux), each written once, parameterized, and verified by **one formal
harness** that runs at every configuration the designs use.

## Layout of the workspace

```
workspace/
  ad_common/   this library (rtl/common, formal, sim, scripts)
  ad_rop/      ROP   -- reads ../ad_common/rtl/common/... from its .f lists and .sby files
  ad_su/       SU    -- same
  ad_vf/       VF    -- same
```
The designs refer to the library by relative path (`../ad_common/...` in sim file lists,
`../../../ad_common/...` in formal `[files]`), so the four directories must sit side by side.
In a real repository this is a git submodule (or a package path variable) at the same place.

## Catalog

| Module | Path | What it is | Replaces (before) |
|---|---|---|---|
| `ad_fifo` | `rtl/common/fifo/ad_fifo.v` | Sync FIFO, show-ahead, DEPTH a power of two, count | `ad_su_fifo`, `ad_gfx_fifo` (SU) |
| `ad_delay` | `rtl/common/pipe/ad_delay.v` | N-stage valid/data delay line | `ad_ctl_spipe` (SU) |
| `ad_skid` | `rtl/common/pipe/ad_skid.v` | Two-stage skid buffer, registered ready | `ad_gfx_skid` (SU) |
| `ad_ram_1r1w` | `rtl/common/mem/ad_ram_1r1w.v` | 1 write + 1 registered read port, read-old | `ad_su_ram1r1w` (SU) |
| `ad_ram_tdp` | `rtl/common/mem/ad_ram_tdp.v` | Port A read/write (read-first) + port B read | `ad_mem_tdpram` (SU) |
| `ad_ram_sp_be` | `rtl/common/mem/ad_ram_sp_be.v` | Single port, byte write enables | `ad_cache_ram` (ROP) |
| `ad_popcount` | `rtl/common/math/ad_popcount.v` | Number of ones of a W-bit word | `ad_gfx_popc32` (SU) |
| `rec_arbiter` | `rtl/common/arb/rec_arbiter.sv` | Fixed priority (lowest index), log depth; also the priority encoder | `ad_hazard_prienc` (ROP), `ad_vf_vc_penc` (VF) |
| `rr_pick` | `rtl/common/arb/rr_pick.sv` | Round-robin choice from an external pointer | `ad_su_rr_pick` (SU) |
| `rr_arbiter` | `rtl/common/arb/rr_arbiter.sv` | Round-robin with its own pointer | (new) |
| `qos_arbiter` | `rtl/common/arb/qos_arbiter.sv` | Two classes, high-burst limit while low waits | (new) |
| `ad_amb_mux` | `rtl/common/bus/ad_amb_mux.v` | N AMB clients onto one port (uses `rr_pick`, `rec_arbiter`) | three copies (ROP, SU, VF) |

Port lists are unchanged from the modules they replace (the migration renamed ports only for
`ad_gfx_fifo` d/q, the priority encoders and `ad_su_rr_pick`, whose ports now use the
`grant_*` names of the arbiters, and `ad_gfx_popc32` m/n).

## Formal: one harness per primitive, one task per configuration

```
python3 scripts/scan_instances.py   # elaborate the ROP/SU/VF tops (all regression parameter sets)
                                    # -> formal/instances.json: every configuration in use
python3 scripts/gen_fpv.py          # corner sizes + instances.json -> formal/<prim>/<prim>.sby
scripts/regress.sh                  # every task (FTIMEOUT seconds each, default 900) + sim tests
scripts/mutations.sh                # each primitive's -DMUT_* must fail its harness
```

Each `formal/<prim>/fv_<prim>.sv` is written once, parameterized like the module. What it checks:

| Primitive | Properties |
|---|---|
| ad_fifo | count/empty/full equal a counter model; a solver-chosen pushed item reaches the head after exactly the items ahead of it and leaves with its value |
| ad_delay | out_valid equals in_valid N cycles earlier; a chosen input comes out after exactly N cycles with its data |
| ad_skid | occupancy 0..2 decides in_ready/out_valid/empty; a chosen item leaves in order, once, with its value |
| ad_ram_1r1w / ad_ram_tdp | for a symbolic address, a read returns the last value written before the read's cycle; outputs hold while not enabled |
| ad_ram_sp_be | for a symbolic address and byte, a read returns the byte last written with its enable |
| ad_popcount | equal to a reference written another way |
| rec_arbiter / rr_pick | equal to "lowest set bit" / "first request at or after ptr" for every input |
| rr_arbiter / qos_arbiter | one-hot grant to a requester; starvation bounds (N-1; QoS burst and wait bounds) |
| ad_amb_mux | hand-written harness: AMB client properties, tag routing, no reuse of live tags (N = 2, as every instance; reduced payload width) |

**Data independence.** The storage primitives move data bits (bytes, for `ad_ram_sp_be`) without
ever combining them, so a proof at a narrow data width covers every width. Their `prove` tasks
cap the data width (4 bits, 2 bytes) and keep depth, stages and address width at the instance's
real values; each instance's `bmc` task runs at the real width.

**Engines.** `prove` tasks use abc pdr, except `ad_fifo`, which is proven by k-induction (smtbmc z3,
depth 3) with two strengthening invariants read through formal-only ports (`-DAD_FV_FIFO`): pdr
did not converge at depth 32 and 64, induction closes every depth in seconds. `bmc` tasks use abc
bmc3. Full-width BMC is skipped above 32 kbit of state (the 128 x 512-bit ROP cache RAM): the
width-capped proof covers it, and `ad_rop_cache`'s own formal runs with the real RAM.

**Mutations.** Every primitive has a `-DMUT_*` that must make its harness fail:
`MUT_FIFO_NOFULL`, `MUT_DELAY_SHORT`, `MUT_SKID_LOSS`, `MUT_RAM_WFIRST`, `MUT_RAM_TDP_WFIRST`,
`MUT_RAM_BE_ALL`, `MUT_POPC_SKIP0`, `MUT_RR_STUCK`, `MUT_QOS_NOCNT`, `MUT_MUX_FIXPRI`,
`MUT_MUX_NOLOCK`.

## What stays in the designs

The designs keep the formal of their own blocks. A parent's harness still includes the common
primitive (it is part of the parent's logic); what the designs no longer have is a private copy of
the primitive and its private proof. Inline logic that is not a separate module (the SU
scheduler's lowest-free-slot loop, `ad_gfx_pt_alloc`'s lowest free block, the VF STATE guard's
lowest held slot, the round-robin mode of `ad_ctl_wsel`) is a candidate for `rec_arbiter` /
`rr_pick` next.

## Adding a primitive

1. Put it in `rtl/common/<group>/`, parameterized, synchronous active-low reset, with a header
   comment stating the contract, and one `-DMUT_*` mutation.
2. Write `formal/<prim>/fv_<prim>.sv` with the same parameters; check data with a symbolic
   watched item or address so the proof cost does not grow with width.
3. Add an entry to `PRIMS` in `scripts/gen_fpv.py` (files, parameter order, corner sizes, BMC depth,
   data-width cap if data-independent) and the name to `PRIMS` in `scripts/scan_instances.py`.
4. Run the three scripts above; confirm the mutation fails.
5. In a design, instantiate it and add `../ad_common/rtl/common/<group>/<file>` to the .f lists
   (and the `.sby` of every block that contains it); `scripts/migrate.py` automates this for a
   private copy that is being replaced.
