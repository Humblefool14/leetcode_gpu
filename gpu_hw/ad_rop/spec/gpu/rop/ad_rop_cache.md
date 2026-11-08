# ad_rop_cache

RTL: `rtl/gpu/rop/ad_rop_cache.v`.  Parent: `ad_rop` / `ad_rop_wb`.  Implemented in: ws001-p017.

## 1. Purpose and place

A 4-way set-associative L1 tile cache for ROP rendering (Color / Depth attachments).
Replaces small write-combining buffers with an 8 KiB on-chip cache structure to eliminate external memory thrashing during triangle rasterization.
Infers 7-series RAMB36E1 block RAM for data lines with per-byte write enables, delivering sustained 1-cycle hit access and hiding DRAM latency.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `LINE_BYTES` | `64` | Cache line size in bytes (1 AMB burst beat / line). |
| `WAYS` | `4` | Associativity (4-way set-associative). |
| `SETS_LOG2` | `5` | Log2 of the number of sets (32 sets -> 32 × 4 × 64B = 8 KiB capacity). |

## 3. Ports

Clock/reset domain: `clk` (gclk), synchronous reset `rst_n` (active low).

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **ROP pipeline interface** | | | |
| `req_valid` | in | 1 | Request valid. |
| `req_ready` | out | 1 | Ready to accept request (1 on hit or idle). |
| `req_write` | in | 1 | 1 = write, 0 = read. |
| `req_addr` | in | 32 | Byte address. |
| `req_be` | in | LINE_BYTES | Byte enables for writes. |
| `req_wdata` | in | LINE_BYTES*8 | Write data (64 bytes). |
| `rsp_valid` | out | 1 | Response valid (asserted 1 cycle after hit or refill). |
| `rsp_rdata` | out | LINE_BYTES*8 | Read data (64 bytes). |
| **External AMB / L2 memory bus** | | | |
| `mem_req_valid` | out | 1 | Memory access request. |
| `mem_req_ready` | in | 1 | Memory interface ready. |
| `mem_req_write` | out | 1 | 1 = eviction writeback, 0 = refill read. |
| `mem_req_line` | out | 26 | Line address (`req_addr >> 6`). |
| `mem_req_wdata` | out | LINE_BYTES*8 | Eviction writeback data. |
| `mem_rsp_valid` | in | 1 | Memory read data valid. |
| `mem_rsp_rdata` | in | LINE_BYTES*8 | Refill read data from memory. |
| **Flush & Status** | | | |
| `flush` | in | 1 | Trigger full dirty-line writeback. |
| `busy` | out | 1 | Asserted during miss refill, eviction, or flush. |

16 ports.

## 4. Behaviour

- **Parallel Tag Match**: 4-way parallel comparator checks `addr_tag` against all ways in `set_idx`.
- **Hit Access (1 cycle)**:
  - Read hit: Data read synchronously from `data_mem`, `rsp_valid` returned next cycle.
  - Write hit: Line updated with byte enable `req_be`, dirty bit set, Tree-PLRU updated.
- **Tree-PLRU Replacement**:
  - Uses 3 tree bits per set ($b_0, b_1, b_2$) to track pseudo-least-recently-used ways.
  - On eviction, selects non-accessed sub-trees to determine victim way without arithmetic operators.
- **Write-Back & Dirty Tracking**:
  - Modified lines remain in cache until evicted or flushed.
  - On eviction of a dirty line, `mem_req_write = 1` writes the full 64-byte line to memory before reading the new line.
- **Flush**: Iterates through all sets and ways, writing back all dirty lines until cache is fully clean.

## 5. What the TB checks

`sim/tb/ad_rop_cache_tb.v` prints:
- `PASS ad_rop_cache.hit`: Read and write hits streaming continuously at 1 cycle/req.
- `PASS ad_rop_cache.plru`: Filling all 4 ways of a set, triggering Tree-PLRU eviction, and confirming dirty line writeback to memory.
- `PASS ad_rop_cache.flush`: Flushing all remaining dirty lines to memory and ensuring `busy` drops to 0.
- `PASS ad_rop_cache` at the end.

## 10. Status

2026-11-08: implemented in `rtl/rop/ad_rop_cache.v` with leaves `rtl/rop/cache/ad_cache_tagmatch.v`, `ad_cache_plru.v` (tree PLRU, no arithmetic), `ad_cache_ram.v` (single-port synchronous RAM, byte write enables, registered read that holds while not read).  `sim/tb/ad_rop_cache_tb.v` prints `PASS ad_rop_cache.hit`, `.plru`, `.flush`, `.random` (6000 random reads/writes with random byte enables over 32 lines of 4 sets, random flushes, ad_amb_mem with random ready/latency; reads checked against a flat reference; memory equals the reference after the final flush) and `PASS ad_rop_cache`.  Mutations `-DMUT_CACHE_DIRTY` (write hit does not set dirty) and `-DMUT_PLRU` fail the TB.
Formal: `formal/ad_rop_cache/` (reduced: LINE_BYTES=4, SETS_LOG2=1, WAYS=4, addresses < 64, reset in the first cycle only): memory payload held until ready, one refill read outstanding, refill never issued over a dirty victim, busy low => idle, flush ends with no dirty line, and data integrity for a symbolic line A (every read of A returns its latest written value, with a memory model returning A's memory copy) — prove PASS by k-induction (smtbmc z3, depth 3, ~4-6 min) with helper invariants (h_*); bmc (abc bmc3, depth 20) PASS; cover (smtbmc z3, 16: read miss of A, flush write-back, flush end) PASS.  `-DMUT_CACHE_DIRTY` fails bmc (helper: a clean copy of A must equal memory).  `formal/ad_cache_plru/`: victim/update against a table, the victim after an access is never the accessed way: prove PASS.
ASSUMPTION: Ports as the §3 table (19 rows; its "16 ports" count is wrong).  mem_req_line = 32-log2(LINE_BYTES) bits (26 for 64-byte lines); there is no mem_req_be/tag: a write-back is always a full line, the integrator ties be to all ones and the tag to a constant.
ASSUMPTION: mem_rsp_valid comes only for refill reads (one per read, in order, at least one cycle after the read is taken); AMB write responses are not given to the cache (the integrator drops responses with rsp_write=1).  The memory keeps request order (a written-back line read later returns the written data).
ASSUMPTION: req_ready = idle && !flush (also 0 while a flush is pending); a miss stalls requests until its response.  rsp_valid comes one cycle after a hit, and one cycle after the REPLAY state of a miss (accept, MISS, [EVICT], REFILL_REQ, REFILL_WAIT, REPLAY).  Writes also pulse rsp_valid; rsp_rdata is meaningful only for reads (it is the data RAM output).  Responses are in request order, one per request.
ASSUMPTION: write-allocate (a write miss refills the line, then merges the bytes and marks it dirty).  Victim: the lowest invalid way, else the tree-PLRU victim; hits and refills touch the PLRU.  PLRU bits per set: [0] root (0 left pair, 1 right pair), [1] way 0/1, [2] way 2/3.
ASSUMPTION: flush is a one-cycle trigger (remembered if it comes while busy); it writes back each dirty line and leaves it valid and clean; it scans every {set, way} (SETS*WAYS cycles plus write-backs).  WAYS must be 4.
ASSUMPTION: Formal-only observation ports (state, valid, dirty, tags, RAM, latched request) exist under `-DAD_FV_CACHE` only.
