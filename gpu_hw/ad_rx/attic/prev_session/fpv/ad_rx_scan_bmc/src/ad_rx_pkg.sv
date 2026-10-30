// ============================================================================
// ad_rx_pkg.sv -- every shared constant of the ad_rx rasterizer.
//
// Rule: every name declared in this package is at most 7 characters
// (enforced by tools/lint_pkg.py).  RTL references names with explicit
// scope (ad_rx_pkg::FP_W) because open-source Yosys does not accept
// wildcard imports; the same code reads unchanged in VCS / Xcelium / JG.
//
// Groups
//   1. Number formats            (fp32, 15.8 fixed point, edge values)
//   2. Geometry limits           (guard band, render target, tiles, MSAA)
//   3. Interface widths          (PT, STATE bus, sequence numbers)
//   4. STATE register addresses  (GHCI RX range)
//   5. sp_tri / cl_tri layouts   (field offsets and widths)
//   6. fp32 constants
//   7. Hi-Z and depth functions
// ============================================================================
package ad_rx_pkg;

  // --------------------------------------------------------------------------
  // 1. Number formats
  // --------------------------------------------------------------------------
  localparam int FP_W    = 32;   // IEEE-754 binary32
  localparam int FP_EW   = 8;    // exponent bits
  localparam int FP_MW   = 23;   // stored fraction bits
  localparam int FP_BIAS = 127;  // exponent bias
  localparam int FIX_F   = 8;    // subpixel fraction bits (1/256 px)
  localparam int FIX_W   = 24;   // snapped coordinate: signed 15.8
  localparam int FIX_SAT = (1 << 22) - 1;   // snap saturation magnitude
  localparam int EDGE_W  = 48;   // edge value, subpixel^2 units
  localparam int CRD_W   = 16;   // integer pixel coordinate
  localparam int MUL_W   = 25;   // operand width of the edge multiplier

  // --------------------------------------------------------------------------
  // 2. Geometry limits
  // --------------------------------------------------------------------------
  localparam int GUARD   = 16383;        // guard band, pixels (x, y)
  localparam int SUBPX   = 1 << FIX_F;   // 256 subpixels per pixel
  localparam int HALFPX  = SUBPX / 2;    // 128: pixel centre offset
  localparam int TILE_L2 = 3;            // coarse tile = 8 x 8 pixels
  localparam int TILE    = 1 << TILE_L2;
  localparam int QPT_L2  = TILE_L2 - 1;  // quads per tile row (log2) = 2
  localparam int NSAMP   = 4;            // max MSAA samples per pixel
  localparam int NLANE   = 4;            // lanes per quad
  localparam int NEDGE   = 3;            // edges per triangle
  localparam int WARP_Q  = 8;            // quads per 32-lane warp
  localparam int NWLANE  = WARP_Q * NLANE;
  localparam int VMAX    = 10;           // clip polygon: 3 + 7 planes
  localparam int VIDX_W  = 4;            // vertex index width (0..VMAX-1)
  localparam int VWORDS  = 7;            // words per clip vertex (xyzw + 3 weights)
  localparam int VTX_W   = VWORDS * FP_W;   // 224
  localparam int NPLANE  = 7;            // w, near, far, +-x, +-y guard
  localparam int VRY_MAX = 64;           // varying words per vertex
  localparam int NVP     = 16;           // viewport / scissor array entries

  // --------------------------------------------------------------------------
  // 3. Interface widths
  // --------------------------------------------------------------------------
  localparam int ST_IW   = 9;    // STATE index
  localparam int ST_DW   = 32;   // STATE data
  localparam int PT_IW   = 8;    // primitive-table entry index
  localparam int PT_WW   = 7;    // PT word index (0-3 pos, 4+w varying)
  localparam int SEQ_W   = 16;   // fragment sequence number
  localparam int FREG_W  = 7;    // setup fp register address
  localparam int FLR_W   = 6;    // fragment register index (r0..r9)
  localparam int FLL_W   = 5;    // warp lane index
  localparam int PWA_W   = 12;   // primitive-table word address
  localparam int INFO_W  = 64;   // fl_info width
  localparam int KIND_W  = 2;    // 0 point, 1 line, 2 triangle

  // --------------------------------------------------------------------------
  // 4. STATE register addresses (GHCI, RX range)
  // --------------------------------------------------------------------------
  localparam logic [ST_IW-1:0] SA_VP   = 9'h050;  // VIEWPORT 0x050-0x055
  localparam logic [ST_IW-1:0] SA_SMIN = 9'h056;  // SCISSOR_MIN {y,x}
  localparam logic [ST_IW-1:0] SA_SMAX = 9'h057;  // SCISSOR_MAX {y,x}
  localparam logic [ST_IW-1:0] SA_CULL = 9'h058;
  localparam logic [ST_IW-1:0] SA_DCLP = 9'h059;  // DEPTH_CLAMP
  localparam logic [ST_IW-1:0] SA_RMOD = 9'h05A;  // RAST_MODE
  localparam logic [ST_IW-1:0] SA_VCNT = 9'h05B;  // VARYING_COUNT
  localparam logic [ST_IW-1:0] SA_MSCT = 9'h05E;  // MS_CTRL
  localparam logic [ST_IW-1:0] SA_SKIL = 9'h05F;  // SAMPLE_KILL
  localparam logic [ST_IW-1:0] SA_DBC  = 9'h060;  // DEPTH_BIAS_CONST
  localparam logic [ST_IW-1:0] SA_DBS  = 9'h061;  // DEPTH_BIAS_SLOPE
  localparam logic [ST_IW-1:0] SA_DBCL = 9'h062;  // DEPTH_BIAS_CLAMP
  localparam logic [ST_IW-1:0] SA_LWID = 9'h063;  // LINE_WIDTH
  localparam logic [ST_IW-1:0] SA_PSIZ = 9'h064;  // POINT_SIZE
  localparam logic [ST_IW-1:0] SA_VIDX = 9'h065;  // VIEWPORT_IDX
  localparam logic [ST_IW-1:0] SA_ZFN  = 9'h066;  // DEPTH_FUNC (Hi-Z, ad_rx addition)
  localparam logic [ST_IW-1:0] SA_RTSZ = 9'h073;  // RT_SIZE {y,x}
  localparam logic [ST_IW-1:0] SA_RAW  = 9'h1E0;  // DRAW_RAW vertices 0x1E0-0x1E8

  // RAST_MODE bits
  localparam int RM_BIAS = 0;    // depth bias enable
  localparam int RM_VPR  = 3;    // cut by viewport rectangle
  localparam int RM_DISC = 6;    // rasterizer discard

  // --------------------------------------------------------------------------
  // 5. Bundle layouts
  // --------------------------------------------------------------------------
  // edge record = {E[47:0], B[23:0], A[23:0]}
  localparam int ER_W    = EDGE_W + 2 * FIX_W;      // 96
  localparam int EDGES_W = NEDGE * ER_W;            // 288
  localparam int BBOX_W  = 4 * CRD_W;               // 64 {ymax,xmax,ymin,xmin}
  localparam int PLANE_W = 3 * FP_W;                // 96 (A, B, C)

  // sp_tri (setup -> scan / frag), 768 bits
  localparam int SP_W    = 768;
  localparam int SP_EDG  = 0;                       // [287:0]
  localparam int SP_BBX  = SP_EDG + EDGES_W;        // [351:288]
  localparam int SP_PZ   = SP_BBX + BBOX_W;         // [447:352] z plane
  localparam int SP_PW   = SP_PZ + PLANE_W;         // [543:448] 1/w plane
  localparam int SP_PB0  = SP_PW + PLANE_W;         // [639:544] b0/w plane
  localparam int SP_PB1  = SP_PB0 + PLANE_W;        // [735:640] b1/w plane
  localparam int SP_PT   = SP_PB1 + PLANE_W;        // [759:736] 3 PT entries
  localparam int SP_LU   = SP_PT + 3 * PT_IW;       // [762:760] last-use flags
  localparam int SP_FR   = SP_LU + 3;               // [763] front facing
  localparam int SP_RAW  = SP_FR + 1;               // [764] raw
  localparam int SP_KND  = SP_RAW + 1;              // [766:765] kind
  localparam int PL4_W   = 4 * PLANE_W;             // 384: z, 1/w, b0/w, b1/w

  // cl_tri (clip -> setup), 702 bits
  localparam int CL_W    = 702;
  localparam int CL_POS  = 0;                       // [383:0] 3 x xyzw
  localparam int CL_WGT  = 384;                     // [671:384] 3 x 3 weights
  localparam int CL_PT   = 672;                     // [695:672]
  localparam int CL_LU   = 696;                     // [698:696]
  localparam int CL_RAW  = 699;
  localparam int CL_KND  = 700;                     // [701:700]

  // --------------------------------------------------------------------------
  // 6. fp32 constants
  // --------------------------------------------------------------------------
  localparam logic [FP_W-1:0] FP_ZERO = 32'h0000_0000;
  localparam logic [FP_W-1:0] FP_ONE  = 32'h3F80_0000;
  localparam logic [FP_W-1:0] FP_HALF = 32'h3F00_0000;
  localparam logic [FP_W-1:0] FP_QNAN = 32'h7FC0_0000;  // canonical NaN
  localparam logic [FP_W-1:0] FP_PINF = 32'h7F80_0000;
  localparam logic [FP_W-1:0] FP_WMIN = 32'h3780_0000;  // 2^-16 (w plane)
  localparam logic [FP_W-1:0] FP_GBND = 32'h467F_FC00;  // 16383.0
  localparam logic [FP_W-1:0] FP_TRV4 = 32'h4080_0000;  // 4.0 (trivial bound)

  // --------------------------------------------------------------------------
  // 7. Hi-Z
  // --------------------------------------------------------------------------
  localparam int HZ_ZW   = 16;   // stored tile depth (unorm16)
  localparam int HZ_GW   = 8;    // clear-generation tag
  localparam int RT_MAXL = 13;   // log2 max render-target side (8192 px)
  localparam int HZ_AW   = 2 * (RT_MAXL - TILE_L2);   // tile address width (20)

  // depth compare functions (same encoding as early_z_unit / Vulkan)
  localparam logic [2:0] DF_NEVR = 3'd0;
  localparam logic [2:0] DF_LESS = 3'd1;
  localparam logic [2:0] DF_EQ   = 3'd2;
  localparam logic [2:0] DF_LEQ  = 3'd3;
  localparam logic [2:0] DF_GRTR = 3'd4;
  localparam logic [2:0] DF_NEQ  = 3'd5;
  localparam logic [2:0] DF_GEQ  = 3'd6;
  localparam logic [2:0] DF_ALWS = 3'd7;

  // --------------------------------------------------------------------------
  // Shared helpers (fp32 field access)
  // --------------------------------------------------------------------------
  function automatic logic fp_nan(input logic [FP_W-1:0] f);
    fp_nan = (f[30:23] == 8'hFF) && (f[22:0] != 23'd0);
  endfunction

  function automatic logic fp_inf(input logic [FP_W-1:0] f);
    fp_inf = (f[30:23] == 8'hFF) && (f[22:0] == 23'd0);
  endfunction

  // zero or denormal: both read as zero (denormals flushed on input)
  function automatic logic fp_zer(input logic [FP_W-1:0] f);
    fp_zer = (f[30:23] == 8'h00);
  endfunction

endpackage
