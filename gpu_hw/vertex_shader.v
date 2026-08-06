`timescale 1ns / 1ps

module vertex_shader #(
    parameter int DATA_W       = 32,
    parameter int FRAC_BITS    = 16,
    parameter int PC_W         = 8,
    parameter int NUM_TEMP     = 12,
    parameter int NUM_CONST    = 16,
    parameter int NUM_INPUT    = 16,
    parameter int NUM_OUTPUT   = 12,
    parameter int INST_W       = 96,
    parameter int MAX_GS_VERTS = 8      // strip depth for GS mode
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              start,
    input  logic              mode_gs,      // 0 = VS (1 input vertex), 1 = GS (3 input vertices -> strip out)
    output logic              busy,
    output logic              done,
    output logic [PC_W-1:0]   pc,
    input  logic [INST_W-1:0] inst_rdata,

    // vertex attribute load. vin_vtx selects which of the up-to-3 input vertex
    // slots this load targets (VS mode: caller ties vin_vtx = 0)
    input  logic              vin_valid,
    input  logic [1:0]        vin_vtx,
    input  logic [3:0]        vin_reg,
    input  logic [3:0]        vin_mask,
    input  logic [DATA_W-1:0] vin_data [0:3],

    input  logic              cin_valid,
    input  logic [3:0]        cin_reg,
    input  logic [3:0]        cin_mask,
    input  logic [DATA_W-1:0] cin_data [0:3],

    // output stream: for VS this is 1 implicit vertex; for GS this walks the
    // emitted strip in order (vout_vtx_idx increments each OP_EMIT boundary)
    output logic                            vout_valid,
    output logic [3:0]                      vout_reg,
    output logic [$clog2(MAX_GS_VERTS)-1:0] vout_vtx_idx,
    output logic                            vout_last,
    output logic [DATA_W-1:0]               vout_data [0:3],
    input  logic                            vout_ack,

    // valid once `done` is high in GS mode: number of vertices in the strip
    output logic [$clog2(MAX_GS_VERTS+1)-1:0] gs_vertex_count
);

    localparam int NUM_GS_IN_VERTS = 3;

    typedef enum logic [7:0] {
        OP_NOP  = 8'h00, OP_ADD  = 8'h01, OP_SUB  = 8'h02, OP_MUL  = 8'h03,
        OP_MAD  = 8'h04, OP_DP3  = 8'h05, OP_DP4  = 8'h06, OP_MOV  = 8'h07,
        OP_MIN  = 8'h08, OP_MAX  = 8'h09, OP_SGE  = 8'h0A, OP_SLT  = 8'h0B,
        OP_RCP  = 8'h0C, OP_RSQ  = 8'h0D, OP_FRC  = 8'h0E, OP_M4X4 = 8'h0F,
        OP_EMIT = 8'h10,
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
    // widened: up to 3 input vertex slots (VS mode only ever uses slot 0)
    logic [DATA_W-1:0] input_reg  [0:NUM_GS_IN_VERTS-1][0:NUM_INPUT-1][0:3];
    logic [DATA_W-1:0] output_reg [0:NUM_OUTPUT-1][0:3];

    logic [3:0]        wr_mask;
    logic [DATA_W-1:0] wr_data [0:3];
    logic [5:0]        wr_idx;
    reg_type_t         wr_type;
    logic              wr_en;

    logic [DATA_W-1:0] rd_data_s0 [0:3];
    logic [DATA_W-1:0] rd_data_s1 [0:3];
    logic [DATA_W-1:0] rd_data_s2 [0:3];

    // REG_INPUT addressing: idx[5:4] = vertex slot (0..2), idx[3:0] = reg #
    function automatic logic [DATA_W-1:0] read_reg(
        reg_type_t rtype, logic [5:0] idx, int comp
    );
        case (rtype)
            REG_TEMP:   return temp_reg[idx][comp];
            REG_INPUT:  return input_reg[idx[5:4]][idx[3:0]][comp];
            REG_CONST:  return const_reg[idx][comp];
            REG_OUTPUT: return output_reg[idx][comp];
            default:    return '0;
        endcase
    endfunction

    // bounds check for whichever register type/index a source operand names
    function automatic logic idx_in_range(reg_type_t rtype, logic [5:0] idx);
        case (rtype)
            REG_TEMP:   return idx < NUM_TEMP;
            REG_CONST:  return idx < NUM_CONST;
            REG_OUTPUT: return idx < NUM_OUTPUT;
            REG_INPUT:  return idx[5:4] < NUM_GS_IN_VERTS;
            default:    return 1'b0;
        endcase
    endfunction

    logic s0_in_range, s1_in_range, s2_in_range;
    assign s0_in_range = idx_in_range(dec_s0_type, dec_s0_idx);
    assign s1_in_range = idx_in_range(dec_s1_type, dec_s1_idx);
    assign s2_in_range = idx_in_range(dec_s2_type, dec_s2_idx);

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
            for (int v = 0; v < NUM_GS_IN_VERTS; v++)
                for (int i = 0; i < NUM_INPUT; i++)
                    for (int j = 0; j < 4; j++) input_reg[v][i][j] <= '0;
            for (int i = 0; i < NUM_CONST; i++)
                for (int j = 0; j < 4; j++) const_reg[i][j] <= '0;
        end else begin
            if (vin_valid) begin
                for (int c = 0; c < 4; c++)
                    if (vin_mask[c]) input_reg[vin_vtx][vin_reg][c] <= vin_data[c];
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

    // ST_STALL removed: single-instruction-at-a-time core has no RAW window,
    // so the old raw_hazard signal (which fed back into wr_en, its own input)
    // was a genuine combinational loop, not a real hazard guard.
    typedef enum logic [2:0] {
        ST_IDLE, ST_RUN, ST_RCP, ST_RSQ, ST_M4X4, ST_DONE
    } state_t;

    state_t state, next_state;
    logic [PC_W-1:0] pc_reg, pc_next;
    logic [2:0]      mc_cnt;
    logic [DATA_W-1:0] mc_accum [0:3];

    assign pc = pc_reg;

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
                case (dec_opcode)
                    OP_END:  next_state = ST_DONE;
                    OP_RCP:  next_state = ST_RCP;
                    OP_RSQ:  next_state = ST_RSQ;
                    OP_M4X4: next_state = ST_M4X4;
                    default: pc_next = pc_reg + 1'b1; // covers ALU ops, OP_NOP, OP_EMIT
                endcase
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

    // FIX: DP3 must only sum lanes 0-2 (xyz); it was summing all 4 lanes
    // identically to DP4, silently pulling w into the dot product.
    always_comb begin
        if (dec_opcode == OP_DP3) begin
            dp_sum = ($signed(dp_prod[0]) >>> FRAC_BITS) +
                     ($signed(dp_prod[1]) >>> FRAC_BITS) +
                     ($signed(dp_prod[2]) >>> FRAC_BITS);
        end else begin
            dp_sum = ($signed(dp_prod[0]) >>> FRAC_BITS) +
                     ($signed(dp_prod[1]) >>> FRAC_BITS) +
                     ($signed(dp_prod[2]) >>> FRAC_BITS) +
                     ($signed(dp_prod[3]) >>> FRAC_BITS);
        end
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
    logic [DATA_W-1:0] y_reg;
    logic [DATA_W-1:0] y_seed;

    assign y_seed = (~sfu_x + 1'b1);

    always_comb begin
        sfu_x = s0_swizzled[0];
        sfu_y = (mc_cnt == 0) ? y_seed : y_reg;
    end

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

        if (state == ST_RUN && dec_opcode != OP_NOP && dec_opcode != OP_END && dec_opcode != OP_EMIT) begin
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

    // ---------------- GS strip-emit FIFO ----------------
    logic [DATA_W-1:0] emit_fifo [0:MAX_GS_VERTS-1][0:NUM_OUTPUT-1][0:3];
    logic [$clog2(MAX_GS_VERTS+1)-1:0] emit_wr_ptr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emit_wr_ptr <= '0;
        end else if (state == ST_IDLE && start) begin
            emit_wr_ptr <= '0; // new invocation, clear the strip
        end else if (state == ST_RUN && dec_opcode == OP_EMIT) begin
            emit_fifo[emit_wr_ptr] <= output_reg;
            if (emit_wr_ptr < MAX_GS_VERTS - 1)
                emit_wr_ptr <= emit_wr_ptr + 1'b1;
        end
    end

    assign gs_vertex_count = emit_wr_ptr;

    // ---------------- output drain ----------------
    logic [3:0]                            out_reg_cnt; // register within current vertex
    logic [$clog2(MAX_GS_VERTS)-1:0]       out_vtx_cnt; // which strip vertex (GS mode only)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_reg_cnt  <= '0;
            out_vtx_cnt  <= '0;
            vout_valid   <= 1'b0;
            vout_last    <= 1'b0;
            vout_vtx_idx <= '0;
        end else if (state == ST_DONE) begin
            if (mode_gs) begin
                if (out_vtx_cnt < emit_wr_ptr) begin
                    vout_valid   <= 1'b1;
                    vout_reg     <= out_reg_cnt;
                    vout_vtx_idx <= out_vtx_cnt;
                    vout_data    <= emit_fifo[out_vtx_cnt][out_reg_cnt];
                    vout_last    <= (out_vtx_cnt == emit_wr_ptr - 1'b1) && (out_reg_cnt == NUM_OUTPUT - 1);
                    if (vout_ack) begin
                        if (out_reg_cnt == NUM_OUTPUT - 1) begin
                            out_reg_cnt <= '0;
                            out_vtx_cnt <= out_vtx_cnt + 1'b1;
                        end else begin
                            out_reg_cnt <= out_reg_cnt + 1'b1;
                        end
                    end
                end else begin
                    vout_valid <= 1'b0;
                end
            end else begin
                if (out_reg_cnt < NUM_OUTPUT) begin
                    vout_valid   <= 1'b1;
                    vout_reg     <= out_reg_cnt;
                    vout_vtx_idx <= '0;
                    vout_data    <= output_reg[out_reg_cnt];
                    vout_last    <= (out_reg_cnt == NUM_OUTPUT - 1);
                    if (vout_ack) out_reg_cnt <= out_reg_cnt + 1'b1;
                end else begin
                    vout_valid <= 1'b0;
                end
            end
        end else begin
            vout_valid   <= 1'b0;
            vout_last    <= 1'b0;
            out_reg_cnt  <= '0;
            out_vtx_cnt  <= '0;
        end
    end

    assert property (@(posedge clk) disable iff (!rst_n) pc_reg < (1<<PC_W));
    assert property (@(posedge clk) disable iff (!rst_n) !(vin_valid && cin_valid));

    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RCP) |-> ##[1:4] state != ST_RCP);
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN) |-> s_eventually (dec_opcode == OP_END));

    assert property (@(posedge clk) disable iff (!rst_n)
        (wr_en && wr_type == REG_TEMP)   |-> (wr_idx < NUM_TEMP));
    assert property (@(posedge clk) disable iff (!rst_n)
        (wr_en && wr_type == REG_OUTPUT) |-> (wr_idx < NUM_OUTPUT));
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_M4X4) |-> ((dec_s1_idx + mc_cnt) < NUM_CONST));

    // NEW: read-side bounds checks for all three source operands
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN) |-> s0_in_range);
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN) |-> s1_in_range);
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN) |-> s2_in_range);

    // NEW: emit FIFO must not overflow the strip depth
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && dec_opcode == OP_EMIT) |-> (emit_wr_ptr < MAX_GS_VERTS));

endmodule
