`timescale 1ns / 1ps

// Shared types/functions for the tessellation-stage shaders (TCS + TES).
// Instruction encoding intentionally mirrors vertex_shader.sv's conventions
// (96-bit word, per-operand type/idx/swizzle fields) for consistency, but the
// opcode set is trimmed to what patch-constant / interpolation programs
// typically need. If perspective-correct interpolation or distance-based
// tess-level computation is required later, RCP/RSQ/DP3/DP4 can be ported
// back in from vertex_shader.sv's SFU logic.
package tess_common_pkg;

    localparam int DATA_W    = 32;
    localparam int FRAC_BITS = 16;
    localparam logic [DATA_W-1:0] ONE_FP  = (1 << FRAC_BITS);
    localparam logic [DATA_W-1:0] ZERO_FP = '0;

    typedef enum logic [7:0] {
        OP_NOP  = 8'h00,
        OP_ADD  = 8'h01,
        OP_SUB  = 8'h02,
        OP_MUL  = 8'h03,
        OP_MAD  = 8'h04,   // s0*s1 + s2
        OP_MOV  = 8'h05,
        OP_MIN  = 8'h06,
        OP_MAX  = 8'h07,
        OP_SGE  = 8'h08,
        OP_SLT  = 8'h09,
        OP_LERP = 8'h0A,   // s0 + s2*(s1 - s0)   (s2 = interpolation weight, typically u/v/w)
        OP_END  = 8'hFF
    } tess_opcode_t;

    // Source-operand register class. Meaning of SRC_CPIN and SRC_SPECIAL
    // differs by stage (documented in each module):
    //   TCS: SRC_CPIN  = patch input control points (vertex-shader output)
    //        SRC_SPECIAL = unused, reserved (reads as 0)
    //   TES: SRC_CPIN  = TCS output control points (this patch's post-TCS CPs)
    //        SRC_SPECIAL = domain coordinate register: lane0=u, lane1=v,
    //                      lane2=w (barycentric third coord, quads: =0), lane3=0
    typedef enum logic [1:0] {
        SRC_TEMP    = 2'b00,
        SRC_CPIN    = 2'b01,
        SRC_CONST   = 2'b10,
        SRC_SPECIAL = 2'b11
    } tess_src_type_t;

    // Destination-register class.
    //   TCS: DST_CPOUT      -> gl_out[current invocation] (implicit index, INV_RUN state only)
    //        DST_TESS_OUTER -> tess_level_outer[dst_idx[1:0]]  (PATCH_RUN state only, else ignored)
    //        DST_TESS_INNER -> tess_level_inner[dst_idx[0]]    (PATCH_RUN state only, else ignored)
    //   TES: DST_CPOUT      -> final output vertex attribute register dst_idx
    typedef enum logic [1:0] {
        DST_TEMP       = 2'b00,
        DST_CPOUT      = 2'b01,
        DST_TESS_OUTER = 2'b10,
        DST_TESS_INNER = 2'b11
    } tess_dst_type_t;

    // Sentinel source index meaning "current invocation" for SRC_CPIN reads
    // in the TCS per-invocation program (e.g. a straight pass-through
    // gl_out[ID] = gl_in[ID] pattern). Real hardware would reject/ignore this
    // encoding anywhere idx width is smaller than 6 bits; NUM_IN_CP/NUM_OUT_CP
    // must therefore stay <= 63 for the sentinel to be unambiguous.
    localparam logic [5:0] CPIN_SELF_IDX = 6'h3F;

    function automatic logic [DATA_W-1:0] fx_mul(
        logic [DATA_W-1:0] a, logic [DATA_W-1:0] b
    );
        logic [DATA_W*2-1:0] p;
        p = $signed(a) * $signed(b);
        return p[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
    endfunction

    function automatic logic [DATA_W-1:0] apply_swizzle(
        logic [DATA_W-1:0] vec [0:3], logic [7:0] swz, int lane
    );
        logic [1:0] sel;
        begin
            case (lane)
                0: sel = swz[1:0];
                1: sel = swz[3:2];
                2: sel = swz[5:4];
                3: sel = swz[7:6];
            endcase
            case (sel)
                2'b00: return vec[0];
                2'b01: return vec[1];
                2'b10: return vec[2];
                2'b11: return vec[3];
            endcase
        end
    endfunction

endpackage
