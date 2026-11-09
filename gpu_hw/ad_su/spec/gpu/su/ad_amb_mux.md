# ad_amb_mux

RTL: `rtl/rop/ad_amb_mux.v` (new).  Parent: ad_rop (the "am_amb_mux" of ad_rop.md: requester 0 = ad_rop_ds, requester 1 = ad_rop_wb).

## 1. Purpose and place

Shares one AMB client port (design §4.1) between N AMB clients: round-robin request arbitration, tag remapping so that every response goes back to the client that asked, with that client's tag.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `N` | `2` | Number of client ports. |
| `TBL_LOG2` | `4` | log2 of the tag-table entries (1..7): the most requests outstanding downstream. |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.  LW = ADDR_W-LINE_SHIFT.  Client i uses bits [i*W +: W] of each packed client vector.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Client ports (AMB memory side, one per requester)** | | | |
| `c_req_valid` | in | N | Request valid; payload held until `c_req_ready`. |
| `c_req_ready` | out | N | Taken this cycle (at most one bit set). |
| `c_req_write` | in | N | 1 write, 0 read. |
| `c_req_line` | in | N*LW | Line address. |
| `c_req_be` | in | N*LINE_BYTES | Byte enables of a write. |
| `c_req_wdata` | in | N*LINE_BYTES*8 | Write data. |
| `c_req_tag` | in | N*8 | The client's tag. |
| `c_rsp_valid` | out | N | Response to client i (at most one bit set); one per request. |
| `c_rsp_write` | out | 1 | Shared: the response is a write's. |
| `c_rsp_tag` | out | 8 | Shared: the client's original tag. |
| `c_rsp_rdata` | out | LINE_BYTES*8 | Shared: read data. |
| `c_rsp_error` | out | 1 | Shared: aperture or AXI error. |
| **AMB client port (to the MC)** | | | |
| `m_req_valid` | out | 1 | Request valid; payload held until `m_req_ready`. |
| `m_req_ready` | in | 1 | Taken this cycle. |
| `m_req_write` | out | 1 | 1 write, 0 read. |
| `m_req_line` | out | LW | Line address. |
| `m_req_be` | out | LINE_BYTES | Byte enables. |
| `m_req_wdata` | out | LINE_BYTES*8 | Write data. |
| `m_req_tag` | out | 8 | Internal tag (table index, upper bits 0). |
| `m_rsp_valid` | in | 1 | Response, one cycle, no back-pressure. |
| `m_rsp_write` | in | 1 | Write response. |
| `m_rsp_tag` | in | 8 | Internal tag of the request answered. |
| `m_rsp_rdata` | in | LINE_BYTES*8 | Read data. |
| `m_rsp_error` | in | 1 | Error. |

26 ports.

## 4. Behaviour

- **Arbitration**: when no request is being presented, the valid requester following the last granted one (round robin) is chosen and its request presented downstream at once (combinational: `c_req_ready[i] = m_req_ready` while i is presented).  If the MC does not take it, grant, payload and internal tag are held until `m_req_ready` (no switching mid-request).
- **Tag table**: 2^TBL_LOG2 entries {valid, requester, client tag}.  A request is presented only when an entry is free (the lowest free one); its index is `m_req_tag`.  The entry is written when the request is taken.  Table full: nothing presented, `c_req_ready` = 0.
- **Responses**: `m_rsp_tag` selects the entry; `c_rsp_valid` is raised for its requester only, `c_rsp_tag` = the stored client tag, write/rdata/error pass through; the entry is freed.  No added latency.
- Responses may come back in any order (tags), as long as each answers one outstanding request.

## 5. State machine

Lock: idle → (presented, not taken) locked → (m_req_ready) idle.

## 6. Latency and throughput

Zero cycles on both paths (combinational); one request per cycle.

## 7. Corner cases and errors

- A response whose tag names no live entry (not allowed by AMB) is dropped.
- Client tags may repeat across clients and need not be unique within a client (the table stores them).

## 8. What the TB checks

`sim/tb/ad_amb_mux_tb.v` (two random clients using the same tag values, ad_amb_mem with random ready and latency up to 40, a few error lines) prints:

- `PASS ad_amb_mux.route` — every client gets exactly its own responses, with its own tags, data/write/error against a flat reference memory, nothing lost; downstream payload held until ready; table-full stalls exercised; grants alternate while both request (`-DMUT_MUX_FIXPRI` fails it); `-DMUT_MUX_NOLOCK` (switching mid-request) fails it
- `PASS ad_amb_mux` at the end.

## 9. References

design §4.1 (AMB), ad_rop.md §1, §4.

## 10. Status

Implemented 2026-11-08 (new block; the parent ad_rop.md names it am_amb_mux).
ASSUMPTION: extra parameter `TBL_LOG2` (default 4, 16 entries) for the tag table; ad_rop's instance keeps the default.
ASSUMPTION: shared response payload with per-client `c_rsp_valid`; requests are presented combinationally from the client inputs (ready path m_req_ready -> c_req_ready is combinational).
Formal: `formal/ad_amb_mux/` (LINE_BYTES=1, ADDR_W=8: the payload is only multiplexed): downstream ad_amb_client_props (hold until ready), no internal tag reused while outstanding, forwarded payload = granted client's, each response to its requester only with its original tag, no response to a client with nothing outstanding.  bmc (abc bmc3, 24, TBL_LOG2=2) PASS, prove (abc pdr, TBL_LOG2=2) PASS, bmc16 (abc bmc3, 20, TBL_LOG2=4) PASS, prove16 (smtbmc z3 k-induction depth 3, TBL_LOG2=4, the default table) PASS, cover PASS.  Helper invariants use formal-only observation ports under `-DAD_FV_MUX`.  `-DMUT_MUX_NOLOCK` fails bmc.
ASSUMPTION: the memory side may answer outstanding requests in any order (each once, at least one cycle after being taken).
