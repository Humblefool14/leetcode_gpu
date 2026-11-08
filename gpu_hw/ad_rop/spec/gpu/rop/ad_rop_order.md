# ad_rop_order

RTL: `rtl/rop/ad_rop_order.v` (new).  Parent: ad_rop.

## 1. Purpose and place

Primitive-order retirement at the ROP's input: quads from SU 0 (ex_*) and from the RX's direct path (dx_*, DEBUG_COLOR) may arrive in any order across primitives; the module passes them to `ad_rop_ms` in the order the rasterizer issued their sequence numbers (ord_*), the quads of one number contiguous and in arrival order.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `SEQ_W` | `16` | Sequence number width (formal harness only narrows it). |
| `COLOR_W` | `512` | ex_color / o_color width (formal only). |
| `DEPTH_W` | `128` | ex_depth / dx_depth / o_depth width (formal only). |
| `AUX_W` | `154` | ex_aux / o_aux width (formal only; the direct beat is truncated). |
| `FIFO_LG` | `4` | log2 of the issued-number FIFO depth (16). |

ad_rop uses the defaults.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, reset |
| `ex_valid` / `ex_ready` | in / out | 1, 1 | A quad of SU 0; taken when both are 1.  ex_ready is combinational (the quad's number against the head, output register free); the SU may withdraw or change an offer that was not taken |
| `ex_seq`, `ex_xy`, `ex_mask`, `ex_color`, `ex_depth`, `ex_last`, `ex_aux` | in | 16, 32, 4, 512, 128, 1, 154 | Its sequence number, position, lanes, colours, depths, last quad of the number, the beat |
| `ex_next` | out | 16 | The next number to retire (the FIFO head); meaningful while the FIFO holds a number |
| `dx_valid` / `dx_ready` | in / out | 1, 1 | A direct quad, as ex_* |
| `dx_seq`, `dx_xy`, `dx_mask`, `dx_depth`, `dx_last` | in | 16, 32, 4, 128, 1 | Its number, position, lanes, depths, last quad of the number |
| `ord_valid`, `ord_seq` | in | 1, 16 | One issued number per cycle, in issue order (no ready, see §4) |
| `o_valid` / `o_ready` | out / in | 1, 1 | The quad to ad_rop_ms (i_valid / i_ready) |
| `o_xy`, `o_mask`, `o_color`, `o_depth`, `o_dbg`, `o_aux` | out | 32, 4, 512, 128, 1, 154 | Its position, lanes, colours, depths, direct path, beat (ad_rop_ms i_*) |
| `busy` | out | 1 | o_valid or a number outstanding |
| `ovf` | out | 1 | Sticky: a number was issued into a full FIFO and lost (a protocol error; simulation also prints FAIL).  May be left open |

25 ports (24 without ovf).

## 4. Behaviour

- A FIFO of 2^FIFO_LG issued numbers; ord_valid pushes ord_seq.  It has no ready: the rasterizer must not have more than 16 numbers outstanding (issued and not retired; a retirement in the same cycle counts).  An issue into a full FIFO is dropped and sets ovf.
- cur = the FIFO head; ex_next = cur.  An SU quad is taken when the FIFO is non-empty, ex_seq == cur and the output register is free (empty, or emptied this cycle by o_ready); a direct quad likewise with dx_seq == cur, unless an SU quad is taken in the same cycle (SU first).
- A taken quad with last (ex_last / dx_last) pops the head after it: the next number's quads are taken from the next cycle.
- A taken quad with no lane (mask 0) counts (for last) but is not forwarded.
- SU quads go out as they came, o_dbg = 0, o_aux = ex_aux.  Direct quads go out with o_color = 0, o_dbg = 1, o_depth = dx_depth, o_aux = {rt 0, qlast 1, qfirst 1, nocol 0, front 1, d_s 0, zexp 0, smask 16'h1111} (sample 0 of each lane; ad_rop_ms and-s it with the lanes).
- One output register with valid/ready; it holds its contents while o_valid and not o_ready.

## 5. State machine

None beyond the FIFO (read/write pointers, count) and the output register's valid bit.

## 6. Latency and throughput

One quad per cycle: a taken quad is at the output the next cycle; the output register reloads in the cycle it is emptied (no bubble).  The quads of the next number are taken one cycle after the last quad of the current one.

## 7. Corner cases and errors

- A quad whose number is not the head waits (ready 0) however long; a number issued but never finished (no last) blocks all later numbers.
- Duplicate outstanding numbers are allowed: quads of the second wait until the first is retired.
- `MUT_ORD_ANYSEQ` takes SU quads whatever their number (the TB and formal mutation check).
- ovf: see §4; the order of the numbers already in the FIFO is kept.

## 8. What the TB checks

`sim/tb/ad_rop_order_tb.v` (400 numbers from 0xFFE1, wrapping; 30% direct; 1-5 quads each, 1/8 of them mask 0; a random generator offers SU and direct quads from any pending number, the head only half of the time, numbers not yet issued included; issues up to 16 ahead at random; random o_ready) prints:

- `PASS ad_rop_order.inorder` — the output stream equals the issued order of the numbers, each number's quads contiguous and in arrival order, mask-0 quads absent, every field equal, nothing lost or duplicated, no quad taken out of turn, out-of-turn offers held back, ovf 0
- `PASS ad_rop_order.direct` — the direct quads with colour 0, o_dbg 1 and the fixed beat
- `PASS ad_rop_order` at the end.

## 9. References

spec ad_rop.md (the top ports ex_*, dx_*, ord_*), ad_rop_ms.md (i_aux).

## 10. Status

2026-11-08: implemented; every PASS of §8 (`-DMUT_ORD_ANYSEQ` fails `.inorder` and `.direct`).  Formal `formal/ad_rop_order` (SEQ_W 4, COLOR_W 8, DEPTH_W 8, AUX_W 16, FIFO of 4; harness shadow FIFO of the issued numbers): taken quads only with the head's number, ex_next = the shadow head, no overflow (under the assumption of at most 4 outstanding) and no underflow, busy, the output register's contents and seq, the direct beat, mask-0 quads never forwarded, hold under back-pressure: bmc 20 (abc bmc3), prove (abc pdr), cover (smtbmc z3); `MUT_ORD_ANYSEQ` fails bmc.

- ASSUMPTION: there is no spec from the design; this one is derived from ad_rop.md's ports.  The rasterizer bounds the numbers outstanding to the FIFO depth (no ord_ready); ovf is an added debug port.
- ASSUMPTION: last marks the last quad of a sequence number (ad_rop.md says "of the warp" for ex_last): one issued number per warp.
- ASSUMPTION: ready depends on the offered number (combinational); offers need not be held while not taken.
- ASSUMPTION: a direct quad with mask 0 is consumed and not forwarded, as an SU quad.
