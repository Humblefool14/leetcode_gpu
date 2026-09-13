`timescale 1ns / 1ps
import tess_common_pkg::*;

// Geometry Shader (GS) -- v2: adds indexed SRC_CPIN addressing + a small
// branch/loop stack, so the program can express "for each valid input
// vertex, do X, conditionally emit" instead of only fully-unrolled
// straight-line code. Mirrors the branching/loop-stack pattern already used
// in the vertex shader; this is the GS-specific instantiation of the same
// idea, sized down since GS loop nesting is shallow in practice (loop over
// input vertices, optionally loop over output attributes).
//
// ==================== REQUIRED tess_common_pkg CHANGES ====================
// Add three new opcodes to tess_opcode_t (any encoding not already used):
//   OP_LOOP_START,   // src0 = iteration count (see semantics below)
//   OP_LOOP_END,     // closes the innermost open OP_LOOP_START
//   OP_BRA           // conditional branch: if (src0 lane0 != 0) pc <- bra_target
// No other package changes needed -- everything else reuses existing types
// (tess_src_type_t, tess_dst_type_t) and 28 bits of the 96-bit instruction
// word that were unused in v1 (bits [27:0]).
//
// ==================== NEW INSTRUCTION FIELDS (bits [27:0], previously unused) ====
//   [27:26] s0_idxm   -- 2'b00 = no indexing, 2'b01 = add idx_reg[0],
//                        2'b10 = add idx_reg[1] to this source's SRC_CPIN
//                        vertex-select field before the register read.
//   [25:24] s1_idxm   -- same, for source 1
//   [23:22] s2_idxm   -- same, for source 2
//   [21:14] bra_target -- absolute PC target for OP_BRA (width = PC_W; the
//                         parameterized default PC_W=8 exactly fits this
//                         8-bit slice -- if you resize PC_W, resize this
//                         field too).
//   [13:0]  reserved
//
// ==================== SEMANTICS ====================
//  - idx_reg[0], idx_reg[1]: two small counters, each written implicitly by
//    OP_LOOP_START/OP_LOOP_END (loop nest depth 0 and 1 respectively). They
//    are NOT general-purpose registers -- they only exist to drive indexed
//    SRC_CPIN addressing for "for each vertex" style loops. Programs that
//    need a plain scalar loop counter for other purposes should still copy
//    idx_reg into a temp_reg via a MOV-from-special path if needed (not
//    added here to keep the change minimal).
//  - OP_LOOP_START: push {return_pc = pc+1, count = src0 lane0 truncated to
//    8 bits} onto loop_stack, reset the corresponding idx_reg to 0. Typical
//    use: src0 reads prim_num_verts via SRC_SPECIAL so the loop trip count
//    is the actual valid-vertex count for whatever primitive type is bound
//    this invocation (points/lines/tris/adjacency), keeping the program
//    primitive-type-agnostic as intended.
//  - OP_LOOP_END: decrement the innermost frame's count; if it was already
//    <=1, pop the frame and fall through (loop exits); otherwise jump back
//    to the frame's stored pc and increment that nest level's idx_reg.
//  - OP_BRA: predicated absolute jump. if (src0 lane0 != 0) pc <- bra_target
//    else pc <- pc+1. Used for conditional emit (e.g. silhouette edge test)
//    without needing a full jump-target-in-register mechanism.
//  - LOOP_DEPTH is fixed at 2: one loop over input vertices is the common
//    case (flat shading, silhouette extrusion), and a second nested level
//    covers e.g. an inner loop over output attributes if a program wants
//    one. Deeper nesting is not supported by this revision.
//
// (See v1 header comment for the rest of the module's behavior --
// EmitVertex/EndPrimitive semantics, bounded output buffering, decoupled
// execution/streaming -- all unchanged.)
module geometry_shader #(
    parameter int PC_W          = 8,
    parameter int MAX_IN_VERTS  = 6,   // 1=point,2=line,3=tri,4=lines_adj,6=tris_adj
    parameter int NUM_IN_ATTR   = 8,   // must satisfy $clog2(MAX_IN_VERTS)+$clog2(NUM_IN_ATTR) <= 6
    parameter int NUM_OUT_ATTR  = 12,
    parameter int MAX_OUT_VERTS = 16,
    parameter int NUM_TEMP      = 8,
    parameter int NUM_CONST     = 16,
    parameter int INST_W        = 96,
    parameter int VTX_W         = $clog2(MAX_IN_VERTS),
    parameter int ATTR_W        = $clog2(NUM_IN_ATTR),
    parameter int EMIT_W        = $clog2(MAX_OUT_VERTS+1),
    parameter int LOOP_DEPTH    = 2    // fixed nesting depth for the new loop stack
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic               start,
    input  logic [2:0]         prim_num_verts,   // valid input-vertex count this invocation
    input  logic [DATA_W-1:0]  primitive_id,     // gl_PrimitiveIDIn
    output logic               busy,
    output logic               done,

    output logic [PC_W-1:0]    pc,
    input  logic [INST_W-1:0]  inst_rdata,

    // primitive input vertices: load one (vtx, attr) register at a time
    input  logic                vin_valid,
    input  logic [VTX_W-1:0]    vin_vtx,
    input  logic [ATTR_W-1:0]   vin_attr,
    input  logic [3:0]          vin_mask,
    input  logic [DATA_W-1:0]   vin_data [0:3],

    input  logic                const_valid,
    input  logic [3:0]          const_idx,
    input  logic [3:0]          const_mask,
    input  logic [DATA_W-1:0]   const_data [0:3],

    // emitted-vertex output stream, one attribute register at a time
    output logic                vout_valid,
    output logic [3:0]          vout_attr,
    output logic [DATA_W-1:0]   vout_data [0:3],
    output logic                vout_cut,     // pulses on the last attr cycle of a strip-ending vertex
    input  logic                vout_ack,
    output logic [EMIT_W-1:0]   total_emitted // valid once `done` is asserted
);

    // synthesis-time sanity checks
    initial begin
        if (VTX_W + ATTR_W > 6)
            $error("geometry_shader: VTX_W(%0d)+ATTR_W(%0d) exceeds 6-bit source index field", VTX_W, ATTR_W);
        if (PC_W > 8)
            $error("geometry_shader: PC_W(%0d) exceeds the 8-bit bra_target instruction field", PC_W);
    end

    tess_opcode_t   dec_opcode;
    logic [3:0]     dec_dst_mask;
    tess_dst_type_t dec_dst_type;
    logic [5:0]     dec_dst_idx;
    tess_src_type_t dec_s0_type, dec_s1_type, dec_s2_type;
    logic [5:0]     dec_s0_idx,  dec_s1_idx,  dec_s2_idx;
    logic [7:0]     dec_s0_swz,  dec_s1_swz,  dec_s2_swz;

    // -- new fields, packed into the 28 bits that were unused in v1 --
    logic [1:0]      dec_s0_idxm, dec_s1_idxm, dec_s2_idxm;
    logic [PC_W-1:0] dec_bra_target;

    assign dec_opcode   = tess_opcode_t'(inst_rdata[95:88]);
    assign dec_dst_mask = inst_rdata[87:84];
    assign dec_dst_type = tess_dst_type_t'(inst_rdata[83:82]);
    assign dec_dst_idx  = inst_rdata[81:76];
    assign dec_s0_type  = tess_src_type_t'(inst_rdata[75:74]);
    assign dec_s0_idx   = inst_rdata[73:68];
    assign dec_s0_swz   = inst_rdata[67:60];
    assign dec_s1_type  = tess_src_type_t'(inst_rdata[59:58]);
    assign dec_s1_idx   = inst_rdata[57:52];
    assign dec_s1_swz   = inst_rdata[51:44];
    assign dec_s2_type  = tess_src_type_t'(inst_rdata[43:42]);
    assign dec_s2_idx   = inst_rdata[41:36];
    assign dec_s2_swz   = inst_rdata[35:28];

    assign dec_s0_idxm     = inst_rdata[27:26];
    assign dec_s1_idxm     = inst_rdata[25:24];
    assign dec_s2_idxm     = inst_rdata[23:22];
    assign dec_bra_target  = inst_rdata[21:14];

    logic [DATA_W-1:0] temp_reg  [0:NUM_TEMP-1][0:3];
    logic [DATA_W-1:0] const_reg [0:NUM_CONST-1][0:3];
    logic [DATA_W-1:0] vin_reg   [0:MAX_IN_VERTS-1][0:NUM_IN_ATTR-1][0:3];
    logic [DATA_W-1:0] out_reg   [0:NUM_OUT_ATTR-1][0:3];

    logic [DATA_W-1:0] special_vec [0:3];
    assign special_vec[0] = primitive_id;
    assign special_vec[1] = {{(DATA_W-3){1'b0}}, prim_num_verts}; // exposed so OP_LOOP_START can drive a
                                                                    // "for each valid input vertex" loop
    assign special_vec[2] = '0;
    assign special_vec[3] = '0;

    // -- new: loop stack + indexed-addressing counters --
    typedef struct packed {
        logic [PC_W-1:0] loop_pc;
        logic [7:0]      count;
    } loop_frame_t;

    loop_frame_t loop_stack      [0:LOOP_DEPTH-1];
    loop_frame_t loop_stack_next [0:LOOP_DEPTH-1];
    logic [$clog2(LOOP_DEPTH+1)-1:0] loop_sp, loop_sp_next;

    logic [VTX_W-1:0] idx_reg      [0:LOOP_DEPTH-1];
    logic [VTX_W-1:0] idx_reg_next [0:LOOP_DEPTH-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int v = 0; v < MAX_IN_VERTS; v++)
                for (int a = 0; a < NUM_IN_ATTR; a++)
                    for (int c = 0; c < 4; c++) vin_reg[v][a][c] <= '0;
            for (int i = 0; i < NUM_CONST; i++)
                for (int c = 0; c < 4; c++) const_reg[i][c] <= '0;
        end else begin
            if (vin_valid)
                for (int c = 0; c < 4; c++)
                    if (vin_mask[c]) vin_reg[vin_vtx][vin_attr][c] <= vin_data[c];
            if (const_valid)
                for (int c = 0; c < 4; c++)
                    if (const_mask[c]) const_reg[const_idx][c] <= const_data[c];
        end
    end

    function automatic logic [DATA_W-1:0] read_src(
        tess_src_type_t stype, logic [5:0] idx, int comp
    );
        case (stype)
            SRC_TEMP:    return temp_reg[idx[$clog2(NUM_TEMP)-1:0]][comp];
            SRC_CPIN:    return vin_reg[idx[VTX_W+ATTR_W-1:ATTR_W]][idx[ATTR_W-1:0]][comp];
            SRC_CONST:   return const_reg[idx[$clog2(NUM_CONST)-1:0]][comp];
            SRC_SPECIAL: return special_vec[comp];
            default:     return '0;
        endcase
    endfunction

    // -- new: apply indexed addressing to the vertex-select bits of a
    // SRC_CPIN index before it reaches read_src. Only meaningful when the
    // source type is SRC_CPIN and idxm != 0; for all other types/modes the
    // raw decoded index passes through unchanged. Program correctness is
    // responsible for keeping the resulting vertex-select in-range for
    // MAX_IN_VERTS, same as v1's assumption for the raw decoded index.
    function automatic logic [5:0] apply_idx_mode(
        tess_src_type_t stype, logic [5:0] raw_idx, logic [1:0] idxm
    );
        logic [VTX_W-1:0] add_v;
        if (stype != SRC_CPIN || idxm == 2'b00) return raw_idx;
        add_v = (idxm == 2'b01) ? idx_reg[0] : idx_reg[1];
        return raw_idx + (add_v << ATTR_W);
    endfunction

    logic [5:0] eff_s0_idx, eff_s1_idx, eff_s2_idx;
    assign eff_s0_idx = apply_idx_mode(dec_s0_type, dec_s0_idx, dec_s0_idxm);
    assign eff_s1_idx = apply_idx_mode(dec_s1_type, dec_s1_idx, dec_s1_idxm);
    assign eff_s2_idx = apply_idx_mode(dec_s2_type, dec_s2_idx, dec_s2_idxm);

    logic [DATA_W-1:0] s0_raw [0:3], s1_raw [0:3], s2_raw [0:3];
    logic [DATA_W-1:0] s0_sw  [0:3], s1_sw  [0:3], s2_sw  [0:3];

    generate
        genvar gi;
        for (gi = 0; gi < 4; gi++) begin : gen_src_rd
            assign s0_raw[gi] = read_src(dec_s0_type, eff_s0_idx, gi);  // was dec_s0_idx
            assign s1_raw[gi] = read_src(dec_s1_type, eff_s1_idx, gi);  // was dec_s1_idx
            assign s2_raw[gi] = read_src(dec_s2_type, eff_s2_idx, gi);  // was dec_s2_idx
            assign s0_sw[gi]  = apply_swizzle(s0_raw, dec_s0_swz, gi);
            assign s1_sw[gi]  = apply_swizzle(s1_raw, dec_s1_swz, gi);
            assign s2_sw[gi]  = apply_swizzle(s2_raw, dec_s2_swz, gi);
        end
    endgenerate

    logic [DATA_W-1:0] alu_result [0:3];
    generate
        genvar lane;
        for (lane = 0; lane < 4; lane++) begin : gen_alu
            always_comb begin
                case (dec_opcode)
                    OP_ADD:  alu_result[lane] = s0_sw[lane] + s1_sw[lane];
                    OP_SUB:  alu_result[lane] = s0_sw[lane] - s1_sw[lane];
                    OP_MUL:  alu_result[lane] = fx_mul(s0_sw[lane], s1_sw[lane]);
                    OP_MAD:  alu_result[lane] = fx_mul(s0_sw[lane], s1_sw[lane]) + s2_sw[lane];
                    OP_MOV:  alu_result[lane] = s0_sw[lane];
                    OP_MIN:  alu_result[lane] = ($signed(s0_sw[lane]) < $signed(s1_sw[lane])) ? s0_sw[lane] : s1_sw[lane];
                    OP_MAX:  alu_result[lane] = ($signed(s0_sw[lane]) > $signed(s1_sw[lane])) ? s0_sw[lane] : s1_sw[lane];
                    OP_SGE:  alu_result[lane] = ($signed(s0_sw[lane]) >= $signed(s1_sw[lane])) ? ONE_FP : ZERO_FP;
                    OP_SLT:  alu_result[lane] = ($signed(s0_sw[lane]) <  $signed(s1_sw[lane])) ? ONE_FP : ZERO_FP;
                    OP_LERP: alu_result[lane] = s0_sw[lane] + fx_mul(s2_sw[lane], s1_sw[lane] - s0_sw[lane]);
                    default: alu_result[lane] = '0; // OP_NOP/OP_EMIT/OP_CUT/OP_END/OP_LOOP_*/OP_BRA don't write via alu_result
                endcase
            end
        end
    endgenerate

    // ---- emit buffer ----
    logic [DATA_W-1:0] emit_buf [0:MAX_OUT_VERTS-1][0:NUM_OUT_ATTR-1][0:3];
    logic               emit_cut [0:MAX_OUT_VERTS-1];
    logic [EMIT_W-1:0]  emit_wr_ptr, emit_wr_ptr_next;

    typedef enum logic [1:0] { ST_IDLE, ST_RUN, ST_STREAM, ST_DONE } state_t;
    state_t          state, next_state;
    logic [PC_W-1:0] pc_reg, pc_next;
    logic [EMIT_W-1:0] emit_rd_ptr, emit_rd_ptr_next;
    logic [3:0]        attr_idx, attr_idx_next;

    assign pc = pc_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; pc_reg <= '0; emit_wr_ptr <= '0;
            emit_rd_ptr <= '0; attr_idx <= '0;
            loop_sp <= '0;
            for (int i = 0; i < LOOP_DEPTH; i++) begin
                loop_stack[i] <= '0;
                idx_reg[i]    <= '0;
            end
        end else begin
            state <= next_state; pc_reg <= pc_next; emit_wr_ptr <= emit_wr_ptr_next;
            emit_rd_ptr <= emit_rd_ptr_next; attr_idx <= attr_idx_next;
            loop_sp <= loop_sp_next;
            loop_stack <= loop_stack_next;
            idx_reg <= idx_reg_next;
        end
    end

    always_comb begin
        next_state       = state;
        pc_next          = pc_reg;
        emit_wr_ptr_next = emit_wr_ptr;
        emit_rd_ptr_next = emit_rd_ptr;
        attr_idx_next    = attr_idx;
        loop_sp_next      = loop_sp;
        loop_stack_next   = loop_stack;
        idx_reg_next      = idx_reg;
        busy = 1'b0;
        done = 1'b0;

        case (state)
            ST_IDLE: if (start) begin
                next_state       = ST_RUN;
                pc_next          = '0;
                emit_wr_ptr_next = '0;
                loop_sp_next      = '0;   // fresh invocation starts with an empty loop stack
            end
            ST_RUN: begin
                busy = 1'b1;
                case (dec_opcode)
                    OP_END: begin
                        next_state       = ST_STREAM;
                        emit_rd_ptr_next = '0;
                        attr_idx_next    = '0;
                    end
                    OP_LOOP_START: begin
                        // src0 (typically SRC_SPECIAL -> prim_num_verts) supplies the trip count.
                        // Pushes onto the stack at the current loop_sp and resets that nesting
                        // level's idx_reg to 0. Loop body starts at pc+1.
                        loop_stack_next[loop_sp].loop_pc = pc_reg + 1'b1;
                        loop_stack_next[loop_sp].count   = s0_sw[0][7:0];
                        idx_reg_next[loop_sp]             = '0;
                        loop_sp_next                      = loop_sp + 1'b1;
                        pc_next                           = pc_reg + 1'b1;
                    end
                    OP_LOOP_END: begin
                        // closes the innermost open loop (loop_sp-1)
                        if (loop_stack[loop_sp-1].count <= 8'd1) begin
                            loop_sp_next = loop_sp - 1'b1;      // trip count exhausted: pop, fall through
                            pc_next      = pc_reg + 1'b1;
                        end else begin
                            loop_stack_next[loop_sp-1].count = loop_stack[loop_sp-1].count - 8'd1;
                            idx_reg_next[loop_sp-1]           = idx_reg[loop_sp-1] + 1'b1;
                            pc_next                            = loop_stack[loop_sp-1].loop_pc; // jump back
                        end
                    end
                    OP_BRA: begin
                        // predicated absolute jump: branch if src0 lane0 is non-zero
                        pc_next = (s0_sw[0] != '0) ? dec_bra_target : pc_reg + 1'b1;
                    end
                    default: pc_next = pc_reg + 1'b1; // OP_EMIT/OP_CUT side effects handled in the FF block below
                endcase
            end
            ST_STREAM: begin
                busy = 1'b1;
                if (emit_wr_ptr == 0) begin
                    next_state = ST_DONE; // nothing was ever emitted this invocation
                end else if (vout_ack) begin
                    if (attr_idx + 1 >= NUM_OUT_ATTR) begin
                        attr_idx_next = '0;
                        if (emit_rd_ptr + 1 >= emit_wr_ptr)
                            next_state       = ST_DONE;
                        else
                            emit_rd_ptr_next = emit_rd_ptr + 1'b1;
                    end else begin
                        attr_idx_next = attr_idx + 1'b1;
                    end
                end
            end
            ST_DONE: begin
                done = 1'b1;
                if (!start) next_state = ST_IDLE;
            end
        endcase
    end

    // ---- writeback: temp/out_reg during RUN, emit_buf snapshot on OP_EMIT, cut marker on OP_CUT ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_TEMP; i++)     for (int c = 0; c < 4; c++) temp_reg[i][c] <= '0;
            for (int i = 0; i < NUM_OUT_ATTR; i++) for (int c = 0; c < 4; c++) out_reg[i][c]  <= '0;
            for (int v = 0; v < MAX_OUT_VERTS; v++) emit_cut[v] <= 1'b0;
        end else if (state == ST_IDLE && start) begin
            // fresh invocation: clear working output regs (documented reset-per-invocation choice)
            for (int i = 0; i < NUM_OUT_ATTR; i++) for (int c = 0; c < 4; c++) out_reg[i][c] <= '0;
        end else if (state == ST_RUN) begin
            unique case (dec_opcode)
                OP_EMIT: begin
                    if (emit_wr_ptr < MAX_OUT_VERTS) begin
                        for (int a = 0; a < NUM_OUT_ATTR; a++)
                            for (int c = 0; c < 4; c++) emit_buf[emit_wr_ptr][a][c] <= out_reg[a][c];
                        emit_cut[emit_wr_ptr] <= 1'b0;
                    end
                    // else: MAX_OUT_VERTS exceeded -- dropped, see overflow assertion below
                end
                OP_CUT: begin
                    if (emit_wr_ptr > 0) emit_cut[emit_wr_ptr - 1] <= 1'b1;
                    // else: EndPrimitive with nothing emitted since last cut -- no-op, per GL spec
                end
                OP_NOP, OP_END, OP_LOOP_START, OP_LOOP_END, OP_BRA: ; // no out_reg/temp_reg writeback
                default: begin
                    for (int c = 0; c < 4; c++)
                        if (dec_dst_mask[c]) begin
                            case (dec_dst_type)
                                DST_TEMP:  temp_reg[dec_dst_idx[$clog2(NUM_TEMP)-1:0]][c] <= alu_result[c];
                                DST_CPOUT: out_reg[dec_dst_idx[$clog2(NUM_OUT_ATTR)-1:0]][c] <= alu_result[c];
                                default: ; // DST_TESS_OUTER/INNER not meaningful in GS
                            endcase
                        end
                end
            endcase
        end
    end

    assign vout_valid = (state == ST_STREAM) && (emit_wr_ptr != 0);
    assign vout_attr  = attr_idx;
    assign vout_data  = emit_buf[emit_rd_ptr][attr_idx];
    assign vout_cut   = vout_valid && (attr_idx == NUM_OUT_ATTR-1) && emit_cut[emit_rd_ptr];
    assign total_emitted = emit_wr_ptr;

    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && dec_opcode == OP_EMIT) |-> (emit_wr_ptr < MAX_OUT_VERTS))
        else $warning("geometry_shader: OP_EMIT exceeded MAX_OUT_VERTS=%0d, vertex dropped", MAX_OUT_VERTS);
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN) |-> ##[1:256] state != ST_RUN);
    assert property (@(posedge clk) disable iff (!rst_n) prim_num_verts <= MAX_IN_VERTS);

    // -- new: loop stack must never be popped/decremented past empty. If this fires,
    // an OP_LOOP_END executed with no matching open OP_LOOP_START -- a program bug.
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && dec_opcode == OP_LOOP_END) |-> (loop_sp > 0))
        else $error("geometry_shader: OP_LOOP_END with no open loop (loop_sp==0)");
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && dec_opcode == OP_LOOP_START) |-> (loop_sp < LOOP_DEPTH))
        else $error("geometry_shader: OP_LOOP_START nesting exceeds LOOP_DEPTH=%0d", LOOP_DEPTH);

endmodule
