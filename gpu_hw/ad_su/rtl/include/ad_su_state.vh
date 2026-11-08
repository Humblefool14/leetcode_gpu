// ad_su_state.vh -- STATE indices the shader unit keeps (design §2.3 is not in this
// repository; indices marked ASSUMED fill the ranges the specs name).
`ifndef AD_SU_STATE_VH
`define AD_SU_STATE_VH
`define AD_S_VS_BASE     9'h190   // (ASSUMED, range 0x190-0x19A per ad_su_sched §9) vertex program base
`define AD_S_FS_BASE     9'h191   // (ASSUMED) fragment program base
`define AD_S_CS_BASE     9'h192   // (ASSUMED) compute program base
`define AD_S_LDS_BYTES   9'h198   // (ASSUMED) LDS allotment per workgroup (ad_su_lds §7)
`define AD_S_WG_SIZE     9'h199   // (spec, ad_su_sched) workgroup size in lanes
`define AD_S_GRID_X      9'h1E9   // (spec range 0x1E9-0x1EB) workgroups in x, y, z
`define AD_S_GRID_Y      9'h1EA
`define AD_S_GRID_Z      9'h1EB
`define AD_S_LC_REGION   9'h1EC   // (spec range 0x1EC-0x1EE, order ASSUMED) LOAD_CONST region
`define AD_S_LC_ADDR     9'h1ED   //   source byte address
`define AD_S_LC_WORDS    9'h1EE   //   word count (<= 256)
`endif
