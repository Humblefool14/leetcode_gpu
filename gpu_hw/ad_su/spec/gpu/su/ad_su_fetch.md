# ad_su_fetch

RTL: `rtl/gpu/su/ad_su_fetch.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

Instruction fetch: takes a (warp, pc, address) from the scheduler, reads the 64-bit instruction from the I$ and hands it to the decoder.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `WARP_W` | `2` | log2(NWARPS). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From ad_su_sched** | | | |
| `f_valid` | in | 1 | Fetch request. |
| `f_ready` | out | 1 | Taken. |
| `f_warp` | in | WARP_W | Warp. |
| `f_pc` | in | 16 | pc. |
| `f_addr` | in | 32 | Byte address (8-byte aligned). |
| **I$ port (ad_su_icache)** | | | |
| `ic_req` | out | 1 | Read the instruction at ic_addr. |
| `ic_ready` | in | 1 | Taken. |
| `ic_addr` | out | 32 | Address. |
| `ic_rvalid` | in | 1 | The instruction (in request order). |
| `ic_rdata` | in | 64 | word0 in [31:0], word1 in [63:32]. |
| **To ad_su_dec** | | | |
| `d_valid` | out | 1 | Instruction. |
| `d_ready` | in | 1 | Taken. |
| `d_warp` | out | WARP_W | Warp. |
| `d_pc` | out | 16 | pc. |
| `d_instr` | out | 64 | Instruction. |

17 ports.

## 4. Behaviour

A small queue of in-flight fetches (depth 2) keeps {warp, pc} in order with the I$ responses; f_ready when there is room.

## 5. State machine

None (two-entry queue).

## 6. Latency and throughput

One instruction per cycle on I$ hits (I$ latency 1).

## 7. Corner cases and errors

- I$ misses stall the queue (all warps: the I$ is blocking in v1).

## 8. What the TB checks

`sim/tb/ad_su_fetch_tb.v` prints, in this order:

- `PASS ad_su_fetch.order` — random hit/miss latencies: instructions leave with their own warp and pc
- `PASS ad_su_fetch` at the end.

## 9. References

design §3.5 (I$), §3.3 (64-bit instructions).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/ad_su_fetch_tb.v`).

2026-11-08 (front-end builder, rtl/su/ad_su_fetch.v + leaf rtl/su/ctl/ad_ctl_fq.v): rewritten.  ic_req = f_valid while the 2-entry queue (ad_ctl_fq) has room; f_ready = ic_ready && room; the queue keeps {warp, pc} per accepted request, takes the I$ answers in order into the oldest entry without data and hands the head to ad_su_dec.  TB `sim/tb/ad_su_fetch_tb.v` (random I$ ready/latency, random d_ready; one instruction per cycle on hits); formal `formal/ad_su_fetch` (order and pairing by tagged token, no loss within a bound, every instruction carries its own warp/pc) and `formal/ad_ctl_fq`; mutation MUT_FQ_FILL.
- ASSUMPTION: "room" counts a head that leaves in the same cycle, so f_ready (and ic_req) depend combinationally on d_ready.
- ASSUMPTION: the instruction leaves the cycle after the I$ answer (registered in the queue): 2 cycles from request to d_valid on a hit, one instruction per cycle in steady state.
- ASSUMPTION: an I$ answer with no entry waiting for data is a protocol error and is dropped.
