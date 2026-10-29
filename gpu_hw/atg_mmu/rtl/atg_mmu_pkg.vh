// ============================================================================
// atg_mmu_pkg.vh -- configuration package for the atg_mmu translation unit
// ----------------------------------------------------------------------------
// Verilog-2005 has no packages, so this include file plays that role.
// Rule: every define is exactly 7 characters ("AMU_" + 3).  Each one is
// wrapped in `ifndef so a build or a formal run can override it with +define.
// Derived widths are written out (not computed) so that each value is visible
// in one place; the consistency rules are listed next to each group and are
// checked by the elaboration-time guards at the bottom of atg_mmu.v.
// ============================================================================
`ifndef AMU_PKG
`define AMU_PKG

// ---------------------------------------------------------------- addresses
`ifndef AMU_VAW
`define AMU_VAW 32          // GPU VA width (EXT_CAP_FEATURE.VA_BITS = 32 -> 2-level walk)
`endif
`ifndef AMU_GVW
`define AMU_GVW 64          // VA width carried by packets / client ports (upper bits must be 0)
`endif
`ifndef AMU_PAW
`define AMU_PAW 40          // physical / IOVA width (EXT_CAP_FEATURE.PA_BITS, 40..48)
`endif
`ifndef AMU_PGS
`define AMU_PGS 12          // page shift: 4 KiB pages
`endif
`ifndef AMU_VPW
`define AMU_VPW 20          // VPN width            = AMU_VAW - AMU_PGS
`endif
`ifndef AMU_PFW
`define AMU_PFW 28          // PFN width            = AMU_PAW - AMU_PGS
`endif
`ifndef AMU_D1W
`define AMU_D1W 11          // directory index VA[31:21] -> 2048 x 8 B = 16 KiB root
`endif
`ifndef AMU_D0W
`define AMU_D0W 9           // table index     VA[20:12] ->  512 x 8 B =  4 KiB table
`endif                      // rule: AMU_D1W + AMU_D0W = AMU_VPW
`ifndef AMU_PTW
`define AMU_PTW 64          // PTE width = walker AXI data width (one PTE per beat)
`endif
`ifndef AMU_HPW
`define AMU_HPW 32          // CP_HEAP physical address width (CP_HEAP_BASE/LIMIT are 32-bit)
`endif
`ifndef AMU_RAS
`define AMU_RAS 14          // root alignment shift: 16 KiB root directory
`endif
`ifndef AMU_RTW
`define AMU_RTW 18          // root pointer width   = AMU_HPW - AMU_RAS
`endif

// ---------------------------------------------------------------- sessions / clients
`ifndef AMU_SIW
`define AMU_SIW 4           // session id width
`endif
`ifndef AMU_NSS
`define AMU_NSS 16          // sessions             = 2**AMU_SIW
`endif
`ifndef AMU_PRT
`define AMU_PRT 1           // CONFIG_MC_ENABLE_PROT: 1 = per-session tables, 0 = one shared table
`endif
`ifndef AMU_NCL
`define AMU_NCL 6           // translation clients: 0 CP, 1 VF, 2 SU, 3 TU, 4 ROP, 5 BLT
`endif
`ifndef AMU_CIW
`define AMU_CIW 3           // client id width      >= clog2(AMU_NCL)
`endif
`ifndef AMU_UMP
`define AMU_UMP 24'h654210  // client -> GHCI FAULT_INFO.UNIT code, 4 bits per client (CP0 VF1 SU2 TU4 ROP5 BLT6)
`endif
`ifndef AMU_STW
`define AMU_STW 2           // shader stage width (FAULT_INFO[19:16] low bits: VS FS CS MS)
`endif

// ---------------------------------------------------------------- TLB geometry
`ifndef AMU_L1E
`define AMU_L1E 16          // L1 entries per client (fully associative)
`endif
`ifndef AMU_L2S
`define AMU_L2S 64          // L2 sets
`endif
`ifndef AMU_L2X
`define AMU_L2X 6           // L2 set index width   = clog2(AMU_L2S)
`endif
`ifndef AMU_L2W
`define AMU_L2W 4           // L2 ways  (64 x 4 = 256 entries)
`endif
`ifndef AMU_L2T
`define AMU_L2T 14          // L2 VPN tag width     = AMU_VPW - AMU_L2X
`endif
`ifndef AMU_OSD
`define AMU_OSD 16          // in-flight transactions tracked per client per epoch
`endif

// ---------------------------------------------------------------- TLB attribute vector
`ifndef AMU_ATW
`define AMU_ATW 6           // attribute vector width
`endif
`define AMU_ARD 0           // attr: read allowed
`define AMU_AWR 1           // attr: write allowed
`define AMU_AEX 2           // attr: execute allowed
`define AMU_ACO 3           // attr: coherent  (AxCACHE hint)
`define AMU_AWC 4           // attr: write-combining
`define AMU_ALO 5           // attr: local VRAM

