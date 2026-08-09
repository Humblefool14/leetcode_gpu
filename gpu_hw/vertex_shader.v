`timescale 1ns / 1ps
//
// CHANGELOG vs. the pasted draft (doc2):
//  1. File was truncated mid-instruction inside the integer ALU case block
//     (OP_ISHR onward). Completed OP_ISHR, OP_ISAR, OP_IAND, OP_IOR,
//     OP_IXOR, OP_INOT, OP_IMIN, OP_IMAX.
//  2. pred_wr_en combinational assign was missing from the excerpt. Wired
//     it WITHOUT gating on pred_true (same self-referencing-predicate bug
//     as the VS 1.1 SETP review: SETP's pred_sel/pred_inv fields are its
//     *destination*, not an outer guard, so gating the write on the bit
//     it's about to write creates a bit that can never toggle 0->1).
//  3. Generic writeback (wr_en) previously fired for ANY opcode not in
//     {NOP,END,EMIT,SETP}, which meant OP_BRA/OP_BRAZ/OP_BRANZ/OP_LOOP/
//     OP_ENDLP/OP_TEXLD would zero out whatever register happened to be
//     encoded in dst_idx (alu_result defaults to '0 for unlisted opcodes).
//     Excluded flow-control and TEXLD from the generic writeback path and
//     added a dedicated writeback for OP_TEXLD driven by tex_resp_data.
//  4. Loop stack push was unconditional; on LOOP_STACK_DEPTH+1 nested
//     OP_LOOPs it would silently index out of range. Guarded the push and
//     added an assertion that catches attempted overflow.
//  5. OP_LOOP repurposes s0_idx as an immediate iteration count (not a
//     register reference), and OP_TEXLD repurposes s1_idx/s2_idx as
//     sampler/texture immediates. The blanket s0/s1/s2_in_range
//     assertions would false-fire on these. Added an opcode-qualified
//     "operand is actually a register" signal and gated the range
//     assertions on it.
//
module vertex_shader #(
    parameter int DATA_W       = 32,
    parameter int FRAC_BITS    = 16,
    parameter int PC_W         = 8,
    parameter int NUM_TEMP     = 12,
    parameter int NUM_CONST    = 16,
    parameter int NUM_INPUT    = 16,
    parameter int NUM_OUTPUT   = 12,
    parameter int INST_W       = 96,
    parameter int MAX_GS_VERTS = 8,
    parameter int LOOP_STACK_DEPTH = 4
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              start,
    input  logic              mode_gs,      // 0 = VS, 1 = GS
    output logic              busy,
    output logic              done,
    output logic [PC_W-1:0]   pc,
    input  logic [INST_W-1:0] inst_rdata,

    // vertex attribute load
    input  logic              vin_valid,
    input  logic [1:0]        vin_vtx,
    input  logic [3:0]        vin_reg,
    input  logic [3:0]        vin_mask,
    input  logic [DATA_W-1:0] vin_data [0:3],

    // constant load
    input  logic              cin_valid,
    input  logic [3:0]        cin_reg,
    input  logic [3:0]        cin_mask,
    input  logic [DATA_W-1:0] cin_data [0:3],

    // output stream
    output logic                            vout_valid,
    output logic [3:0]                      vout_reg,
    output logic [$clog2(MAX_GS_VERTS)-1:0] vout_vtx_idx,
    output logic                            vout_last,
    output logic [DATA_W-1:0]               vout_data [0:3],
    input  logic                            vout_ack,

    // GS strip vertex count
    output logic [$clog2(MAX_GS_VERTS+1)-1:0] gs_vertex_count,

    // -----------------------------------------------------------------
    // TEXTURE SAMPLER INTERFACE
    // -----------------------------------------------------------------
    output logic                    tex_req_valid,
    output logic [3:0]              tex_sampler_id,
    output logic [15:0]             tex_texture_id,
    output logic [DATA_W-1:0]       tex_coord [0:3],
    input  logic                    tex_resp_valid,
    input  logic [DATA_W-1:0]       tex_resp_data [0:3]
);

    localparam int NUM_GS_IN_VERTS = 3;
    localparam int NUM_PRED        = 4;   // p0..p3

    // =====================================================================
    // INSTRUCTION ENCODING (96 bits)
    // =====================================================================
    // [95:88]  opcode
    // [87:84]  mask
    // [83:82]  dst_type
    // [81:76]  dst_idx
    // [75:74]  s0_type
    // [73:68]  s0_idx        -- NOTE: reused as immediate loop count for OP_LOOP
    // [67:60]  s0_swz
    // [59:58]  s1_type
    // [57:52]  s1_idx        -- NOTE: reused as sampler id (low 4b) for OP_TEXLD
    // [51:44]  s1_swz
    // [43:42]  s2_type
    // [41:36]  s2_idx        -- NOTE: reused as texture id for OP_TEXLD
    // [35:28]  s2_swz
    // [27:26]  pred_sel     -- predicate to test / destination for SETP
    // [25]     pred_inv     -- invert predicate sense
    // [24:22]  cmp_mode     -- compare mode for SETP
    // [21:6]   branch_imm   -- 16-bit signed PC-relative offset for branches
    // [5:0]    reserved
    // =====================================================================

    typedef enum logic [7:0] {
        OP_NOP   = 8'h00, OP_ADD   = 8'h01, OP_SUB   = 8'h02, OP_MUL   = 8'h03,
        OP_MAD   = 8'h04, OP_DP3   = 8'h05, OP_DP4   = 8'h06, OP_MOV   = 8'h07,
        OP_MIN   = 8'h08, OP_MAX   = 8'h09, OP_SGE   = 8'h0A, OP_SLT   = 8'h0B,
        OP_RCP   = 8'h0C, OP_RSQ   = 8'h0D, OP_FRC   = 8'h0E, OP_M4X4  = 8'h0F,
        OP_EMIT  = 8'h10,
        OP_SETP  = 8'h11,
        // Flow control
        OP_BRA   = 8'h18, OP_BRAZ  = 8'h19, OP_BRANZ = 8'h1A,
        OP_LOOP  = 8'h1B, OP_ENDLP = 8'h1C,
        // Texture
        OP_TEXLD = 8'h20,
        // Integer ALU
        OP_IADD  = 8'h30, OP_ISUB  = 8'h31, OP_IMUL  = 8'h32, OP_IMAD  = 8'h33,
        OP_ISHL  = 8'h34, OP_ISHR  = 8'h35, OP_ISAR  = 8'h36, OP_IAND  = 8'h37,
        OP_IOR   = 8'h38, OP_IXOR  = 8'h39, OP_INOT  = 8'h3A, OP_IMIN  = 8'h3B,
        OP_IMAX  = 8'h3C,
        OP_END   = 8'hFF
    } opcode_t;

    typedef enum logic [2:0] {
        CMP_EQ = 3'b000, CMP_NE = 3'b001, CMP_LT = 3'b010,
        CMP_LE = 3'b011, CMP_GT = 3'b100, CMP_GE = 3'b101
    } cmp_mode_t;

    typedef enum logic [1:0] {
        REG_TEMP   = 2'b00, REG_INPUT  = 2'b01, REG_CONST  = 2'b10, REG_OUTPUT = 2'b11
    } reg_type_t;

    localparam logic [DATA_W-1:0] ONE_FP  = (1 << FRAC_BITS);
    localparam logic [DATA_W-1:0] ZERO_FP = '0;

    // =====================================================================
    // Decode
    // =====================================================================
    opcode_t                  dec_opcode;
    logic [3:0]               dec_mask;
    reg_type_t                dec_dst_type;
    logic [5:0]               dec_dst_idx;
    reg_type_t                dec_s0_type, dec_s1_type, dec_s2_type;
    logic [5:0]               dec_s0_idx,  dec_s1_idx,  dec_s2_idx;
    logic [7:0]               dec_s0_swz,  dec_s1_swz,  dec_s2_swz;
    logic [1:0]               dec_pred_sel;
    logic                     dec_pred_inv;
    cmp_mode_t                dec_cmp_mode;
    logic signed [15:0]       dec_branch_imm;
    logic [PC_W-1:0]          branch_offset;

    assign dec_opcode     = opcode_t'(inst_rdata[95:88]);
    assign dec_mask       = inst_rdata[87:84];
    assign dec_dst_type   = reg_type_t'(inst_rdata[83:82]);
    assign dec_dst_idx    = inst_rdata[81:76];
    assign dec_s0_type    = reg_type_t'(inst_rdata[75:74]);
    assign dec_s0_idx     = inst_rdata[73:68];
    assign dec_s0_swz     = inst_rdata[67:60];
    assign dec_s1_type    = reg_type_t'(inst_rdata[59:58]);
    assign dec_s1_idx     = inst_rdata[57:52];
    assign dec_s1_swz     = inst_rdata[51:44];
    assign dec_s2_type    = reg_type_t'(inst_rdata[43:42]);
    assign dec_s2_idx     = inst_rdata[41:36];
    assign dec_s2_swz     = inst_rdata[35:28];
    assign dec_pred_sel   = inst_rdata[27:26];
    assign dec_pred_inv   = inst_rdata[25];
    assign dec_cmp_mode   = cmp_mode_t'(inst_rdata[24:22]);
    assign dec_branch_imm = $signed(inst_rdata[21:6]);
    assign branch_offset  = PC_W'(dec_branch_imm);

    // =====================================================================
    // Register files
    // =====================================================================
    logic [DATA_W-1:0] temp_reg   [0:NUM_TEMP-1][0:3];
    logic [DATA_W-1:0] const_reg  [0:NUM_CONST-1][0:3];
    logic [DATA_W-1:0] input_reg  [0:NUM_GS_IN_VERTS-1][0:NUM_INPUT-1][0:3];
    logic [DATA_W-1:0] output_reg [0:NUM_OUTPUT-1][0:3];
    logic [NUM_PRED-1:0] pred_reg;

    logic [3:0]        wr_mask;
    logic [DATA_W-1:0] wr_data [0:3];
    logic [5:0]        wr_idx;
    reg_type_t         wr_type;
    logic              wr_en;
    logic              pred_wr_en;

    logic [DATA_W-1:0] rd_data_s0 [0:3];
    logic [DATA_W-1:0] rd_data_s1 [0:3];
    logic [DATA_W-1:0] rd_data_s2 [0:3];

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

    // Which src operands are genuine register references for the current
    // opcode, vs. fields repurposed as immediates. Used only to qualify
    // the range-check assertions below -- read_reg/apply_swizzle still run
    // unconditionally (harmlessly) for opcodes that ignore their outputs.
    logic s0_is_reg, s1_is_reg, s2_is_reg;
    always_comb begin
        s0_is_reg = 1'b1;
        s1_is_reg = 1'b1;
        s2_is_reg = 1'b1;
        case (dec_opcode)
            OP_NOP, OP_END: begin
                s0_is_reg = 1'b0; s1_is_reg = 1'b0; s2_is_reg = 1'b0;
            end
            OP_BRA: begin
                s0_is_reg = 1'b0; s1_is_reg = 1'b0; s2_is_reg = 1'b0;
            end
            OP_BRAZ, OP_BRANZ: begin
                // Condition comes from pred_reg[dec_pred_sel], not a src reg.
                s0_is_reg = 1'b0; s1_is_reg = 1'b0; s2_is_reg = 1'b0;
            end
            OP_LOOP: begin
                // s0_idx is an immediate iteration count, not a register.
                s0_is_reg = 1'b0; s1_is_reg = 1'b0; s2_is_reg = 1'b0;
            end
            OP_ENDLP: begin
                s0_is_reg = 1'b0; s1_is_reg = 1'b0; s2_is_reg = 1'b0;
            end
            OP_TEXLD: begin
                // s0 is the real texture-coordinate register; s1/s2 idx
                // fields are sampler-id / texture-id immediates.
                s1_is_reg = 1'b0; s2_is_reg = 1'b0;
            end
            OP_INOT: begin
                // Unary integer op: only s0 is read.
                s1_is_reg = 1'b0; s2_is_reg = 1'b0;
            end
            default: ; // ALU ops: leave all three qualified as registers
        endcase
    end

    generate
        genvar g;
        for (g = 0; g < 4; g++) begin : gen_reg_rd
            assign rd_data_s0[g] = read_reg(dec_s0_type, dec_s0_idx, g);
            assign rd_data_s1[g] = read_reg(dec_s1_type, dec_s1_idx, g);
            assign rd_data_s2[g] = read_reg(dec_s2_type, dec_s2_idx, g);
        end
    endgenerate

    // =====================================================================
    // Register writeback (temp / output)
    // =====================================================================
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

    // =====================================================================
    // Predicate register file
    //
    // pred_wr_en is intentionally NOT gated on pred_true: for OP_SETP the
    // pred_sel/pred_inv fields name the *destination* predicate bit, not an
    // outer execution guard. Gating the write on the current value of the
    // bit being written creates a bit that can never transition (see the
    // VS 1.1 predication review).
    // =====================================================================
    logic setp_result;

    always_comb begin
        pred_wr_en = 1'b0;
        if (state == ST_RUN && dec_opcode == OP_SETP) begin
            pred_wr_en = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pred_reg <= '0;
        end else if (pred_wr_en) begin
            pred_reg[dec_pred_sel] <= setp_result;
        end
    end

    // =====================================================================
    // Loop stack
    // =====================================================================
    logic [PC_W-1:0] loop_pc_stack [0:LOOP_STACK_DEPTH-1];
    logic [5:0]      loop_cnt_stack[0:LOOP_STACK_DEPTH-1];
    logic [$clog2(LOOP_STACK_DEPTH):0] loop_sp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_sp <= '0;
            for (int i = 0; i < LOOP_STACK_DEPTH; i++) begin
                loop_pc_stack[i]  <= '0;
                loop_cnt_stack[i] <= '0;
            end
        end else if (state == ST_RUN && pred_true) begin
            if (dec_opcode == OP_LOOP) begin
                // Guard against overflow: a LOOP nested deeper than
                // LOOP_STACK_DEPTH is dropped rather than corrupting the
                // stack; the assertion below flags this to the verifier.
                if (loop_sp < LOOP_STACK_DEPTH) begin
                    loop_pc_stack[loop_sp]  <= pc_reg + 1'b1;
                    loop_cnt_stack[loop_sp] <= dec_s0_idx[5:0];
                    loop_sp <= loop_sp + 1'b1;
                end
            end else if (dec_opcode == OP_ENDLP) begin
                if (loop_sp > 0) begin
                    if (loop_cnt_stack[loop_sp-1] > 1)
                        loop_cnt_stack[loop_sp-1] <= loop_cnt_stack[loop_sp-1] - 1'b1;
                    else
                        loop_sp <= loop_sp - 1'b1;
                end
            end
        end
    end

    // =====================================================================
    // Swizzle
    // =====================================================================
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

    // =====================================================================
    // Predicate test
    // =====================================================================
    logic pred_true;
    assign pred_true = pred_reg[dec_pred_sel] ^ dec_pred_inv;

    // =====================================================================
    // State machine
    // =====================================================================
    typedef enum logic [3:0] {
        ST_IDLE, ST_RUN, ST_RCP, ST_RSQ, ST_M4X4, ST_TEX_WAIT, ST_DONE
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

    // Texture request registers (hold across ST_TEX_WAIT)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tex_req_valid  <= 1'b0;
            tex_sampler_id <= '0;
            tex_texture_id <= '0;
            for (int i = 0; i < 4; i++) tex_coord[i] <= '0;
        end else if (state == ST_RUN && pred_true && dec_opcode == OP_TEXLD) begin
            tex_req_valid  <= 1'b1;
            tex_sampler_id <= dec_s1_idx[3:0];
            tex_texture_id <= {10'b0, dec_s2_idx[5:0]}; // 16-bit texture id
            tex_coord      <= s0_swizzled;
        end else if (state == ST_TEX_WAIT && tex_resp_valid) begin
            tex_req_valid  <= 1'b0;
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
                if (pred_true) begin
                    case (dec_opcode)
                        OP_END:   next_state = ST_DONE;

                        OP_RCP:   next_state = ST_RCP;
                        OP_RSQ:   next_state = ST_RSQ;
                        OP_M4X4:  next_state = ST_M4X4;
                        OP_TEXLD: next_state = ST_TEX_WAIT;

                        OP_BRA:   pc_next = pc_reg + branch_offset;
                        OP_BRAZ:  pc_next = !pred_reg[dec_pred_sel] ? (pc_reg + branch_offset) : (pc_reg + 1'b1);
                        OP_BRANZ: pc_next =  pred_reg[dec_pred_sel] ? (pc_reg + branch_offset) : (pc_reg + 1'b1);

                        OP_LOOP:  pc_next = pc_reg + 1'b1; // stack push in always_ff
                        OP_ENDLP: begin
                            if (loop_sp > 0 && loop_cnt_stack[loop_sp-1] > 1)
                                pc_next = loop_pc_stack[loop_sp-1];
                            else
                                pc_next = pc_reg + 1'b1;
                        end

                        default:  pc_next = pc_reg + 1'b1;
                    endcase
                end else begin
                    // Predicated false: skip
                    pc_next = pc_reg + 1'b1;
                end
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

            ST_TEX_WAIT: begin
                busy = 1'b1;
                if (tex_resp_valid) begin
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

    // =====================================================================
    // ALU datapath
    // =====================================================================
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

    // SETP comparison
    always_comb begin
        case (dec_cmp_mode)
            CMP_EQ:  setp_result = ($signed(s0_swizzled[0]) == $signed(s1_swizzled[0]));
            CMP_NE:  setp_result = ($signed(s0_swizzled[0]) != $signed(s1_swizzled[0]));
            CMP_LT:  setp_result = ($signed(s0_swizzled[0]) <  $signed(s1_swizzled[0]));
            CMP_LE:  setp_result = ($signed(s0_swizzled[0]) <= $signed(s1_swizzled[0]));
            CMP_GT:  setp_result = ($signed(s0_swizzled[0]) >  $signed(s1_swizzled[0]));
            CMP_GE:  setp_result = ($signed(s0_swizzled[0]) >= $signed(s1_swizzled[0]));
            default: setp_result = 1'b0;
        endcase
    end

    generate
        genvar lane;
        for (lane = 0; lane < 4; lane++) begin : gen_alu_lane
            always_comb begin
                alu_result[lane] = '0;
                case (dec_opcode)
                    // Scalar / existing fixed-point
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
                    OP_SETP: alu_result[lane] = '0;

                    // Integer ALU
                    OP_IADD: alu_result[lane] = $signed(s0_swizzled[lane]) + $signed(s1_swizzled[lane]);
                    OP_ISUB: alu_result[lane] = $signed(s0_swizzled[lane]) - $signed(s1_swizzled[lane]);
                    OP_IMUL: begin
                        logic [DATA_W*2-1:0] ip;
                        ip = $signed(s0_swizzled[lane]) * $signed(s1_swizzled[lane]);
                        alu_result[lane] = ip[DATA_W-1:0];
                    end
                    OP_IMAD: begin
                        logic [DATA_W*2-1:0] ip;
                        ip = $signed(s0_swizzled[lane]) * $signed(s1_swizzled[lane]);
                        alu_result[lane] = ip[DATA_W-1:0] + $signed(s2_swizzled[lane]);
                    end
                    OP_ISHL: alu_result[lane] = s0_swizzled[lane] << s1_swizzled[lane][4:0];
                    OP_ISHR: alu_result[lane] = s0_swizzled[lane] >> s1_swizzled[lane][4:0];
                    OP_ISAR: alu_result[lane] = $signed(s0_swizzled[lane]) >>> s1_swizzled[lane][4:0];
                    OP_IAND: alu_result[lane] = s0_swizzled[lane] & s1_swizzled[lane];
                    OP_IOR:  alu_result[lane] = s0_swizzled[lane] | s1_swizzled[lane];
                    OP_IXOR: alu_result[lane] = s0_swizzled[lane] ^ s1_swizzled[lane];
                    OP_INOT: alu_result[lane] = ~s0_swizzled[lane];
                    OP_IMIN: alu_result[lane] = ($signed(s0_swizzled[lane]) < $signed(s1_swizzled[lane])) ? s0_swizzled[lane] : s1_swizzled[lane];
                    OP_IMAX: alu_result[lane] = ($signed(s0_swizzled[lane]) > $signed(s1_swizzled[lane])) ? s0_swizzled[lane] : s1_swizzled[lane];

                    default: alu_result[lane] = '0; // BRA/BRAZ/BRANZ/LOOP/ENDLP/TEXLD/END: no ALU result
                endcase
            end
        end
    endgenerate

    // =====================================================================
    // SFU (RCP / RSQ)
    // =====================================================================
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

    // =====================================================================
    // M4X4
    // =====================================================================
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

    // =====================================================================
    // Writeback control
    //
    // Generic ALU writeback excludes every opcode that doesn't produce a
    // meaningful alu_result: NOP/END/EMIT/SETP (as before) plus the new
    // flow-control ops (BRA/BRAZ/BRANZ/LOOP/ENDLP) and TEXLD, which has
    // its own dedicated writeback path below driven by tex_resp_data.
    // =====================================================================
    always_comb begin
        wr_en   = 1'b0;
        wr_type = REG_TEMP;
        wr_idx  = '0;
        wr_mask = '0;
        wr_data = '{ZERO_FP, ZERO_FP, ZERO_FP, ZERO_FP};

        if (state == ST_RUN && pred_true &&
            dec_opcode != OP_NOP   && dec_opcode != OP_END  &&
            dec_opcode != OP_EMIT  && dec_opcode != OP_SETP &&
            dec_opcode != OP_BRA   && dec_opcode != OP_BRAZ &&
            dec_opcode != OP_BRANZ && dec_opcode != OP_LOOP &&
            dec_opcode != OP_ENDLP && dec_opcode != OP_TEXLD) begin
            wr_en   = 1'b1;
            wr_type = dec_dst_type;
            wr_idx  = dec_dst_idx;
            wr_mask = dec_mask;
            wr_data = alu_result;
        end else if ((state == ST_RCP || state == ST_RSQ) && mc_cnt == 3) begin
            // Note: we only entered these states if pred_true was high
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
        end else if (state == ST_TEX_WAIT && tex_resp_valid) begin
            // Note: we only entered ST_TEX_WAIT if pred_true was high, so
            // no extra pred_true check needed here (mirrors RCP/RSQ/M4X4).
            wr_en   = 1'b1;
            wr_type = dec_dst_type;
            wr_idx  = dec_dst_idx;
            wr_mask = dec_mask;
            wr_data = tex_resp_data;
        end
    end

    // =====================================================================
    // GS strip-emit FIFO
    // =====================================================================
    logic [DATA_W-1:0] emit_fifo [0:MAX_GS_VERTS-1][0:NUM_OUTPUT-1][0:3];
    logic [$clog2(MAX_GS_VERTS+1)-1:0] emit_wr_ptr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emit_wr_ptr <= '0;
        end else if (state == ST_IDLE && start) begin
            emit_wr_ptr <= '0;
        end else if (state == ST_RUN && pred_true && dec_opcode == OP_EMIT) begin
            emit_fifo[emit_wr_ptr] <= output_reg;
            if (emit_wr_ptr < MAX_GS_VERTS - 1)
                emit_wr_ptr <= emit_wr_ptr + 1'b1;
        end
    end

    assign gs_vertex_count = emit_wr_ptr;

    // =====================================================================
    // Output drain
    // =====================================================================
    logic [3:0]                            out_reg_cnt;
    logic [$clog2(MAX_GS_VERTS)-1:0]       out_vtx_cnt;

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

    // =====================================================================
    // Assertions
    // =====================================================================
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

    // Source-range checks, qualified so opcodes that repurpose an idx
    // field as an immediate (LOOP count, TEXLD sampler/texture id) don't
    // false-fire.
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && s0_is_reg) |-> s0_in_range);
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && s1_is_reg) |-> s1_in_range);
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && s2_is_reg) |-> s2_in_range);

    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && dec_opcode == OP_EMIT) |-> (emit_wr_ptr < MAX_GS_VERTS));

    // Predication / SETP
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && dec_opcode == OP_SETP) |-> (dec_cmp_mode <= 3'b101));

    // Loop stack: flag attempted overflow (push dropped, not corrupted)
    // and underflow (ENDLP with no matching LOOP is a no-op, not an error,
    // so this only checks the stack pointer never exceeds its bound).
    assert property (@(posedge clk) disable iff (!rst_n)
        loop_sp <= LOOP_STACK_DEPTH);
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_RUN && pred_true && dec_opcode == OP_LOOP) |->
            (loop_sp < LOOP_STACK_DEPTH));

    // Texture handshake: request stays asserted until the response arrives,
    // and a new request is never issued while one is outstanding.
    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_TEX_WAIT) |-> tex_req_valid);
    assert property (@(posedge clk) disable iff (!rst_n)
        tex_req_valid |-> ##[1:$] tex_resp_valid);

endmodule
