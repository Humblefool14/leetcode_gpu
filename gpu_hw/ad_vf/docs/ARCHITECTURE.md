# ad_vf architecture (summary)

Full document with diagrams: https://claude.ai/artifact/QGN7QryYxqK2sgqvxbHd2h

## Overview

ad_vf is the vertex fetcher. On each DRAW it turns indices into 32-lane vertex warps for the SU,
loads each vertex's attributes into the SU's registers, and sends assembled primitives to the RX.

DRAW -> ad_vf_index (walk / index buffer, restart, instances) -iv-> ad_vf_asm (warps, PT slot, carry,
provoking order, last use) -vb-> ad_vf_fetch (element, address, ATTR_LIMIT, 4 x 8-entry line buffers)
-af-> ad_vf_conv (format conversion, one register word per cycle) -> SU registers (vl_we/reg/lane/data).
asm requests an SU slot (vl_req/gnt/ptbase), starts the warp after conv_done (vl_go, vl_mask) and
emits primitives (prim_vtx = 3 PT entries + kind, prim_free, prim_last).  index and fetch share one
AMB client through ad_amb_mux.  ad_vf_stguard holds PROVOKING / ATTR_LIMIT writes during a draw.
Only one warp is in flight at a time (v1).

## Hierarchy

7 module files (ad_vf, ad_vf_index, ad_vf_asm, ad_vf_fetch, ad_vf_conv, ad_vf_vc, ad_amb_mux) and
25 leaf IPs in rtl/vf/{idx,asm,fetch,fmt,vc,top}/, about 1,780 lines of RTL without comments.

## STATE (rtl/include/ad_vf_state.vh)

Fixed by the specs: VF ranges 0x020-0x04F and 0x1C0-0x1CF, kick-time words 0x021-0x027, ATTR_LIMIT
0x1D0 + k, PROVOKING at RX 0x05D, ATTR_DESC[19:16]/[20]/[31:24], ATTR_DST[5:0]/[7:6]/[31:24].
ASSUMED: TOPOLOGY 0x020, INDEX_BASE 0x021, INDEX_FORMAT 0x022, FIRST 0x023, COUNT 0x024,
FIRST_INSTANCE 0x025, INSTANCE_COUNT 0x026, VERTEX_OFFSET 0x027, PRIM_RESTART 0x028,
ATTR_BASE[k] 0x030 + 2k, ATTR_DESC[k] 0x031 + 2k (stride [15:0]), ATTR_DST[k] 0x1C0 + k,
legacy format codes 0-9 (10-15 reserved), and the 50-entry VkFormat set (tools/fmtmodel.py).

## Review findings (fixed)

1. PROVOKING and ATTR_LIMIT were read live during a draw, but the CP does not hold those indices while
   the VF is busy: a SET_REG right after a DRAW changed the running draw.  Fixed by ad_vf_stguard
   (scene `race`, mutation MUT_NO_STGUARD).
2. After an index-buffer rsp_error, asm waited forever and busy never fell, so the CP could not see
   when in-flight reads were done before resetting the VF.  After an index fault, busy now covers only
   reads in flight (scene `fault`, mutation MUT_NO_ERRBUSY).

## Spec inconsistencies

| Where | Specs say | RTL does |
|---|---|---|
| fetch section 3 | 30 ports | 31 (af_oob) |
| fetch section 4 | VkFormat sizes 1/2/4/8/12/16 | also 6 (R16G16B16) |
| fetch sections 4, 6 | no cross-attribute eviction; 4x pipelined bursts | k and k+4 share a stream; one attribute at a time, <= 2 reads in flight |
| conv section 10 vs fetch section 4 | enable on [31:24] or [7:0] / whole word | whole word != 0 |
| conv, fetch | atg_fmt_*, tools/vf-vectors.py, atg_rop_unorm8.vh | not provided; ad_vf_fmt_* leaves and tools/fmtmodel.py |
| index section 4 | mux uses tag bit 7 | ad_amb_mux remaps tags; harmless |
| ad_vf_vc | parent ad_vf; no sections 7-10 | standalone, not instantiated (asm: v1 has no reuse cache) |

## Assumptions to confirm

STATE indices and fields above; legacy format codes; the VkFormat set; CAPS[30] always present; the
CP waits for VF idle before a DRAW and resets the VF after a fault; the SU's PT allocator gives 32-entry
blocks and takes back lanes outside vl_mask at vl_go (asm section 7); vertex-cache same-cycle rules.
