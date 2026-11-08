// ad_rop_state.vh -- STATE indices and field layouts used by the ad_rop blocks.
//
// Indices marked (spec) are given by spec/gpu/rop/*.md.  Indices marked
// (ASSUMED) are not stated in the specs we have (design §2.3 is not in this
// repository); they were chosen to fill the gaps of the 0x070-0x08F ROP range
// consistently.  Change them here only: every block includes this file.
`ifndef AD_ROP_STATE_VH
`define AD_ROP_STATE_VH

// ---- RX range (0x050-0x06F) words the ROP keeps ----------------------------
`define AD_S_VP_ZSCALE      9'h054   // (spec, ad_rop_ms) VIEWPORT z scale, fp32
`define AD_S_VP_ZOFFSET     9'h055   // (spec, ad_rop_ms) VIEWPORT z offset, fp32
`define AD_S_DEPTH_CLAMP    9'h059   // (spec, ad_rop_ms) [0] clamp to [n,f], [1] RX clips z
`define AD_S_MS_CTRL        9'h05E   // (spec, ad_rop_ms) [3:0]=2 four samples, [8] A2C, [9] A2One

// ---- ROP range (0x070-0x08F) ----------------------------------------------
`define AD_S_RT_BASE        9'h070   // (ASSUMED) RT0 base, bytes
`define AD_S_RT_STRIDE      9'h071   // (ASSUMED) RT0 row stride, bytes
`define AD_S_RT_FORMAT      9'h072   // (spec) legacy code 0 BGRA8, 1 RGBA8, 2/3 RGB565
`define AD_S_DS_BASE        9'h073   // (ASSUMED) depth/stencil base
`define AD_S_DS_STRIDE      9'h074   // (ASSUMED) depth/stencil row stride
`define AD_S_DEBUG_COLOR    9'h075   // (ASSUMED) RGBA8, R in [7:0]
`define AD_S_DEPTH          9'h076   // (spec) see AD_DEPTH_* below
`define AD_S_STENCIL_FRONT  9'h077   // (spec)
`define AD_S_STENCIL_OPS    9'h078   // (spec)
`define AD_S_STENCIL_BACK   9'h079   // (spec)
`define AD_S_BLEND          9'h07A   // (spec) BLEND of RT0
`define AD_S_BLEND_CONST    9'h07B   // (spec) RGBA8, R in [7:0]
`define AD_S_WRITE_MASK     9'h07C   // (ASSUMED) [4k+3:4k] = RGBA write mask of RT k
`define AD_S_RT_FORMATS     9'h07D   // (spec) byte k = VkFormat of RT k
`define AD_S_RT1_BASE       9'h07E   // (ASSUMED) RT1..3 base/stride pairs 0x07E..0x083
`define AD_S_RT1_STRIDE     9'h07F
`define AD_S_RT2_BASE       9'h080
`define AD_S_RT2_STRIDE     9'h081
`define AD_S_RT3_BASE       9'h082
`define AD_S_RT3_STRIDE     9'h083
`define AD_S_BLEND1         9'h084   // (spec) BLEND1..3 = 0x084..0x086
`define AD_S_BLEND2         9'h085
`define AD_S_BLEND3         9'h086
`define AD_S_BLEND_CONST_R  9'h087   // (spec) fp32 R,G,B,A = 0x087..0x08A
`define AD_S_BLEND_CONST_G  9'h088
`define AD_S_BLEND_CONST_B  9'h089
`define AD_S_BLEND_CONST_A  9'h08A
`define AD_S_DBOUNDS_MIN    9'h08B   // (spec) fp32
`define AD_S_DBOUNDS_MAX    9'h08C   // (spec) fp32
`define AD_S_ROP_CTRL       9'h08D   // (spec) see AD_ROPC_* below
`define AD_S_LOGIC_OP       9'h08E   // (spec) byte k: [0] enable, [4:1] VkLogicOp of RT k (layout ASSUMED)

// ---- ROP_CTRL bits ---------------------------------------------------------
`define AD_ROPC_OCC         0        // occlusion counting enable
`define AD_ROPC_FCONST      1        // use fp32 BLEND_CONST_R..A
`define AD_ROPC_LOGIC       2        // logic op enable, all RTs
`define AD_ROPC_DUALSRC     7        // dual-source factors 15..18 allowed

// ---- BLEND word fields -----------------------------------------------------
// [0] enable, [4:1] src colour, [8:5] dst colour, [11:9] colour op,
// [15:12] src alpha, [19:16] dst alpha, [22:20] alpha op,
// [23] src colour MSB, [24] dst colour MSB, [25] src alpha MSB, [26] dst alpha MSB
// (factor = {MSB, 4 bits}; MSBs count only with ROP_CTRL[7]).

// ---- VkBlendFactor ---------------------------------------------------------
`define AD_BF_ZERO      5'd0
`define AD_BF_ONE       5'd1
`define AD_BF_SC        5'd2
`define AD_BF_OMSC      5'd3
`define AD_BF_DC        5'd4
`define AD_BF_OMDC      5'd5
`define AD_BF_SA        5'd6
`define AD_BF_OMSA      5'd7
`define AD_BF_DA        5'd8
`define AD_BF_OMDA      5'd9
`define AD_BF_CC        5'd10
`define AD_BF_OMCC      5'd11
`define AD_BF_CA        5'd12
`define AD_BF_OMCA      5'd13
`define AD_BF_SAS       5'd14
`define AD_BF_S1C       5'd15
`define AD_BF_OMS1C     5'd16
`define AD_BF_S1A       5'd17
`define AD_BF_OMS1A     5'd18

// ---- VkBlendOp -------------------------------------------------------------
`define AD_BO_ADD       3'd0
`define AD_BO_SUB       3'd1
`define AD_BO_RSUB      3'd2
`define AD_BO_MIN       3'd3
`define AD_BO_MAX       3'd4

// ---- VkFormat codes the ROP handles ---------------------------------------
`define AD_VK_R5G6B5        8'd4
`define AD_VK_A1R5G5B5      8'd8
`define AD_VK_R8            8'd9
`define AD_VK_R8G8          8'd16
`define AD_VK_RGBA8         8'd37
`define AD_VK_RGBA8_SRGB    8'd43
`define AD_VK_BGRA8         8'd44
`define AD_VK_BGRA8_SRGB    8'd50
`define AD_VK_ABGR8         8'd51
`define AD_VK_ABGR8_SRGB    8'd57
`define AD_VK_A2B10G10R10   8'd64
`define AD_VK_R16F          8'd76
`define AD_VK_R16G16F       8'd83
`define AD_VK_R16G16B16A16F 8'd97

// ---- DEPTH word fields (spec ad_rop_dtest) ---------------------------------
`define AD_DEPTH_TEST   0
`define AD_DEPTH_WRITE  1
// [4:2] compare op
`define AD_DEPTH_D24S8  5
`define AD_DEPTH_D32F   6
`define AD_DEPTH_D16    7
`define AD_DEPTH_STEN   8
`define AD_DEPTH_BOUNDS 9

`endif
