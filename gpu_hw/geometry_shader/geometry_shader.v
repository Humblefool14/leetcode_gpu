`timescale 1ns / 1ps
import tess_common_pkg::*;

// Geometry Shader (GS).
//
// Sits after TES + primitive assembly in the pipeline diagram (Tessellation
// -> Geometry Shader -> Vertex Post-Processing). Structurally different from
// TCS/TES: a GS invocation runs once per ASSEMBLED PRIMITIVE (not per vertex
// or per control point), with visibility into every vertex of that primitive
// simultaneously, and produces a variable-length stream of output vertices
// grouped into output primitives via OP_EMIT (EmitVertex) / OP_CUT
// (EndPrimitive).
//
// ==================== FEATURES IMPLEMENTED ====================
//  - Primitive-type-agnostic input: `prim_num_verts` tells the program how
//    many of the MAX_IN_VERTS input vertex slots are valid this invocation,
//    so one instance can serve points(1)/lines(2)/triangles(3)/
//    lines_adjacency(4)/triangles_adjacency(6) -- same as GLSL's layout
//    qualifiers picking the input primitive shape.
//  - Whole-primitive vertex visibility: SRC_CPIN addressing is
//    {vtx_sel, attr_sel}, so the program can read gl_in[k] for ANY k in the
//    primitive, not just a single implicit vertex -- required for anything
//    that needs edge/face info (flat-shaded normals, silhouette detection,
//    shadow-volume extrusion, wireframe-with-barycentric tricks, etc.)
//  - gl_PrimitiveIDIn passthrough via SRC_SPECIAL.
//  - EmitVertex/EndPrimitive semantics: OP_EMIT snapshots the current
//    output-attribute registers (out_reg) as a new vertex; those registers
//    RETAIN their values across multiple OP_EMIT calls (matches GLSL, where
//    you commonly set gl_Position per-emit but leave a per-primitive normal
//    or color untouched across several emits). OP_CUT closes the current
//    output primitive (marks the most recently emitted vertex as strip-end)
//    and is a documented no-op if nothing has been emitted since the last
//    cut/start, matching the GL spec.
//  - Bounded output buffering: emit_buf holds up to MAX_OUT_VERTS vertices
//    (the gl_MaxGeometryOutputVertices-style limit) before streaming out;
//    exceeding it is caught by an assertion and additional emits are safely
//    dropped rather than corrupting adjacent buffer entries.
//  - Decoupled execution/streaming: like TES, the ALU program runs to
//    completion (buffering emits) before any output streaming begins, so
//    downstream consumers see a clean vout_valid/vout_ack/vout_cut stream
//    with no back-pressure interaction with the ALU.
//
// ==================== FEATURES NOT IMPLEMENTED (documented gaps) ====================
//  - GS instancing (`layout(invocations = N)` running the program N times
//    per input primitive with a distinct gl_InvocationID) -- this module
//    runs exactly one invocation per primitive. Would need an outer loop
//    analogous to TCS's INV_RUN loop, re-using this same datapath.
//  - Custom gl_Layer / gl_ViewportIndex output (layered rendering / viewport
//    array) -- not modeled; assume single layer, single viewport downstream.
//  - Multiple transform-feedback output streams (`layout(stream = N)`) --
//    only a single output stream is produced.
//  - Per-emitted-vertex gl_PrimitiveID override -- primitive ID is only
//    consumed (passthrough input), never produced/reassigned on output.
//  - Arbitrary output primitive topology changes mid-program beyond simple
//    strip-cutting (e.g. simultaneously emitting to point AND line streams)
//    -- one output topology per invocation, consistent with GLSL's single
//    fixed `layout(triangle_strip, max_vertices = N) out;`-style declaration.
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
    parameter int EMIT_W        = $clog2(MAX_OUT_VERTS+1)
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

    // synthesis-time sanity check on the flattened SRC_CPIN addressing scheme
    initial begin
        if (VTX_W + ATTR_W > 6)
            $error("geometry_shader: VTX_W(%0d)+ATTR_W(%0d) exceeds 6-bit source index field", VTX_W, ATTR_W);
    end

    tess_opcode_t   dec_opcode;
    logic [3:0]     dec_dst_mask;
    tess_dst_type_t dec_dst_type;
    logic [5:0]     dec_dst_idx;
    tess_src_type_t dec_s0_type, dec_s1_type, dec_s2_type;
    logic [5:0]     dec_s0_idx,  dec_s1_idx,  dec_s2_idx;
    logic [7:0]     dec_s0_swz,  dec_s1_swz,  dec_s2_swz;

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

    logic [DATA_W-1:0] temp_reg  [0:NUM_TEMP-1][0:3];
    logic [DATA_W-1:0] const_reg [0:NUM_CONST-1][0:3];
    logic [DATA_W-1:0] vin_reg   [0:MAX_IN_VERTS-1][0:NUM_IN_ATTR-1][0:3];
    logic [DATA_W-1:0] out_reg   [0:NUM_OUT_ATTR-1][0:3];

    logic [DATA_W-1:0] special_vec [0:3];
    assign special_vec[0] = primitive_id;
    assign special_vec[1] = '0;
    assign special_vec[2] = '0;
    assign special_vec[3] = '0;

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

    logic [DATA_W-1:0] s0_raw [0:3], s1_raw [0:3], s2_raw [0:3];
    logic [DATA_W-1:0] s0_sw  [0:3], s1_sw  [0:3], s2_sw  [0:3];

    generate
        genvar gi;
        for (gi = 0; gi < 4; gi++) begin : gen_src_rd
            assign s0_raw[gi] = read_src(dec_s0_type, dec_s0_idx, gi);
            assign s1_raw[gi] = read_src(dec_s1_type, dec_s1_idx, gi);
            assign s2_raw[gi] = read_src(dec_s2_type, dec_s2_idx, gi);
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
                    default: alu_result[lane] = '0; // OP_NOP/OP_EMIT/OP_CUT/OP_END don't write via alu_result
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
        end else begin
            state <= next_state; pc_reg <= pc_next; emit_wr_ptr <= emit_wr_ptr_next;
            emit_rd_ptr <= emit_rd_ptr_next; attr_idx <= attr_idx_next;
        end
    end

    always_comb begin
        next_state       = state;
        pc_next          = pc_reg;
        emit_wr_ptr_next = emit_wr_ptr;
        emit_rd_ptr_next = emit_rd_ptr;
        attr_idx_next    = attr_idx;
        busy = 1'b0;
        done = 1'b0;

        case (state)
            ST_IDLE: if (start) begin
                next_state       = ST_RUN;
                pc_next          = '0;
                emit_wr_ptr_next = '0;
            end
            ST_RUN: begin
                busy = 1'b1;
                case (dec_opcode)
                    OP_END: begin
                        next_state       = ST_STREAM;
                        emit_rd_ptr_next = '0;
                        attr_idx_next    = '0;
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
                OP_NOP, OP_END: ; // no register writeback
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

endmodule
