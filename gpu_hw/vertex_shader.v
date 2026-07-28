`timescale 1ns / 1ps

// ============================================================================
// Vertex Shader Core (VS 1.1-style)
// ============================================================================
// - 4-component vector SIMD (x,y,z,w)
// - Fixed-point arithmetic (default 16.16, parameterized)
// - Single-issue, in-order 2-stage pipeline with RAW stall interlock
// - Multi-cycle RCP/RSQ via Newton-Raphson iteration
// ============================================================================

module vertex_shader #(
    parameter int DATA_W       = 32,    // Bits per vector component
    parameter int FRAC_BITS    = 16,    // Fixed-point fraction width
    parameter int PC_W         = 8,     // Program counter width
    parameter int NUM_TEMP     = 12,    // r0-r11
    parameter int NUM_CONST    = 16,    // c0-c15
    parameter int NUM_INPUT    = 16,    // v0-v15
    parameter int NUM_OUTPUT   = 12,    // o0-o11 (oPos=o0, oD0=o1, oT0=o5...)
    parameter int INST_W       = 96     // Instruction width
)(
    input  logic              clk,
    input  logic              rst_n,

    // ------------------------------------------------------------------------
    // Control
    // ------------------------------------------------------------------------
    input  logic              start,        // Pulse to begin execution
    output logic              busy,
    output logic              done,         // Pulses when a vertex finishes

    // ------------------------------------------------------------------------
    // Instruction Memory (external ROM/RAM)
    // ------------------------------------------------------------------------
    output logic [PC_W-1:0]   pc,
    input  logic [INST_W-1:0] inst_rdata,   // Instruction at PC

    // ------------------------------------------------------------------------
    // Vertex Input Load (host fills v-regs before start)
    // ------------------------------------------------------------------------
    input  logic              vin_valid,
    input  logic [3:0]        vin_reg,      // 0-15
    input  logic [3:0]        vin_mask,     // {w,z,y,x}
    input  logic [DATA_W-1:0] vin_data [0:3],

    // ------------------------------------------------------------------------
    // Constant Load (host fills c-regs before start)
    // ------------------------------------------------------------------------
    input  logic              cin_valid,
    input  logic [3:0]        cin_reg,
    input  logic [3:0]        cin_mask,
    input  logic [DATA_W-1:0] cin_data [0:3],

    // ------------------------------------------------------------------------
    // Output Read (pops completed vertex output registers)
    // ------------------------------------------------------------------------
    output logic              vout_valid,
    output logic [3:0]        vout_reg,     // Which output register is valid
    output logic [DATA_W-1:0] vout_data [0:3],
    input  logic              vout_ack
);

    // =====================================================================
    // Typedefs & Constants
    // =====================================================================

    typedef enum logic [7:0] {
        OP_NOP  = 8'h00,
        OP_ADD  = 8'h01,
        OP_SUB  = 8'h02,
        OP_MUL  = 8'h03,
        OP_MAD  = 8'h04,
        OP_DP3  = 8'h05,
        OP_DP4  = 8'h06,
        OP_MOV  = 8'h07,
        OP_MIN  = 8'h08,
        OP_MAX  = 8'h09,
        OP_SGE  = 8'h0A,
        OP_SLT  = 8'h0B,
        OP_RCP  = 8'h0C,
        OP_RSQ  = 8'h0D,
        OP_FRC  = 8'h0E,
        OP_M4X4 = 8'h0F,  // 4-cycle matrix*vector
        OP_END  = 8'hFF
    } opcode_t;

    typedef enum logic [1:0] {
        REG_TEMP   = 2'b00,
        REG_INPUT  = 2'b01,
        REG_CONST  = 2'b10,
        REG_OUTPUT = 2'b11
    } reg_type_t;

    localparam logic [DATA_W-1:0] ONE_FP = (1 << FRAC_BITS);  // 1.0 in fixed-point
    localparam logic [DATA_W-1:0] ZERO_FP = '0;

    // =====================================================================
    // Instruction Decoding
    // =====================================================================
    // 96-bit instruction format:
    // [95:88] opcode
    // [87:84] dest_mask  {w,z,y,x}
    // [83:82] dest_type
    // [81:76] dest_idx
    // [75:74] src0_type
    // [73:68] src0_idx
    // [67:60] src0_swizzle (8 bits: 2 per component)
    // [59:58] src1_type
    // [57:52] src1_idx
    // [51:44] src1_swizzle
    // [43:42] src2_type
    // [41:36] src2_idx
    // [35:28] src2_swizzle
    // [27:0]  reserved

    opcode_t                  dec_opcode;
    logic [3:0]               dec_mask;
    reg_type_t                dec_dst_type;
    logic [5:0]               dec_dst_idx;
    reg_type_t                dec_s0_type, dec_s1_type, dec_s2_type;
    logic [5:0]               dec_s0_idx,  dec_s1_idx,  dec_s2_idx;
    logic [7:0]               dec_s0_swz,  dec_s1_swz,  dec_s2_swz;

    assign dec_opcode   = opcode_t'(inst_rdata[95:88]);
    assign dec_mask     = inst_rdata[87:84];
    assign dec_dst_type = reg_type_t'(inst_rdata[83:82]);
    assign dec_dst_idx  = inst_rdata[81:76];
    assign dec_s0_type  = reg_type_t'(inst_rdata[75:74]);
    assign dec_s0_idx   = inst_rdata[73:68];
    assign dec_s0_swz   = inst_rdata[67:60];
    assign dec_s1_type  = reg_type_t'(inst_rdata[59:58]);
    assign dec_s1_idx   = inst_rdata[57:52];
    assign dec_s1_swz   = inst_rdata[51:44];
    assign dec_s2_type  = reg_type_t'(inst_rdata[43:42]);
    assign dec_s2_idx   = inst_rdata[41:36];
    assign dec_s2_swz   = inst_rdata[35:28];

    // =====================================================================
    // Register Files
    // =====================================================================

    // 4 components x DATA_W bits
    logic [DATA_W-1:0] temp_reg   [0:NUM_TEMP-1][0:3];
    logic [DATA_W-1:0] const_reg  [0:NUM_CONST-1][0:3];
    logic [DATA_W-1:0] input_reg  [0:NUM_INPUT-1][0:3];
    logic [DATA_W-1:0] output_reg [0:NUM_OUTPUT-1][0:3];

    // Write-enable per component
    logic [3:0]        wr_mask;
    logic [DATA_W-1:0] wr_data [0:3];
    logic [5:0]        wr_idx;
    reg_type_t         wr_type;
    logic              wr_en;

    // ---------------------------------------------------------------------
    // Async Read (3 ports for MAD)
    // ---------------------------------------------------------------------
    logic [DATA_W-1:0] rd_data_s0 [0:3];
    logic [DATA_W-1:0] rd_data_s1 [0:3];
    logic [DATA_W-1:0] rd_data_s2 [0:3];

    function automatic logic [DATA_W-1:0] read_reg(
        reg_type_t rtype,
        logic [5:0] idx,
        int comp
    );
        case (rtype)
            REG_TEMP:   return temp_reg[idx][comp];
            REG_INPUT:  return input_reg[idx][comp];
            REG_CONST:  return const_reg[idx][comp];
            REG_OUTPUT: return output_reg[idx][comp];
            default:    return '0;
        endcase
    endfunction

    generate
        genvar g;
        for (g = 0; g < 4; g++) begin : gen_reg_rd
            assign rd_data_s0[g] = read_reg(dec_s0_type, dec_s0_idx, g);
            assign rd_data_s1[g] = read_reg(dec_s1_type, dec_s1_idx, g);
            assign rd_data_s2[g] = read_reg(dec_s2_type, dec_s2_idx, g);
        end
    endgenerate

    // ---------------------------------------------------------------------
    // Synchronous Write
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_TEMP; i++)
                for (int j = 0; j < 4; j++) temp_reg[i][j] <= '0;
            for (int i = 0; i < NUM_OUTPUT; i++)
                for (int j = 0; j < 4; j++) output_reg[i][j] <= '0;
        end else begin
            if (wr_en) begin
                for (int c = 0; c < 4; c++) begin
                    if (wr_mask[c]) begin
                        case (wr_type)
                            REG_TEMP:   temp_reg[wr_idx][c]   <= wr_data[c];
                            REG_OUTPUT: output_reg[wr_idx][c] <= wr_data[c];
                            default: ; // read-only or const
                        endcase
                    end
                end
            end
        end
    end

    // Input/Const load from host (takes priority over ALU writeback)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_INPUT; i++)
                for (int j = 0; j < 4; j++) input_reg[i][j] <= '0;
            for (int i = 0; i < NUM_CONST; i++)
                for (int j = 0; j < 4; j++) const_reg[i][j] <= '0;
        end else begin
            if (vin_valid) begin
                for (int c = 0; c < 4; c++)
                    if (vin_mask[c]) input_reg[vin_reg][c] <= vin_data[c];
            end
            if (cin_valid) begin
                for (int c = 0; c < 4; c++)
                    if (cin_mask[c]) const_reg[cin_reg][c] <= cin_data[c];
            end
        end
    end

    // =====================================================================
    // Swizzle Logic
    // =====================================================================
    // swizzle bits: [7:6]=w, [5:4]=z, [3:2]=y, [1:0]=x
    // 00=x, 01=y, 10=z, 11=w

    function automatic logic [DATA_W-1:0] apply_swizzle(
        logic [DATA_W-1:0] vec [0:3],
        logic [7:0] swz,
        int lane
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

    logic [DATA_W-1:0] s0_swizzled [0:3];
    logic [DATA_W-1:0] s1_swizzled [0:3];
    logic [DATA_W-1:0] s2_swizzled [0:3];

    generate
        genvar s;
        for (s = 0; s < 4; s++) begin : gen_swizzle
            assign s0_swizzled[s] = apply_swizzle(rd_data_s0, dec_s0_swz, s);
            assign s1_swizzled[s] = apply_swizzle(rd_data_s1, dec_s1_swz, s);
            assign s2_swizzled[s] = apply_swizzle(rd_data_s2, dec_s2_swz, s);
        end
    endgenerate

    // =====================================================================
    // Control & PC
    // =====================================================================

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_RUN,
        ST_STALL,       // RAW hazard stall
        ST_RCP,         // Multi-cycle reciprocal
        ST_RSQ,         // Multi-cycle reciprocal sqrt
        ST_M4X4,        // Multi-cycle matrix multiply
        ST_DONE
    } state_t;

    state_t state, next_state;
    logic [PC_W-1:0] pc_reg, pc_next;
    logic [2:0]      mc_cnt;      // Multi-cycle counter
    logic [DATA_W-1:0] mc_accum [0:3]; // Accumulator for multi-cycle ops

    assign pc = pc_reg;

    // RAW hazard detection: if decode reads a temp/output that execute is writing
    logic raw_hazard;
    assign raw_hazard = (state == ST_RUN) &&
                        (dec_s0_type == wr_type && dec_s0_idx == wr_idx && wr_en) ||
                        (dec_s1_type == wr_type && dec_s1_idx == wr_idx && wr_en) ||
                        (dec_s2_type == wr_type && dec_s2_idx == wr_idx && wr_en);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= ST_IDLE;
            pc_reg  <= '0;
            mc_cnt  <= '0;
        end else begin
            state  <= next_state;
            pc_reg <= pc_next;
            if (state == ST_RCP || state == ST_RSQ || state == ST_M4X4)
                mc_cnt <= mc_cnt + 1'b1;
            else
                mc_cnt <= '0;
        end
    end

    always_comb begin
        next_state = state;
        pc_next    = pc_reg;
        busy       = 1'b0;
        done       = 1'b0;

        case (state)
            ST_IDLE: begin
                if (start) next_state = ST_RUN;
            end

            ST_RUN: begin
                busy = 1'b1;
                if (raw_hazard) begin
                    next_state = ST_STALL;
                end else begin
                    case (dec_opcode)
                        OP_END:  next_state = ST_DONE;
                        OP_RCP:  next_state = ST_RCP;
                        OP_RSQ:  next_state = ST_RSQ;
                        OP_M4X4: next_state = ST_M4X4;
                        default: pc_next = pc_reg + 1'b1;
                    endcase
                end
            end

            ST_STALL: begin
                busy = 1'b1;
                next_state = ST_RUN; // Resume next cycle (1-cycle bubble)
                pc_next = pc_reg;
            end

            ST_RCP: begin
                busy = 1'b1;
                if (mc_cnt == 3) begin // 4-cycle Newton-Raphson
                    next_state = ST_RUN;
                    pc_next = pc_reg + 1'b1;
                end
            end

            ST_RSQ: begin
                busy = 1'b1;
                if (mc_cnt == 3) begin
                    next_state = ST_RUN;
                    pc_next = pc_reg + 1'b1;
                end
            end

            ST_M4X4: begin
                busy = 1'b1;
                if (mc_cnt == 3) begin // 4 DP4 operations
                    next_state = ST_RUN;
                    pc_next = pc_reg + 1'b1;
                end
            end

            ST_DONE: begin
                done = 1'b1;
                if (!start) next_state = ST_IDLE; // Hold until start drops
            end
        endcase
    end

    // =====================================================================
    // SIMD ALU (4 lanes, combinational)
    // =====================================================================

    logic [DATA_W-1:0] alu_result [0:3];
    logic [DATA_W*2-1:0] mul_wide [0:3];

    // Fixed-point multiply: Q16.16 * Q16.16 -> Q32.32, then truncate to Q16.16
    function automatic logic [DATA_W-1:0] fx_mul(
        logic [DATA_W-1:0] a,
        logic [DATA_W-1:0] b
    );
        logic [DATA_W*2-1:0] p = $signed(a) * $signed(b);
        return p[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
    endfunction

    // Dot product helpers
    logic [DATA_W*2-1:0] dp_prod [0:3];
    logic [DATA_W+2:0]   dp_sum;  // Extra bits for 4-term sum
    logic [DATA_W-1:0]   dp_result;

    generate
        genvar d;
        for (d = 0; d < 4; d++) begin : gen_dp_prod
            assign dp_prod[d] = $signed(s0_swizzled[d]) * $signed(s1_swizzled[d]);
        end
    endgenerate

    always_comb begin
        dp_sum = ($signed(dp_prod[0]) >>> FRAC_BITS) +
                 ($signed(dp_prod[1]) >>> FRAC_BITS) +
                 ($signed(dp_prod[2]) >>> FRAC_BITS) +
                 ($signed(dp_prod[3]) >>> FRAC_BITS);
        dp_result = dp_sum[DATA_W-1:0];
    end

    // Per-lane ALU
    generate
        genvar lane;
        for (lane = 0; lane < 4; lane++) begin : gen_alu_lane
            always_comb begin
                alu_result[lane] = '0;
                case (dec_opcode)
                    OP_NOP:  alu_result[lane] = '0;
                    OP_ADD:  alu_result[lane] = s0_swizzled[lane] + s1_swizzled[lane];
                    OP_SUB:  alu_result[lane] = s0_swizzled[lane] - s1_swizzled[lane];
                    OP_MUL:  alu_result[lane] = fx_mul(s0_swizzled[lane], s1_swizzled[lane]);
                    OP_MAD:  alu_result[lane] = fx_mul(s0_swizzled[lane], s1_swizzled[lane])
                                                 + s2_swizzled[lane];
                    OP_MOV:  alu_result[lane] = s0_swizzled[lane];
                    OP_MIN:  alu_result[lane] = ($signed(s0_swizzled[lane]) < $signed(s1_swizzled[lane]))
                                                 ? s0_swizzled[lane] : s1_swizzled[lane];
                    OP_MAX:  alu_result[lane] = ($signed(s0_swizzled[lane]) > $signed(s1_swizzled[lane]))
                                                 ? s0_swizzled[lane] : s1_swizzled[lane];
                    OP_SGE:  alu_result[lane] = ($signed(s0_swizzled[lane]) >= $signed(s1_swizzled[lane]))
                                                 ? ONE_FP : ZERO_FP;
                    OP_SLT:  alu_result[lane] = ($signed(s0_swizzled[lane]) < $signed(s1_swizzled[lane]))
                                                 ? ONE_FP : ZERO_FP;
                    OP_FRC:  alu_result[lane] = {{(DATA_W-FRAC_BITS){1'b0}}, s0_swizzled[lane][FRAC_BITS-1:0]};
                    OP_DP3:  alu_result[lane] = dp_result;  // Replicated
                    OP_DP4:  alu_result[lane] = dp_result;  // Replicated
                    OP_M4X4: alu_result[lane] = dp_result;  // Replicated per-row
                    default: alu_result[lane] = '0;
                endcase
            end
        end
    endgenerate

    // =====================================================================
    // Special Function Unit (Newton-Raphson for RCP/RSQ)
    // =====================================================================
    // Fixed-point reciprocal: y = y*(2 - x*y), seeded from LUT or approx

    logic [DATA_W-1:0] sfu_result [0:3];
    logic [DATA_W-1:0] sfu_x, sfu_y;

    // Simple seed: for 16.16, approximate 1/x by shifting (very rough, 2 iterations)
    // In a real design, use a 256-entry LUT for the seed.
    always_comb begin
        sfu_x = s0_swizzled[0]; // Scalar operation, uses X component
        // Seed: 1 / x ≈ (3/2 - x/2) for x near 1.0, normalized elsewhere
        // For simplicity, we just do the iteration with a crude seed
        sfu_y = mc_cnt == 0 ? (~sfu_x + 1'b1) : sfu_result[0]; // placeholder seed
    end

    always_comb begin
        if (state == ST_RCP) begin
            // Newton-Raphson: y_{n+1} = y_n * (2 - x * y_n)
            logic [DATA_W*2-1:0] xy = $signed(sfu_x) * $signed(sfu_y);
            logic [DATA_W-1:0] xy_trunc = xy[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
            logic [DATA_W-1:0] two_minus = (2 * ONE_FP) - xy_trunc;
            logic [DATA_W*2-1:0] y_next = $signed(sfu_y) * $signed(two_minus);
            sfu_result[0] = y_next[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
            sfu_result[1] = sfu_result[0];
            sfu_result[2] = sfu_result[0];
            sfu_result[3] = sfu_result[0];
        end else if (state == ST_RSQ) begin
            // y_{n+1} = y_n * (3 - x*y_n^2) / 2
            logic [DATA_W*2-1:0] yy = $signed(sfu_y) * $signed(sfu_y);
            logic [DATA_W-1:0] yy_trunc = yy[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
            logic [DATA_W*2-1:0] xyy = $signed(sfu_x) * $signed(yy_trunc);
            logic [DATA_W-1:0] xyy_trunc = xyy[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
            logic [DATA_W-1:0] three_minus = (3 * ONE_FP) - xyy_trunc;
            logic [DATA_W*2-1:0] y_next = $signed(sfu_y) * $signed(three_minus);
            sfu_result[0] = y_next[FRAC_BITS + DATA_W - 1 : FRAC_BITS + 1]; // divide by 2
            sfu_result[1] = sfu_result[0];
            sfu_result[2] = sfu_result[0];
            sfu_result[3] = sfu_result[0];
        end else begin
            sfu_result = '{default:'0};
        end
    end

    // =====================================================================
    // M4X4 Multi-Cycle Logic
    // =====================================================================
    // OP_M4X4: dest = vector * 4x4 matrix
    // src0 = vector, src1 = matrix row 0 (4 const regs), writes 4 consecutive outputs
    // Simplified: treats src1 as row 0, and reads rows from next 3 const regs

    logic [DATA_W-1:0] m4x4_result [0:3];
    logic [DATA_W-1:0] m4x4_row [0:3];

    // Read matrix row based on mc_cnt from const regs starting at src1
    assign m4x4_row[0] = const_reg[dec_s1_idx + mc_cnt][0];
    assign m4x4_row[1] = const_reg[dec_s1_idx + mc_cnt][1];
    assign m4x4_row[2] = const_reg[dec_s1_idx + mc_cnt][2];
    assign m4x4_row[3] = const_reg[dec_s1_idx + mc_cnt][3];

    always_comb begin
        // DP4 between src0 vector and matrix row
        logic [DATA_W*2-1:0] p [0:3];
        logic [DATA_W+2:0] sum;
        p[0] = $signed(s0_swizzled[0]) * $signed(m4x4_row[0]);
        p[1] = $signed(s0_swizzled[1]) * $signed(m4x4_row[1]);
        p[2] = $signed(s0_swizzled[2]) * $signed(m4x4_row[2]);
        p[3] = $signed(s0_swizzled[3]) * $signed(m4x4_row[3]);
        sum  = ($signed(p[0])>>>FRAC_BITS) + ($signed(p[1])>>>FRAC_BITS) +
               ($signed(p[2])>>>FRAC_BITS) + ($signed(p[3])>>>FRAC_BITS);
        m4x4_result = '{sum[DATA_W-1:0], sum[DATA_W-1:0],
                        sum[DATA_W-1:0], sum[DATA_W-1:0]};
    end

    // =====================================================================
    // Writeback Mux
    // =====================================================================

    always_comb begin
        wr_en   = 1'b0;
        wr_type = REG_TEMP;
        wr_idx  = '0;
        wr_mask = '0;
        wr_data = '{default:'0};

        if (state == ST_RUN && !raw_hazard && dec_opcode != OP_NOP && dec_opcode != OP_END) begin
            wr_en   = 1'b1;
            wr_type = dec_dst_type;
            wr_idx  = dec_dst_idx;
            wr_mask = dec_mask;
            wr_data = alu_result;
        end else if (state == ST_RCP && mc_cnt == 3) begin
            wr_en   = 1'b1;
            wr_type = dec_dst_type;
            wr_idx  = dec_dst_idx;
            wr_mask = dec_mask;
            wr_data = sfu_result;
        end else if (state == ST_RSQ && mc_cnt == 3) begin
            wr_en   = 1'b1;
            wr_type = dec_dst_type;
            wr_idx  = dec_dst_idx;
            wr_mask = dec_mask;
            wr_data = sfu_result;
        end else if (state == ST_M4X4) begin
            wr_en   = 1'b1;
            wr_type = dec_dst_type;
            wr_idx  = dec_dst_idx + mc_cnt; // Write to consecutive outputs
            wr_mask = 4'b1111;
            wr_data = m4x4_result;
        end
    end

    // =====================================================================
    // Output Interface (streams output registers when shader ends)
    // =====================================================================

    logic [3:0] out_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_cnt    <= '0;
            vout_valid <= 1'b0;
        end else begin
            if (state == ST_DONE && out_cnt < NUM_OUTPUT) begin
                vout_valid <= 1'b1;
                vout_reg   <= out_cnt;
                vout_data  <= output_reg[out_cnt];
                if (vout_ack) out_cnt <= out_cnt + 1'b1;
            end else begin
                vout_valid <= 1'b0;
                if (state != ST_DONE) out_cnt <= '0;
            end
        end
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // PC should not overflow program memory
    assert property (@(posedge clk) disable iff (!rst_n) pc_reg < (1<<PC_W));

    // Only one of vin_valid/cin_valid should assert at a time (simplification)
    assert property (@(posedge clk) disable iff (!rst_n) !(vin_valid && cin_valid));

    // Multi-cycle ops must complete in expected cycles
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RCP) |-> ##[1:4] state != ST_RCP);

    // END instruction must eventually be reached
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN) |-> s_eventually (dec_opcode == OP_END));

endmodule
