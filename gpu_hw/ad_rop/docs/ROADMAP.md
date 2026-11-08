# ad_rop feature roadmap (proposed, 2026-11-08)

Solo, part-time pace; effort figures are estimates.  Full rationale per item in the architecture document.

| Phase | Theme | Dates |
| --- | --- | --- |
| 1 | Close v1 gaps | 2026-11-16 → 2026-12-11 (v1.1 release) |
| 2 | Memory efficiency | 2026-12-14 → 2027-01-22 |
| 3 | Throughput and MSAA | 2027-01-25 → 2027-03-05 |
| 4 | Compression, early Z | 2027-03-08 → 2027-04-23 |
| 5 | API features | 2027-04-26 → 2027-06-04 (v2 RTL freeze) |
| 6 | KC705 bring-up | 2027-06-07 → 2027-07-16 (FPGA demo) |
| — | Verification hardening | throughout |

| # | Feature | Phase | Effort (weeks) |
| --- | --- | --- | --- |
| 1 | 8 colour attachments (3-bit rt, STATE 0x1B0–0x1BD) | 1 | 1.5 |
| 2 | wb streaming fast path using ad_rop_hazard | 1 | 2 |
| 3 | Dual-source colour from the SU (b_src1, b_has_src1) | 1 | 1 |
| 4 | AMB error reporting and performance counters | 1 | 1 |
| 5 | Out-of-order responses in the standard AMB model | 1 | 0.5 |
| 5a | Logic ops for integer formats and A2B10G10R10_UNORM (review) | 1 | 1 |
| 5b | Per-line read-after-write match in wb (review) | 1 | 0.5 |
| 6 | Depth line cache (ad_rop_cache inside ds) | 2 | 2 |
| 7 | Colour tile cache replacing the 2-entry line buffer | 2 | 2 |
| 8 | Fast clear (per-tile clear bits, clear value) | 2 | 1.5 |
| 9 | Several ds quads in flight (tagged) | 2 | 1.5 |
| 10 | Bit-exact lerp blend with 16 multipliers | 3 | 1 |
| 11 | 2 quads per clock through blend and fblend | 3 | 2.5 |
| 12 | 8× MSAA and resolve-on-write | 3 | 2 |
| 13 | Sample-rate shading support | 3 | 1 |
| 14 | Hierarchical Z with early-Z feedback to the rasterizer | 4 | 3 |
| 15 | Lossless colour compression (per-tile delta) | 4 | 2.5 |
| 16 | Depth compression (plane equations per tile) | 4 | 2 |
| 17 | More formats: 16-bit UNORM/SNORM, B10G11R11_UFLOAT, A2R10G10B10, D32_SFLOAT_S8 | 5 | 2 |
| 18 | Advanced blend ops (VK_EXT_blend_operation_advanced) | 5 | 2 |
| 19 | Pipeline-statistics and timestamp queries | 5 | 1 |
| 20 | Clock gating of idle blocks | 5 | 1 |
| 21 | KC705 bring-up: timing closure, LUT/BRAM report, scene demo | 6 | 6 |
| 22 | Full-datapath formal for ds/wb, coverage-driven tests, equivalence checks | all | ongoing |
