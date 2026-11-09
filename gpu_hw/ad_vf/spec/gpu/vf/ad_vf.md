# ad_vf

RTL: `rtl/gpu/vf/ad_vf.v`.  Parent: ad_top (HAS_VF).  Implemented in: p009.

## 1. Purpose and place

The vertex fetcher (design §2.3, §3.8): index walk, warp and primitive assembly, attribute fetch and conversion into the SU's registers; one MC client (index and attribute reads behind ad_amb_mux).

Children: `ad_vf_index`, `ad_vf_asm`, `ad_vf_fetch`, `ad_vf_conv`, `ad_amb_mux`.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from ad_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| `draw_kick` | in | 1 | DRAW. |
| `busy` | out | 1 | STATUS.VF_BUSY. |
| **Vertex warps to the SU (ad_su vl_*)** | | | |
| `vl_req` | out | 1 | Slot request (level). |
| `vl_gnt` | in | 1 | Grant pulse. |
| `vl_ptbase` | in | 8 | PT base of the granted warp (with vl_gnt). |
| `vl_go` | out | 1 | Start the warp. |
| `vl_mask` | out | 32 | Valid vertices of the warp. |
| `vl_we` | out | 1 | Attribute word. |
| `vl_reg` | out | 6 | Register (ATTR_DST[k] + component). |
| `vl_lane` | out | 5 | Lane. |
| `vl_data` | out | 32 | Data (converted to 32 bits). |
| **Primitives to the RX** | | | |
| `prim_valid` | out | 1 | A primitive (point, line or triangle). |
| `prim_ready` | in | 1 | Taken. |
| `prim_vtx` | out | 26 | Three PT entries, v0 in [7:0] (provoking vertex first per PROVOKING); [25:24] the kind: 0 point, 1 line, 2 triangle (CAPS[30]; the RX no longer reads TOPOLOGY). |
| `prim_free` | out | 3 | Vertex i is used for the last time (RX frees its PT entry after this primitive). |
| `prim_last` | out | 1 | Last primitive of the draw (a draw with no primitive sends none, ad_vf_asm §7). |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

33 ports; 22 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Wiring only (see the children).  index is requester 0 and fetch requester 1 of the MC port.

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §2.3, §3.8.

## 10. Status

Wiring written in WS288 p023; the children (ad_vf_index, ad_vf_asm, ad_vf_fetch, ad_vf_conv) implemented in WS288 p009 part A (branch p1-vf), the wiring unchanged.  For Q1: ad_cp_seq does not hold a SET_REG into the VF ranges (0x020-0x04F, 0x1C0-0x1CF) while the VF is busy (it does for the BLT, RX and ROP ranges); the VF assumes its STATE does not change under a draw.  Done in p009 part B1 (ad_cp_seq holds them while the VF is busy).

2026-11-09 (ad_vf rebuild, integration and review).  `rtl/vf/ad_vf.v` wires the five children and
`ad_amb_mux` (N = 2) as above, plus two fixes for contract problems found by an independent review
of the integrated RTL (both reproduced in the whole-VF test before the fix, `sim/tb/ad_vf_tb.v`):
- ASSUMPTION/FIX: ad_vf_asm reads PROVOKING (RX STATE 0x05D) and ad_vf_fetch reads ATTR_LIMIT[k]
  (0x1D0 + k) during a draw, but the CP holds SET_REG while the VF is busy only for 0x020-0x04F and
  0x1C0-0x1CF.  A write to either sent right after a DRAW changed that draw (wrong vertex order;
  reads past a buffer's robust limit).  New leaf `rtl/vf/top/ad_vf_stguard.v` holds such writes
  (one entry per index, newest wins) and replays them when the draw is over; busy covers the held
  writes, so the next DRAW sees them.  Scene `race` checks it; `-DMUT_NO_STGUARD` fails it.
- ASSUMPTION/FIX: after an index-buffer rsp_error the walk stops without iv_last and ad_vf_asm
  waited forever, so busy never fell and the CP could not see when the index had drained.  Now,
  after such an error, busy covers only reads in flight (index DRAIN, fetch); the CP resets the VF
  once busy is low.  Scene `fault` checks that busy falls with no read in flight and that a draw
  after the reset is correct; `-DMUT_NO_ERRBUSY` fails it.
- ASSUMPTION: the CP waits for busy low before a DRAW (a kick while busy is ignored by ad_vf_index).
- Formal: `formal/ad_vf` bmc (abc bmc3, depth 20: read-only port, request valid/tag held until
  ready, primitive payload held, busy covers vl_req/vl_go/prim_valid outside fault mode).
  `bmc_line_open` (line held until ready at the top) fails in the AIG model only; replaying its
  inputs in simulation shows no violation, and line hold is proven per client and for ad_amb_mux.
