// ============================================================================
// ad_rx_pkg -- every width, constant and STATE index of the ad_rx rasterizer.
//
// Rule: every name in this package is exactly 7 characters.  Modules refer to
// them as ad_rx_pkg::NAME (explicit scope: works in Yosys 0.33, Verilator,
// Icarus, JasperGold and VCS alike; no file-scope import needed).
//
// Groups:  configuration (CFG), fp32, interfaces, geometry, tiles / Hi-Z,
//          fragment warps, STATE indices, fp32 constants.
// ============================================================================
package ad_rx_pkg;

  // ---------------------------------------------------------------- config
  parameter int HAS_SU_ = 1;        // 1: fragment warps to the SU; 0: direct quads
  parameter int EN_MSAA = 1;        // multisampling coverage logic present
  parameter int EN_EZHZ = 1;        // hierarchical early-Z (Hi-Z) present
  parameter int EN_CRSE = 1;        // 8x8 coarse tile skip present
  parameter int MS_SMAX = 4;        // samples evaluated in parallel (1 or 4)

  // ---------------------------------------------------------------- fp32
  parameter int FP_WDTH = 32;       // IEEE single
  parameter int FP_EXPW = 8;        // exponent bits
  parameter int FP_MANW = 23;       // stored fraction bits
  parameter int FP_SIGW = 24;       // significand incl. hidden one
  parameter int FP_BIAS = 127;      // exponent bias
  parameter int FDV_ITR = 26;       // fdiv quotient bits (24 + guard + 1 for normalisation)

  // ---------------------------------------------------------------- STATE bus
  parameter int ST_IDXW = 9;        // STATE index
  parameter int ST_DATW = 32;       // STATE word

  // ---------------------------------------------------------------- PT / primitives
  parameter int PT_IDXW = 8;        // PT entry index
  parameter int PT_WRDW = 7;        // PT word: 0-3 position, 4 + w varying w (w < 64 needs 7 bits)
  parameter int PRM_KDW = 2;        // primitive kind: 0 point, 1 line, 2 triangle
  parameter int PRM_VTW = 3*PT_IDXW + PRM_KDW;   // prim_vtx = 26

  // ---------------------------------------------------------------- clip / cpoly
  parameter int VTX_WRD = 7;        // x y z w b0 b1 b2
  parameter int VTX_WID = VTX_WRD*FP_WDTH;       // 224
  parameter int PLY_MAX = 10;       // 3 + one vertex per plane x 7 planes
  parameter int PLY_IDX = 4;        // $clog2(PLY_MAX)
  parameter int CPL_NPL = 7;        // clip planes: w, near, far, +x, -x, +y, -y
  parameter int CPL_SEL = 3;        // plane select width
  // cl_tri = 3 x xyzw (384) + 3 x 3 weights (288) + 3 PT (24) + 3 last-use + raw + kind (2)
  parameter int CLT_WID = 12*FP_WDTH + 9*FP_WDTH + 3*PT_IDXW + 3 + 1 + PRM_KDW;   // 702

  // ---------------------------------------------------------------- fixed point and edges
  parameter int FIX_WID = 24;       // signed 15.8 subpixel coordinate
  parameter int FIX_FRC = 8;        // subpixel bits (256 subpixels per pixel)
  parameter int FIX_SAT = (1 << 22) - 1;          // +-16383.996 px guard band
  parameter int EDG_COF = 24;       // edge A, B (subpixel deltas, signed)
  parameter int EDG_ACC = 48;       // edge value E (subpixel^2; 2 x 24 + headroom)
  parameter int EDG_PCK = EDG_ACC + 2*EDG_COF;    // one edge {E, B, A} = 96
  parameter int CRD_WID = 16;       // pixel coordinate / bbox field
  parameter int BBX_WID = 4*CRD_WID;              // {ymax, xmax, ymin, xmin} = 64

  // ---------------------------------------------------------------- sp_tri (setup -> scan / frag)
  // [287:0] 3 edges, [351:288] bbox, [447:352] z plane, [543:448] 1/w plane,
  // [735:544] b0/w, b1/w planes, [759:736] PT entries, [762:760] last use,
  // [763] front, [764] raw, [766:765] kind, [767] 0, [799:768] zmin, [831:800] zmax (fp32, new)
  parameter int SPT_WID = 832;
  parameter int SPT_EDG = 0;
  parameter int SPT_BBX = 288;
  parameter int SPT_PLZ = 352;      // planes start: z, 1/w, b0/w, b1/w (96 bits each)
  parameter int SPT_PTE = 736;
  parameter int SPT_LST = 760;
  parameter int SPT_FRT = 763;
  parameter int SPT_RAW = 764;
  parameter int SPT_KND = 765;
  parameter int SPT_ZMN = 768;      // zmin fp32 (Hi-Z, new)
  parameter int SPT_ZMX = 800;      // zmax fp32 (Hi-Z, new)
  parameter int PLN_WID = 3*FP_WDTH;              // one plane {C, B, A} = 96
  parameter int PLN_ALL = 4*PLN_WID;              // 384

  // ---------------------------------------------------------------- tiles, quads, samples
  parameter int TILE_PX = 8;        // coarse tile edge in pixels
  parameter int TILE_SH = 3;        // log2(TILE_PX)
  parameter int TILE_QD = TILE_PX/2;              // quads per tile row = 4
  parameter int QD_LANE = 4;        // pixels per quad
  parameter int MS_COVW = QD_LANE*4;              // fq_scov: 4 lanes x 4 samples = 16
  parameter int SMP_OFS = 3;        // lane location select: 0 centre, 1+s sample s

  // ---------------------------------------------------------------- Hi-Z
  parameter int HZ_DEPW = 16;       // unorm depth stored per tile
  parameter int HZ_ADRW = 11;       // 2048 tiles (e.g. 512 x 256 px of 8x8 tiles)
  parameter int HZ_GENW = 8;        // generation tag (clear without a sweep)
  parameter int HZ_TLXW = 6;        // tiles per row = 2^6 = 64 (512 px)
  parameter int HZ_MSKW = TILE_PX*TILE_PX;        // per-tile written-pixel mask = 64

  // ---------------------------------------------------------------- fragment warps
  parameter int LANE_NB = 32;       // lanes per warp
  parameter int LANE_IW = 5;        // lane index
  parameter int QUAD_MX = LANE_NB/QD_LANE;        // 8 quads per warp
  parameter int VAR_MAX = 64;       // varying words per vertex (Vulkan 1.0 limit)
  parameter int FL_REGW = 6;        // fl_reg
  parameter int FL_ADRW = 12;       // fl_pw_addr
  parameter int FL_INFW = 64;       // fl_info
  parameter int SEQ_WID = 16;       // fragment sequence number
  parameter int QXY_WID = 2*CRD_WID;              // {y, x}

  // ---------------------------------------------------------------- STATE indices (design 2.3)
  parameter int S_VIEWP = 'h050;    // VIEWPORT x scale, y scale, x off, y off, zmin, zmax (0x050-0x055)
  parameter int S_SCMIN = 'h056;    // SCISSOR_MIN {y, x}
  parameter int S_SCMAX = 'h057;    // SCISSOR_MAX {y, x}
  parameter int S_CULLM = 'h058;    // CULL [2:0]
  parameter int S_DCLMP = 'h059;    // DEPTH_CLAMP [0] clamp, [1] clip
  parameter int S_RMODE = 'h05A;    // RAST_MODE
  parameter int S_VARYC = 'h05B;    // VARYING_COUNT
  parameter int S_MSCTL = 'h05E;    // MS_CTRL [3:0] samples code, [4] CENTROID
  parameter int S_SKILL = 'h05F;    // SAMPLE_KILL [3:0]
  parameter int S_DBCON = 'h060;    // DEPTH_BIAS_CONST
  parameter int S_DBSLP = 'h061;    // DEPTH_BIAS_SLOPE
  parameter int S_DBCLP = 'h062;    // DEPTH_BIAS_CLAMP
  parameter int S_LWDTH = 'h063;    // LINE_WIDTH (fp32)
  parameter int S_PSIZE = 'h064;    // POINT_SIZE (fp32)
  parameter int S_VPIDX = 'h065;    // VIEWPORT_IDX (0-15)
  parameter int S_DFUNC = 'h066;    // DEPTH_FUNC for Hi-Z [2:0] + [3] enable (NEW, see doc 4)
  parameter int S_RTSIZ = 'h073;    // RT_SIZE {y, x}
  parameter int S_RAWV0 = 'h1E0;    // DRAW_RAW vertices 0x1E0-0x1E8 (3 x {x, y, z})
  parameter int VP_ENTR = 16;       // viewport / scissor array entries
  parameter int VP_IDXW = 4;

  // ---------------------------------------------------------------- fp32 constants
  parameter logic [31:0] FP_ZERO = 32'h0000_0000;
  parameter logic [31:0] FP_ONEV = 32'h3F80_0000;   // 1.0
  parameter logic [31:0] FP_HALF = 32'h3F00_0000;   // 0.5
  parameter logic [31:0] FP_EIGH = 32'h3E00_0000;   // 0.125 (sample offsets in eighths)
  parameter logic [31:0] FP_QNAN = 32'h7FC0_0000;   // canonical NaN
  parameter logic [31:0] FP_PINF = 32'h7F80_0000;
  parameter logic [31:0] FP_WMIN = 32'h3780_0000;   // 2^-16, the w plane
  parameter logic [31:0] FP_GRDB = 32'h467F_FC00;   // 16383.0, the guard band
  parameter logic [31:0] FP_TRIV = 32'h4080_0000;   // 4.0, trivial-accept bound |x| <= 4w
  parameter logic [31:0] FP_VOFF = 32'h45C0_0000;   // 6144.0, |x_off| limit for trivial accept
  parameter logic [31:0] FP_VSCL = 32'h4500_0000;   // 2048.0, |x_scale| limit for trivial accept
  parameter logic [31:0] FP_U16M = 32'h477F_FF00;   // 65535.0 (unorm16 scale)

endpackage