// ---------------------------------------------------------------- PTE / PDE bit positions (64-bit entry)
`define AMU_PVL 0           // V  valid
`define AMU_PLO 1           // L  local VRAM
`define AMU_PWR 2           // W  writable
`define AMU_PEX 3           // X  executable
`define AMU_PRD 8           // R  readable        (software bits [11:8])
`define AMU_PCO 9           // C  coherent        (software bits [11:8])
`define AMU_PWC 10          // WC write-combining (software bits [11:8])
`define AMU_PPL 12          // PPN lsb; PPN = [47:12]

// ---------------------------------------------------------------- access kinds
`define AMU_ACW 2           // access kind width
`define AMU_AKR 2'd0        // read
`define AMU_AKW 2'd1        // write
`define AMU_AKX 2'd2        // instruction fetch

// ---------------------------------------------------------------- fault kinds (GHCI FAULT_INFO.KIND)
`define AMU_FKW 4           // fault kind width
`define AMU_FKN 4'd0        // GHCI_FAULT_KIND_NONE
`define AMU_FKA 4'd5        // GHCI_FAULT_KIND_AXI_ERROR
`define AMU_FKP 4'd9        // GHCI_FAULT_KIND_PAGE_FAULT
`define AMU_FKM 4'd10       // GHCI_FAULT_KIND_PERM_FAULT

// ---------------------------------------------------------------- syndrome bits (FAULT_INFO[31:20])
`define AMU_SYW 12          // syndrome width
`define AMU_SWR 0           // 1 = write access (FAULT_INFO[20])
`define AMU_SOR 1           // VA bits above AMU_VAW set
`define AMU_SPD 2           // PDE not valid
`define AMU_SPT 3           // PTE not valid
`define AMU_SPM 4           // permission violation (0x010)
`define AMU_SNS 5           // session has no root (0x020, unmapped session)
`define AMU_SEX 6           // 1 = instruction fetch
`define AMU_SPA 7           // PPN beyond AMU_PAW

// ---------------------------------------------------------------- CP register port (dword index)
`define AMU_RAW 5           // register address width
`define AMU_RRT 5'h00       // ROOT_PT[0..15]   0x00..0x0F
`define AMU_RFL 5'h10       // TLB_FLUSH        (write)
`define AMU_RST 5'h11       // STATUS / INFLIGHT (read)
`define AMU_RFS 5'h12       // FAULT_STATUS     (read, W1C bit 15)
`define AMU_RFA 5'h13       // FAULT_ADDR_LO
`define AMU_RFH 5'h14       // FAULT_ADDR_HI
`define AMU_FAB 4           // TLB_FLUSH bit: all sessions
`define AMU_FRB 5           // TLB_FLUSH bit: one VPN (range)
`define AMU_FVB 15          // FAULT_STATUS bit: valid / W1C
`define AMU_FOB 14          // FAULT_STATUS bit: overflow (fault dropped while latched)

`endif // AMU_PKG
