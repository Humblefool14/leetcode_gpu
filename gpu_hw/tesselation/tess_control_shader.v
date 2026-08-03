`timescale 1ns / 1ps
import tess_common_pkg::*;

// Tessellation Control Shader (TCS).
//
// GL semantics being modeled: TCS runs once per OUTPUT control point
// (gl_InvocationID = 0..num_out_cp-1), all invocations can read any input
// control point (gl_in[]) and write only their own output control point
// (gl_out[gl_InvocationID]), then an implicit barrier separates that from a
// single patch-constant pass that computes gl_TessLevelOuter/Inner (which may
// read any gl_out[] value, since all invocations have completed by then).
//
// Hardware model: rather than truly parallel invocations, this module runs
// the per-invocation program NUM_OUT_CP times sequentially in an INV_RUN
// loop (one program execution per cycle-group), writing each result into
// cp_out_reg[inv_idx]. Because it's sequential, the barrier is free: by the
// time PATCH_RUN starts, every cp_out_reg[] entry the patch-constant program
// might read is already valid. This trades invocation parallelism for a much
// simpler, single-ALU-datapath implementation.
module tess_control_shader #(
    parameter int PC_W       = 8,
    parameter int NUM_IN_CP  = 32,   // input patch size (<=63, see CPIN_SELF_IDX note)
    parameter int NUM_OUT_CP = 32,   // output patch size (<=63)
    parameter int NUM_TEMP   = 8,
    parameter int NUM_CONST  = 16,
    parameter int INST_W     = 96,
    parameter int INV_W      = $clog2(NUM_OUT_CP)
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 start,
    input  logic [INV_W:0]       num_out_cp,     // actual out-CP count this patch, <= NUM_OUT_CP
    output logic                 busy,
    output logic                 done,

    // per-invocation program fetch (decoupled instruction memory, like vertex_shader.sv)
    output logic [PC_W-1:0]      pc_inv,
    input  logic [INST_W-1:0]    inst_inv_rdata,

    // patch-constant program fetch
    output logic [PC_W-1:0]      pc_patch,
    input  logic [INST_W-1:0]    inst_patch_rdata,

    // patch input control points (this patch's post-vertex-shader CPs)
    input  logic                 cp_in_valid,
    input  logic [5:0]           cp_in_idx,
    input  logic [3:0]           cp_in_mask,
    input  logic [DATA_W-1:0]    cp_in_data [0:3],

    // uniform constants
    input  logic                 const_valid,
    input  logic [3:0]           const_idx,
    input  logic [3:0]           const_mask,
    input  logic [DATA_W-1:0]    const_data [0:3],

    // results, held stable from `done` until the next `start`
    output logic [DATA_W-1:0]    cp_out_reg [0:NUM_OUT_CP-1][0:3],
    output logic [DATA_W-1:0]    tess_level_outer [0:3],
    output logic [DATA_W-1:0]    tess_level_inner [0:1]
);

    // ---- decode (shared shape for both program streams; only one is fetched
    // at a time based on `state`, muxed into inst_rdata below) ----
    logic [INST_W-1:0] inst_rdata;

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

    // ---- storage ----
    logic [DATA_W-1:0] temp_reg  [0:NUM_TEMP-1][0:3];
    logic [DATA_W-1:0] const_reg [0:NUM_CONST-1][0:3];
    logic [DATA_W-1:0] cp_in_reg [0:NUM_IN_CP-1][0:3];

    typedef enum logic [1:0] { ST_IDLE, ST_INV_RUN, ST_PATCH_RUN, ST_DONE } state_t;
    state_t          state, next_state;
    logic [PC_W-1:0] pc_inv_reg, pc_inv_next;
    logic [PC_W-1:0] pc_patch_reg, pc_patch_next;
    logic [INV_W:0]  inv_idx, inv_idx_next;

    assign pc_inv   = pc_inv_reg;
    assign pc_patch = pc_patch_reg;
    assign inst_rdata = (state == ST_PATCH_RUN) ? inst_patch_rdata : inst_inv_rdata;

    // ---- input loads ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_IN_CP; i++)
                for (int j = 0; j < 4; j++) cp_in_reg[i][j] <= '0;
            for (int i = 0; i < NUM_CONST; i++)
                for (int j = 0; j < 4; j++) const_reg[i][j] <= '0;
        end else begin
            if (cp_in_valid)
                for (int c = 0; c < 4; c++)
                    if (cp_in_mask[c]) cp_in_reg[cp_in_idx][c] <= cp_in_data[c];
            if (const_valid)
                for (int c = 0; c < 4; c++)
                    if (const_mask[c]) const_reg[const_idx][c] <= const_data[c];
        end
    end

    // ---- source read + swizzle ----
    function automatic logic [DATA_W-1:0] read_src(
        tess_src_type_t stype, logic [5:0] idx, logic [INV_W:0] cur_inv, int comp
    );
        logic [5:0] eff_idx;
        begin
            eff_idx = (idx == CPIN_SELF_IDX) ? cur_inv[5:0] : idx;
            case (stype)
                SRC_TEMP:  return temp_reg[eff_idx[$clog2(NUM_TEMP)-1:0]][comp];
                SRC_CPIN:  return cp_in_reg[eff_idx][comp];
                SRC_CONST: return const_reg[eff_idx[$clog2(NUM_CONST)-1:0]][comp];
                default:   return '0; // SRC_SPECIAL unused in TCS
            endcase
        end
    endfunction

    logic [DATA_W-1:0] s0_raw [0:3], s1_raw [0:3], s2_raw [0:3];
    logic [DATA_W-1:0] s0_sw  [0:3], s1_sw  [0:3], s2_sw  [0:3];

    generate
        genvar gi;
        for (gi = 0; gi < 4; gi++) begin : gen_src_rd
            assign s0_raw[gi] = read_src(dec_s0_type, dec_s0_idx, inv_idx, gi);
            assign s1_raw[gi] = read_src(dec_s1_type, dec_s1_idx, inv_idx, gi);
            assign s2_raw[gi] = read_src(dec_s2_type, dec_s2_idx, inv_idx, gi);
            assign s0_sw[gi]  = apply_swizzle(s0_raw, dec_s0_swz, gi);
            assign s1_sw[gi]  = apply_swizzle(s1_raw, dec_s1_swz, gi);
            assign s2_sw[gi]  = apply_swizzle(s2_raw, dec_s2_swz, gi);
        end
    endgenerate

    // ---- ALU (single cycle, no SFU states -- see package header comment) ----
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
                    default: alu_result[lane] = '0; // OP_NOP / OP_END
                endcase
            end
        end
    endgenerate

    // ---- FSM ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            pc_inv_reg   <= '0;
            pc_patch_reg <= '0;
            inv_idx      <= '0;
        end else begin
            state        <= next_state;
            pc_inv_reg   <= pc_inv_next;
            pc_patch_reg <= pc_patch_next;
            inv_idx      <= inv_idx_next;
        end
    end

    always_comb begin
        next_state    = state;
        pc_inv_next   = pc_inv_reg;
        pc_patch_next = pc_patch_reg;
        inv_idx_next  = inv_idx;
        busy = 1'b0;
        done = 1'b0;

        case (state)
            ST_IDLE: begin
                if (start) begin
                    next_state   = ST_INV_RUN;
                    pc_inv_next  = '0;
                    inv_idx_next = '0;
                end
            end
            ST_INV_RUN: begin
                busy = 1'b1;
                if (dec_opcode == OP_END) begin
                    if (inv_idx + 1 >= num_out_cp) begin
                        next_state    = ST_PATCH_RUN;
                        pc_patch_next = '0;
                    end else begin
                        inv_idx_next = inv_idx + 1'b1;
                        pc_inv_next  = '0;
                    end
                end else begin
                    pc_inv_next = pc_inv_reg + 1'b1;
                end
            end
            ST_PATCH_RUN: begin
                busy = 1'b1;
                if (dec_opcode == OP_END)
                    next_state = ST_DONE;
                else
                    pc_patch_next = pc_patch_reg + 1'b1;
            end
            ST_DONE: begin
                done = 1'b1;
                if (!start) next_state = ST_IDLE;
            end
        endcase
    end

    // ---- writeback ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_TEMP; i++)
                for (int j = 0; j < 4; j++) temp_reg[i][j] <= '0;
            for (int i = 0; i < NUM_OUT_CP; i++)
                for (int j = 0; j < 4; j++) cp_out_reg[i][j] <= '0;
            for (int j = 0; j < 4; j++) tess_level_outer[j] <= '0;
            for (int j = 0; j < 2; j++) tess_level_inner[j] <= '0;
        end else if ((state == ST_INV_RUN || state == ST_PATCH_RUN) &&
                     dec_opcode != OP_NOP && dec_opcode != OP_END) begin
            case (dec_dst_type)
                DST_TEMP: begin
                    for (int c = 0; c < 4; c++)
                        if (dec_dst_mask[c]) temp_reg[dec_dst_idx[$clog2(NUM_TEMP)-1:0]][c] <= alu_result[c];
                end
                DST_CPOUT: begin
                    // implicit destination index = current invocation; illegal/ignored in ST_PATCH_RUN
                    if (state == ST_INV_RUN)
                        for (int c = 0; c < 4; c++)
                            if (dec_dst_mask[c]) cp_out_reg[inv_idx][c] <= alu_result[c];
                end
                DST_TESS_OUTER: begin
                    if (state == ST_PATCH_RUN && dec_dst_mask[0])
                        tess_level_outer[dec_dst_idx[1:0]] <= alu_result[0];
                end
                DST_TESS_INNER: begin
                    if (state == ST_PATCH_RUN && dec_dst_mask[0])
                        tess_level_inner[dec_dst_idx[0]] <= alu_result[0];
                end
            endcase
        end
    end

    assert property (@(posedge clk) disable iff (!rst_n) num_out_cp <= NUM_OUT_CP);
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_INV_RUN) |-> ##[1:256] state != ST_INV_RUN);

endmodule
