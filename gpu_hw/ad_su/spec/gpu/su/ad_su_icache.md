# ad_su_icache

RTL: `rtl/gpu/su/ad_su_icache.v`.  Parent: ad_su.  Implemented in: p008.

## 1. Purpose and place

The SU's instruction cache: 2 KiB direct-mapped (256 instructions), lines of LINE_BYTES from the AMB, invalidated by LOAD_PROGRAM / INVALIDATE[3].

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `IC_BYTES` | `2048` | Size in bytes. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `ic_req` | in | 1 | Read. |
| `ic_ready` | out | 1 | Taken (0 while a miss is served). |
| `ic_addr` | in | 32 | Byte address. |
| `ic_rvalid` | out | 1 | Instruction, one cycle after a hit, later on a miss. |
| `ic_rdata` | out | 64 | Instruction. |
| `inv` | in | 1 | Invalidate everything (one-cycle pulse; flash clear of the valid bits). |
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

20 ports; 9 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Blocking: one miss at a time; the line is written into the data RAM and the waiting request answered.  Tags: [31:log2(IC_BYTES)].  The AMB port goes through am_amb_mux with ad_su_cbank (requester 0).

## 5. State machine

IDLE ↔ MISS_REQ → MISS_WAIT → FILL → IDLE.

## 6. Latency and throughput

Hit: 1 cycle, one per cycle.  Miss: one AMB round trip.

## 7. Corner cases and errors

- inv during a miss: the filled line is not marked valid.  rsp_error: the instruction is returned as 0 (an illegal instruction: word0[1:0] = 00 → ISA fault).

## 8. What the TB checks

`sim/tb/ad_su_icache_tb.v` prints, in this order:

- `PASS ad_su_icache.hit` — hits after the first miss of a line
- `PASS ad_su_icache.conflict` — two addresses of the same index replace each other
- `PASS ad_su_icache.inv` — inv forces misses; inv during a miss
- `PASS ad_su_icache` at the end.

## 9. References

design §3.5 (I$ 2 KiB, 32-byte line, direct map).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/ad_su_icache_tb.v` behind sim/models/amb_mem.v).  Tags and valid bits in registers (the hit is known at the request, so ic_ready = hit in IDLE); one line-wide data RAM read the cycle after the request.  After a fill the waiting request is answered from the fill buffer (state RESP, one cycle), so a line filled during inv or with an error is answered but not kept.

2026-11-08 (front-end builder, rtl/su/ad_su_icache.v): rewritten as described above (states IDLE, MREQ, MWAIT, RESP; RESP is the spec's FILL).  TB `sim/tb/ad_su_icache_tb.v` behind sim/common/ad_amb_mem.v (a reference model predicts every hit/miss; errors on lines above the memory); formal `formal/ad_su_icache` (reduced IC_BYTES 32, LINE_BYTES 8: AMB client properties, every answer for a symbolic line equals the memory's value, after inv no request hits until a line requested after the inv is filled; the last two with helper invariants in the RTL under AD_IC_FV); mutation MUT_IC_INV_KEEP.
- ASSUMPTION: in RESP the held request is taken when its address is in the filled line (it always is: the requester holds its payload until ic_ready); otherwise the cache returns to IDLE and the request is looked up again.
- ASSUMPTION: a fill that answered rsp_error or met an inv leaves the line's previous contents and valid bit as they were (inv itself clears every valid bit).
- ASSUMPTION: an inv in the cycle a hit is taken does not cancel that hit (the request came first).
- ASSUMPTION: AMB requests are reads with tag 0 (one outstanding); rsp_tag and rsp_write are not used.
- ASSUMPTION: LINE_BYTES 8 and 16 also work (used by the formal harness); IC_BYTES/LINE_BYTES lines, tag = addr[31:log2(IC_BYTES)].
