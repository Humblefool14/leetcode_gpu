`timescale 1ns / 1ps
import tess_common_pkg::*;

// Tessellation Evaluation Shader (TES).
//
// Runs the program once per domain point streamed in from the fixed-function
// tessellator, reading this patch's TCS-output control points (cp_in_reg,
// loaded once per patch, static per-instruction indices -- same convention
// as vertex_shader.sv's const_reg) plus the domain coordinate for this
// invocation (SRC_SPECIAL: lane0=u, lane1=v, lane2=w, lane3=0), and produces
// one final output vertex (position/color/normal/texcoord-style attributes,
// same shape as vertex_shader.sv's output side).
//
// Non-pipelined: one domain point is fully evaluated (all instructions to
// OP_END) before the next is accepted. Good enough to prove out correctness;
// if throughput matters, this is the natural place to add a 2-stage pipeline
// (decode/ALU overlap) later, mirroring how vertex_shader.sv is itself
// single-issue.
module tess_eval_shader #(
    parameter int PC_W      = 8,
    parameter int NUM_CP    = 32,   // TCS output control points for this patch
    parameter int NUM_TEMP  = 8,
    parameter int NUM_CONST = 16,
    parameter int NUM_OUT_ATTR = 12, // output vertex attribute slots (position/color/normal/texcoord/...)
    parameter int INST_W    = 96
)(
    input  logic               clk,
    input  logic               rst_n,

    output logic [PC_W-1:0]    pc,
    input  logic [INST_W-1:0]  inst_rdata,

    // patch control points (from TCS.cp_out_reg), loaded once per patch
    input  logic                cp_valid,
    input  logic [5:0]          cp_idx,
    input  logic [3:0]          cp_mask,
    input  logic [DATA_W-1:0]   cp_data [0:3],

    input  logic                const_valid,
    input  logic [3:0]          const_idx,
    input  logic [3:0]          const_mask,
    input  logic [DATA_W-1:0]   const_data [0:3],

    // one domain point per invocation (from tess_fixed_function)
    input  logic                domain_valid,
    output logic                domain_ready,
    input  logic [DATA_W-1:0]   domain_u,
    input  logic [DATA_W-1:0]   domain_v,
    input  logic [DATA_W-1:0]   domain_w,

    // resulting vertex, one attribute register at a time (like vertex_shader.sv's vout_*)
    output logic                vout_valid,
    output logic [3:0]          vout_reg,
    output logic [DATA_W-1:0]   vout_data [0:3],
    input  logic                vout_ack
);

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

    logic [DATA_W-1:0] temp_reg   [0:NUM_TEMP-1][0:3];
    logic [DATA_W-1:0] const_reg  [0:NUM_CONST-1][0:3];
    logic [DATA_W-1:0] cp_reg     [0:NUM_CP-1][0:3];
    logic [DATA_W-1:0] out_reg    [0:NUM_OUT_ATTR-1][0:3];

    logic [DATA_W-1:0] domain_vec [0:3];
    assign domain_vec[0] = domain_u;
    assign domain_vec[1] = domain_v;
    assign domain_vec[2] = domain_w;
    assign domain_vec[3] = '0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_CP; i++)    for (int j = 0; j < 4; j++) cp_reg[i][j]    <= '0;
            for (int i = 0; i < NUM_CONST; i++) for (int j = 0; j < 4; j++) const_reg[i][j] <= '0;
        end else begin
            if (cp_valid)
                for (int c = 0; c < 4; c++) if (cp_mask[c]) cp_reg[cp_idx][c] <= cp_data[c];
            if (const_valid)
                for (int c = 0; c < 4; c++) if (const_mask[c]) const_reg[const_idx][c] <= const_data[c];
        end
    end

    function automatic logic [DATA_W-1:0] read_src(
        tess_src_type_t stype, logic [5:0] idx, int comp
    );
        case (stype)
            SRC_TEMP:    return temp_reg[idx[$clog2(NUM_TEMP)-1:0]][comp];
            SRC_CPIN:    return cp_reg[idx][comp];
            SRC_CONST:   return const_reg[idx[$clog2(NUM_CONST)-1:0]][comp];
            SRC_SPECIAL: return domain_vec[comp]; // idx ignored: single domain-coord register
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
                    default: alu_result[lane] = '0;
                endcase
            end
        end
    endgenerate

    typedef enum logic [1:0] { ST_IDLE, ST_RUN, ST_EMIT, ST_WAIT_ACK } state_t;
    state_t          state, next_state;
    logic [PC_W-1:0] pc_reg, pc_next;
    logic [3:0]      emit_idx, emit_idx_next;

    assign pc = pc_reg;
    assign domain_ready = (state == ST_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; pc_reg <= '0; emit_idx <= '0;
        end else begin
            state <= next_state; pc_reg <= pc_next; emit_idx <= emit_idx_next;
        end
    end

    always_comb begin
        next_state     = state;
        pc_next        = pc_reg;
        emit_idx_next  = emit_idx;
        case (state)
            ST_IDLE: if (domain_valid) begin
                next_state = ST_RUN;
                pc_next    = '0;
            end
            ST_RUN: begin
                if (dec_opcode == OP_END) begin
                    next_state    = ST_EMIT;
                    emit_idx_next = '0;
                end else begin
                    pc_next = pc_reg + 1'b1;
                end
            end
            ST_EMIT: begin
                next_state = ST_WAIT_ACK;
            end
            ST_WAIT_ACK: if (vout_ack) begin
                if (emit_idx + 1 >= NUM_OUT_ATTR) begin
                    next_state = ST_IDLE;
                end else begin
                    emit_idx_next = emit_idx + 1'b1;
                    next_state    = ST_EMIT;
                end
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_TEMP; i++)    for (int j = 0; j < 4; j++) temp_reg[i][j] <= '0;
            for (int i = 0; i < NUM_OUT_ATTR; i++) for (int j = 0; j < 4; j++) out_reg[i][j]  <= '0;
        end else if (state == ST_RUN && dec_opcode != OP_NOP && dec_opcode != OP_END) begin
            case (dec_dst_type)
                DST_TEMP: for (int c = 0; c < 4; c++)
                              if (dec_dst_mask[c]) temp_reg[dec_dst_idx[$clog2(NUM_TEMP)-1:0]][c] <= alu_result[c];
                DST_CPOUT: for (int c = 0; c < 4; c++)
                              if (dec_dst_mask[c]) out_reg[dec_dst_idx[$clog2(NUM_OUT_ATTR)-1:0]][c] <= alu_result[c];
                default: ; // DST_TESS_OUTER/INNER not meaningful in TES, ignored
            endcase
        end
    end

    assign vout_valid = (state == ST_EMIT) || (state == ST_WAIT_ACK);
    assign vout_reg    = emit_idx;
    assign vout_data   = out_reg[emit_idx];

    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN) |-> ##[1:256] state != ST_RUN);

endmodule
