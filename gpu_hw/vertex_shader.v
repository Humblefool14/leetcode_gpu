`timescale 1ns / 1ps

module vertex_shader #(
    parameter int DATA_W       = 32,
    parameter int FRAC_BITS    = 16,
    parameter int PC_W         = 8,
    parameter int NUM_TEMP     = 12,
    parameter int NUM_CONST    = 16,
    parameter int NUM_INPUT    = 16,
    parameter int NUM_OUTPUT   = 12,
    parameter int INST_W       = 96
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              start,
    output logic              busy,
    output logic              done,
    output logic [PC_W-1:0]   pc,
    input  logic [INST_W-1:0] inst_rdata,
    input  logic              vin_valid,
    input  logic [3:0]        vin_reg,
    input  logic [3:0]        vin_mask,
    input  logic [DATA_W-1:0] vin_data [0:3],
    input  logic              cin_valid,
    input  logic [3:0]        cin_reg,
    input  logic [3:0]        cin_mask,
    input  logic [DATA_W-1:0] cin_data [0:3],
    output logic              vout_valid,
    output logic [3:0]        vout_reg,
    output logic [DATA_W-1:0] vout_data [0:3],
    input  logic              vout_ack
);

    typedef enum logic [7:0] {
        OP_NOP  = 8'h00, OP_ADD  = 8'h01, OP_SUB  = 8'h02, OP_MUL  = 8'h03,
        OP_MAD  = 8'h04, OP_DP3  = 8'h05, OP_DP4  = 8'h06, OP_MOV  = 8'h07,
        OP_MIN  = 8'h08, OP_MAX  = 8'h09, OP_SGE  = 8'h0A, OP_SLT  = 8'h0B,
        OP_RCP  = 8'h0C, OP_RSQ  = 8'h0D, OP_FRC  = 8'h0E, OP_M4X4 = 8'h0F,
        OP_END  = 8'hFF
    } opcode_t;

    typedef enum logic [1:0] {
        REG_TEMP   = 2'b00, REG_INPUT  = 2'b01, REG_CONST  = 2'b10, REG_OUTPUT = 2'b11
    } reg_type_t;

    localparam logic [DATA_W-1:0] ONE_FP = (1 << FRAC_BITS);
    localparam logic [DATA_W-1:0] ZERO_FP = '0;

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

    logic [DATA_W-1:0] temp_reg   [0:NUM_TEMP-1][0:3];
    logic [DATA_W-1:0] const_reg  [0:NUM_CONST-1][0:3];
    logic [DATA_W-1:0] input_reg  [0:NUM_INPUT-1][0:3];
    logic [DATA_W-1:0] output_reg [0:NUM_OUTPUT-1][0:3];

    logic [3:0]        wr_mask;
    logic [DATA_W-1:0] wr_data [0:3];
    logic [5:0]        wr_idx;
    reg_type_t         wr_type;
    logic              wr_en;

    logic [DATA_W-1:0] rd_data_s0 [0:3];
    logic [DATA_W-1:0] rd_data_s1 [0:3];
    logic [DATA_W-1:0] rd_data_s2 [0:3];

    function automatic logic [DATA_W-1:0] read_reg(
        reg_type_t rtype, logic [5:0] idx, int comp
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
                            default: ;
                        endcase
                    end
                end
            end
        end
    end

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

    typedef enum logic [2:0] {
        ST_IDLE, ST_RUN, ST_STALL, ST_RCP, ST_RSQ, ST_M4X4, ST_DONE
    } state_t;

    state_t state, next_state;
    logic [PC_W-1:0] pc_reg, pc_next;
    logic [2:0]      mc_cnt;
    logic [DATA_W-1:0] mc_accum [0:3];

    assign pc = pc_reg;

    logic raw_hazard;
    // FIX: parens were missing, so && bound tighter than ||: only the first term
    // was actually gated by (state == ST_RUN); the other two could assert regardless.
    assign raw_hazard = (state == ST_RUN) &&
                        ((dec_s0_type == wr_type && dec_s0_idx == wr_idx && wr_en) ||
                         (dec_s1_type == wr_type && dec_s1_idx == wr_idx && wr_en) ||
                         (dec_s2_type == wr_type && dec_s2_idx == wr_idx && wr_en));

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
                next_state = ST_RUN;
                pc_next = pc_reg;
            end
            ST_RCP: begin
                busy = 1'b1;
                if (mc_cnt == 3) begin
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
                if (mc_cnt == 3) begin
                    next_state = ST_RUN;
                    pc_next = pc_reg + 1'b1;
                end
            end
            ST_DONE: begin
                done = 1'b1;
                if (!start) next_state = ST_IDLE;
            end
        endcase
    end

    logic [DATA_W-1:0] alu_result [0:3];
    logic [DATA_W*2-1:0] mul_wide [0:3];

    function automatic logic [DATA_W-1:0] fx_mul(
        logic [DATA_W-1:0] a, logic [DATA_W-1:0] b
    );
        logic [DATA_W*2-1:0] p;
        p = $signed(a) * $signed(b);
        return p[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
    endfunction

    logic [DATA_W*2-1:0] dp_prod [0:3];
    logic [DATA_W+2:0]   dp_sum;
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
                    OP_MAD:  alu_result[lane] = fx_mul(s0_swizzled[lane], s1_swizzled[lane]) + s2_swizzled[lane];
                    OP_MOV:  alu_result[lane] = s0_swizzled[lane];
                    OP_MIN:  alu_result[lane] = ($signed(s0_swizzled[lane]) < $signed(s1_swizzled[lane])) ? s0_swizzled[lane] : s1_swizzled[lane];
                    OP_MAX:  alu_result[lane] = ($signed(s0_swizzled[lane]) > $signed(s1_swizzled[lane])) ? s0_swizzled[lane] : s1_swizzled[lane];
                    OP_SGE:  alu_result[lane] = ($signed(s0_swizzled[lane]) >= $signed(s1_swizzled[lane])) ? ONE_FP : ZERO_FP;
                    OP_SLT:  alu_result[lane] = ($signed(s0_swizzled[lane]) < $signed(s1_swizzled[lane])) ? ONE_FP : ZERO_FP;
                    OP_FRC:  alu_result[lane] = {{(DATA_W-FRAC_BITS){1'b0}}, s0_swizzled[lane][FRAC_BITS-1:0]};
                    OP_DP3:  alu_result[lane] = dp_result;
                    OP_DP4:  alu_result[lane] = dp_result;
                    OP_M4X4: alu_result[lane] = dp_result;
                    default: alu_result[lane] = '0;
                endcase
            end
        end
    endgenerate

    logic [DATA_W-1:0] sfu_result [0:3];
    logic [DATA_W-1:0] sfu_x, sfu_y;
    logic [DATA_W-1:0] y_reg;    // FIX: flopped iterate, was missing -> combinational loop
    logic [DATA_W-1:0] y_seed;

    // Crude seed: -x as a starting guess (placeholder; a real design should use a LUT)
    assign y_seed = (~sfu_x + 1'b1);

    always_comb begin
        sfu_x = s0_swizzled[0];
        sfu_y = (mc_cnt == 0) ? y_seed : y_reg;
    end

    // FIX: register the Newton-Raphson iterate every cycle we're in ST_RCP/ST_RSQ.
    // Without this flop, sfu_y and sfu_result formed a zero-delay combinational
    // loop and the "4-cycle iteration" never actually advanced.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_reg <= '0;
        end else if (state == ST_RCP || state == ST_RSQ) begin
            y_reg <= sfu_result[0];
        end
    end

    always_comb begin
        if (state == ST_RCP) begin
            logic [DATA_W*2-1:0] xy;
            logic [DATA_W-1:0] xy_trunc;
            logic [DATA_W-1:0] two_minus;
            logic [DATA_W*2-1:0] y_next;
            xy = $signed(sfu_x) * $signed(sfu_y);
            xy_trunc = xy[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
            two_minus = (2 * ONE_FP) - xy_trunc;
            y_next = $signed(sfu_y) * $signed(two_minus);
            sfu_result[0] = y_next[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
            sfu_result[1] = sfu_result[0];
            sfu_result[2] = sfu_result[0];
            sfu_result[3] = sfu_result[0];
        end else if (state == ST_RSQ) begin
            logic [DATA_W*2-1:0] yy;
            logic [DATA_W-1:0] yy_trunc;
            logic [DATA_W*2-1:0] xyy;
            logic [DATA_W-1:0] xyy_trunc;
            logic [DATA_W-1:0] three_minus;
            logic [DATA_W*2-1:0] y_next;
            yy = $signed(sfu_y) * $signed(sfu_y);
            yy_trunc = yy[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
            xyy = $signed(sfu_x) * $signed(yy_trunc);
            xyy_trunc = xyy[FRAC_BITS + DATA_W - 1 : FRAC_BITS];
            three_minus = (3 * ONE_FP) - xyy_trunc;
            y_next = $signed(sfu_y) * $signed(three_minus);
            sfu_result[0] = y_next[FRAC_BITS + DATA_W - 1 : FRAC_BITS + 1];
            sfu_result[1] = sfu_result[0];
            sfu_result[2] = sfu_result[0];
            sfu_result[3] = sfu_result[0];
        end else begin
            sfu_result = '{ZERO_FP, ZERO_FP, ZERO_FP, ZERO_FP};
        end
    end

    // FIX: M4X4 now produces ONE scalar dot-product per cycle (vector . row[mc_cnt]),
    // which gets accumulated into mc_accum[mc_cnt] and assembled into a single
    // 4-component destination register on the last cycle, instead of writing the
    // same replicated scalar into 4 separate destination registers.
    logic [DATA_W-1:0] m4x4_dot;
    logic [DATA_W-1:0] m4x4_row [0:3];

    assign m4x4_row[0] = const_reg[dec_s1_idx + mc_cnt][0];
    assign m4x4_row[1] = const_reg[dec_s1_idx + mc_cnt][1];
    assign m4x4_row[2] = const_reg[dec_s1_idx + mc_cnt][2];
    assign m4x4_row[3] = const_reg[dec_s1_idx + mc_cnt][3];

    always_comb begin
        logic [DATA_W*2-1:0] p [0:3];
        logic [DATA_W+2:0] sum;
        p[0] = $signed(s0_swizzled[0]) * $signed(m4x4_row[0]);
        p[1] = $signed(s0_swizzled[1]) * $signed(m4x4_row[1]);
        p[2] = $signed(s0_swizzled[2]) * $signed(m4x4_row[2]);
        p[3] = $signed(s0_swizzled[3]) * $signed(m4x4_row[3]);
        sum  = ($signed(p[0])>>>FRAC_BITS) + ($signed(p[1])>>>FRAC_BITS) +
               ($signed(p[2])>>>FRAC_BITS) + ($signed(p[3])>>>FRAC_BITS);
        m4x4_dot = sum[DATA_W-1:0];
    end

    // FIX: mc_accum was declared but never used. It now captures each row's dot
    // product as it's computed (cycles 0-2), so the final cycle can assemble the
    // complete 4-component result.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 4; i++) mc_accum[i] <= '0;
        end else if (state == ST_M4X4) begin
            mc_accum[mc_cnt] <= m4x4_dot;
        end
    end

    always_comb begin
        wr_en   = 1'b0;
        wr_type = REG_TEMP;
        wr_idx  = '0;
        wr_mask = '0;
        wr_data = '{ZERO_FP, ZERO_FP, ZERO_FP, ZERO_FP};

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
        end else if (state == ST_M4X4 && mc_cnt == 3) begin
            // FIX: single destination register, components assembled from the
            // 3 previously-registered row dot products plus this cycle's row-3 result
            wr_en      = 1'b1;
            wr_type    = dec_dst_type;
            wr_idx     = dec_dst_idx;
            wr_mask    = 4'b1111;
            wr_data[0] = mc_accum[0];
            wr_data[1] = mc_accum[1];
            wr_data[2] = mc_accum[2];
            wr_data[3] = m4x4_dot;
        end
    end

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

    assert property (@(posedge clk) disable iff (!rst_n) pc_reg < (1<<PC_W));
    assert property (@(posedge clk) disable iff (!rst_n) !(vin_valid && cin_valid));

    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RCP) |-> ##[1:4] state != ST_RCP);
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN) |-> s_eventually (dec_opcode == OP_END));

    // NEW: dec_dst_idx/dec_s1_idx are 6-bit decode fields but the register files
    // are only NUM_TEMP/NUM_OUTPUT/NUM_CONST deep (12/12/16) -- catch any out-of-range
    // write before it silently corrupts an unrelated register.
    assert property (@(posedge clk) disable iff (!rst_n)
        (wr_en && wr_type == REG_TEMP)   |-> (wr_idx < NUM_TEMP));
    assert property (@(posedge clk) disable iff (!rst_n)
        (wr_en && wr_type == REG_OUTPUT) |-> (wr_idx < NUM_OUTPUT));
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_M4X4) |-> ((dec_s1_idx + mc_cnt) < NUM_CONST));

endmodule
