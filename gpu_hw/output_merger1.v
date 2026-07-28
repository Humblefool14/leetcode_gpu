`timescale 1ns / 1ps

module output_merger #(
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480,
    parameter int FB_SIZE       = SCREEN_WIDTH * SCREEN_HEIGHT,
    parameter int ADDR_W        = $clog2(FB_SIZE),
    parameter int DATA_W        = 24,   // RGB888
    parameter int Z_W           = 16,
    parameter int ALPHA_W       = 8,    // NEW: alpha channel width
    parameter logic [Z_W-1:0] Z_FAR = {Z_W{1'b1}}
)(
    input  logic              clk,
    input  logic              rst_n,

    // Control
    input  logic              clear_zbuffer,
    output logic              clear_done,
    output logic              pipeline_stall,

    // NEW: Alpha test configuration
    input  logic              alpha_test_enable,
    input  logic [ALPHA_W-1:0] alpha_test_ref,
    input  logic [2:0]        alpha_test_func,  // 0=NEVER, 1=LESS, 2=EQUAL, 3=LEQUAL, 4=GREATER, 5=NOTEQUAL, 6=GEQUAL, 7=ALWAYS

    // NEW: Blend configuration
    input  logic              blend_enable,
    input  logic [2:0]        blend_src_factor,  // 0=ZERO, 1=ONE, 2=SRC_COLOR, 3=SRC_ALPHA, 4=INV_SRC_ALPHA, 5=DST_ALPHA, 6=INV_DST_ALPHA, 7=DST_COLOR
    input  logic [2:0]        blend_dst_factor,  // Same options

    // From pixel shader (now with alpha)
    input  logic              ps_valid,
    input  logic [15:0]       ps_x,
    input  logic [15:0]       ps_y,
    input  logic [DATA_W-1:0] ps_color,        // RGB
    input  logic [ALPHA_W-1:0] ps_alpha,        // NEW: separate alpha channel
    input  logic [Z_W-1:0]    ps_z,

    // To framebuffer
    output logic              fb_we,
    output logic [ADDR_W-1:0] fb_addr,
    output logic [DATA_W-1:0] fb_wdata
);

    // =====================================================================
    // Z-BUFFER MEMORY
    // =====================================================================
    (* ram_style = "block" *)
    logic [Z_W-1:0] z_buffer [0:FB_SIZE-1];

    // =====================================================================
    // FRAMEBUFFER READ PORT (for blending)
    // Need dual-port or 2-cycle read latency
    // For now: use same BRAM with registered read
    // =====================================================================
    (* ram_style = "block" *)
    logic [DATA_W-1:0] color_buffer [0:FB_SIZE-1];

    // =====================================================================
    // PIPELINE OCCUPANCY (used to gate the clear FSM so it never races
    // against an in-flight pixel retiring into the same memories)
    // =====================================================================
    logic pipeline_busy;
    assign pipeline_busy = s1_valid || s2_valid || s3_valid || s4_valid;

    // =====================================================================
    // CLEAR STATE MACHINE
    // =====================================================================
    // IDLE  : normal operation, pixels flow through the pipeline
    // DRAIN : clear requested; new pixels are blocked (pipeline_stall=1)
    //         and we wait for any in-flight pixel to finish writing
    // CLEAR : draining is complete, safe to sweep the buffers
    typedef enum logic [1:0] { IDLE, DRAIN, CLEAR } state_t;
    state_t state;
    logic [ADDR_W-1:0] clear_addr;

    assign pipeline_stall = (state != IDLE);
    assign clear_done = clear_done_reg;

    logic clear_done_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            clear_addr <= '0;
            clear_done_reg <= 1'b0;
        end else begin
            clear_done_reg <= 1'b0;

            unique case (state)
                IDLE: begin
                    if (clear_zbuffer) begin
                        clear_addr <= '0;
                        // If the pipeline still has in-flight pixels, wait
                        // for them to retire before touching the memories.
                        state <= pipeline_busy ? DRAIN : CLEAR;
                    end
                end

                DRAIN: begin
                    // pipeline_stall is already asserted (state != IDLE),
                    // so no new pixels can enter s1. Just wait for the
                    // ones already in flight to finish writing.
                    if (!pipeline_busy) begin
                        state <= CLEAR;
                    end
                end

                CLEAR: begin
                    z_buffer[clear_addr] <= Z_FAR;
                    if (clear_addr < FB_SIZE - 1) begin
                        clear_addr <= clear_addr + 1'b1;
                    end else begin
                        state <= IDLE;
                        clear_done_reg <= 1'b1;
                    end
                end
            endcase
        end
    end

    // =====================================================================
    // 5-STAGE RMW PIPELINE (extended for alpha + blend)
    // =====================================================================

    // Stage 1: Address calc + bounds check
    logic        s1_valid;
    logic [ADDR_W-1:0] s1_addr;
    logic [DATA_W-1:0] s1_color;
    logic [ALPHA_W-1:0] s1_alpha;
    logic [Z_W-1:0] s1_z;

    logic addr_in_bounds;
    assign addr_in_bounds = (ps_x < SCREEN_WIDTH) && (ps_y < SCREEN_HEIGHT);

    always_ff @(posedge clk) begin
        if (state == IDLE) begin
            s1_valid <= ps_valid && addr_in_bounds;
            if (ps_valid && addr_in_bounds) begin
                s1_addr  <= (ps_y * SCREEN_WIDTH) + ps_x;
                s1_color <= ps_color;
                s1_alpha <= ps_alpha;
                s1_z     <= ps_z;
            end
        end else begin
            s1_valid <= 1'b0;
        end
    end

    // Stage 2: Read Z + Color (for blending)
    logic        s2_valid;
    logic [ADDR_W-1:0] s2_addr;
    logic [DATA_W-1:0] s2_color;
    logic [ALPHA_W-1:0] s2_alpha;
    logic [Z_W-1:0] s2_z;
    logic [Z_W-1:0] z_old;
    logic [DATA_W-1:0] color_old;  // NEW: existing framebuffer color

    always_ff @(posedge clk) begin
        s2_valid <= s1_valid;
        if (s1_valid) begin
            s2_addr  <= s1_addr;
            s2_color <= s1_color;
            s2_alpha <= s1_alpha;
            s2_z     <= s1_z;
            z_old    <= z_buffer[s1_addr];
            color_old <= color_buffer[s1_addr];  // Read existing color
        end
    end

    // Stage 3: Alpha Test
    logic        s3_valid;
    logic [ADDR_W-1:0] s3_addr;
    logic [DATA_W-1:0] s3_color;
    logic [ALPHA_W-1:0] s3_alpha;
    logic [Z_W-1:0] s3_z;
    logic [DATA_W-1:0] s3_color_old;
    logic        s3_alpha_pass;

    // Alpha test function - pure combinational result, kept as its own
    // signal so it's never also driven by a flop (was a multi-driver bug).
    logic alpha_func_result;
    always_comb begin
        case (alpha_test_func)
            3'd0: alpha_func_result = 1'b0;                          // NEVER
            3'd1: alpha_func_result = (s2_alpha < alpha_test_ref);   // LESS
            3'd2: alpha_func_result = (s2_alpha == alpha_test_ref);  // EQUAL
            3'd3: alpha_func_result = (s2_alpha <= alpha_test_ref);  // LEQUAL
            3'd4: alpha_func_result = (s2_alpha > alpha_test_ref);   // GREATER
            3'd5: alpha_func_result = (s2_alpha != alpha_test_ref);  // NOTEQUAL
            3'd6: alpha_func_result = (s2_alpha >= alpha_test_ref);  // GEQUAL
            3'd7: alpha_func_result = 1'b1;                          // ALWAYS
            default: alpha_func_result = 1'b1;
        endcase
    end

    always_ff @(posedge clk) begin
        s3_valid <= s2_valid;
        s3_addr  <= s2_addr;
        s3_color <= s2_color;
        s3_alpha <= s2_alpha;
        s3_z     <= s2_z;
        s3_color_old <= color_old;

        if (s2_valid) begin
            s3_alpha_pass <= !alpha_test_enable || alpha_func_result;
        end else begin
            s3_alpha_pass <= 1'b0;
        end
    end

    // Stage 4: Z-Test + Blend Calculation
    logic        s4_valid;
    logic [ADDR_W-1:0] s4_addr;
    logic [DATA_W-1:0] s4_color;
    logic [Z_W-1:0] s4_z;
    logic        s4_z_pass;

    // Blend factors
    logic [7:0] src_factor_r, src_factor_g, src_factor_b;
    logic [7:0] dst_factor_r, dst_factor_g, dst_factor_b;
    logic [15:0] blend_r, blend_g, blend_b;

    // Decode blend factors
    always_comb begin
        // Source factor
        case (blend_src_factor)
            3'd0: begin src_factor_r = 8'd0;   src_factor_g = 8'd0;   src_factor_b = 8'd0;   end // ZERO
            3'd1: begin src_factor_r = 8'd255; src_factor_g = 8'd255; src_factor_b = 8'd255; end // ONE
            3'd2: begin src_factor_r = s3_color[23:16]; src_factor_g = s3_color[15:8]; src_factor_b = s3_color[7:0]; end // SRC_COLOR
            3'd3: begin src_factor_r = s3_alpha; src_factor_g = s3_alpha; src_factor_b = s3_alpha; end // SRC_ALPHA
            3'd4: begin src_factor_r = 8'd255 - s3_alpha; src_factor_g = 8'd255 - s3_alpha; src_factor_b = 8'd255 - s3_alpha; end // INV_SRC_ALPHA
            3'd5: begin src_factor_r = 8'd255; src_factor_g = 8'd255; src_factor_b = 8'd255; end // DST_ALPHA (stub - no dest alpha stored)
            3'd6: begin src_factor_r = 8'd0;   src_factor_g = 8'd0;   src_factor_b = 8'd0;   end // INV_DST_ALPHA (stub - no dest alpha stored)
            3'd7: begin src_factor_r = s3_color_old[23:16]; src_factor_g = s3_color_old[15:8]; src_factor_b = s3_color_old[7:0]; end // DST_COLOR (enables Multiply mode)
            default: begin src_factor_r = 8'd255; src_factor_g = 8'd255; src_factor_b = 8'd255; end
        endcase

        // Dest factor
        case (blend_dst_factor)
            3'd0: begin dst_factor_r = 8'd0;   dst_factor_g = 8'd0;   dst_factor_b = 8'd0;   end
            3'd1: begin dst_factor_r = 8'd255; dst_factor_g = 8'd255; dst_factor_b = 8'd255; end
            3'd2: begin dst_factor_r = s3_color_old[23:16]; dst_factor_g = s3_color_old[15:8]; dst_factor_b = s3_color_old[7:0]; end
            3'd3: begin dst_factor_r = s3_alpha; dst_factor_g = s3_alpha; dst_factor_b = s3_alpha; end
            3'd4: begin dst_factor_r = 8'd255 - s3_alpha; dst_factor_g = 8'd255 - s3_alpha; dst_factor_b = 8'd255 - s3_alpha; end
            default: begin dst_factor_r = 8'd0; dst_factor_g = 8'd0; dst_factor_b = 8'd0; end
        endcase
    end

    // Blend equation: Src * SrcFactor + Dst * DstFactor
    always_comb begin
        blend_r = (s3_color[23:16] * src_factor_r) + (s3_color_old[23:16] * dst_factor_r);
        blend_g = (s3_color[15:8]  * src_factor_g) + (s3_color_old[15:8]  * dst_factor_g);
        blend_b = (s3_color[7:0]   * src_factor_b) + (s3_color_old[7:0]   * dst_factor_b);
    end

    assign s4_z_pass = (s3_z < z_old);

    always_ff @(posedge clk) begin
        s4_valid <= s3_valid && s3_alpha_pass;
        s4_addr  <= s3_addr;
        s4_z     <= s3_z;

        if (s3_valid && s3_alpha_pass) begin
            if (blend_enable) begin
                s4_color[23:16] <= blend_r[15:8];  // >> 8
                s4_color[15:8]  <= blend_g[15:8];
                s4_color[7:0]   <= blend_b[15:8];
            end else begin
                s4_color <= s3_color;  // Replace mode
            end
        end
    end

    // Stage 5: Write to Z-Buffer + Color Buffer
    always_ff @(posedge clk) begin
        fb_we <= s4_valid && s4_z_pass;
        fb_addr <= s4_addr;

        if (s4_valid && s4_z_pass) begin
            z_buffer[s4_addr] <= s4_z;
            color_buffer[s4_addr] <= s4_color;  // Write blended color
            fb_wdata <= s4_color;
        end else begin
            fb_wdata <= '0;  // Don't care when not writing
        end
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Alpha test only drops pixels, never creates them
    property p_alpha_test_conservative;
        @(posedge clk) disable iff (!rst_n)
        s3_valid |-> s4_valid == s3_alpha_pass;
    endproperty
    a_alpha_test_conservative: assert property (p_alpha_test_conservative);

    // Blend doesn't write without valid data
    property p_blend_valid;
        @(posedge clk) disable iff (!rst_n)
        fb_we |-> $past(s4_valid, 1);
    endproperty
    a_blend_valid: assert property (p_blend_valid);

    // NEW: the clear FSM and the pixel pipeline never write z_buffer/color_buffer
    // on the same cycle (guards against the race the DRAIN state fixes)
    property p_no_clear_pipeline_write_collision;
        @(posedge clk) disable iff (!rst_n)
        (state == CLEAR) |-> !(s4_valid && s4_z_pass);
    endproperty
    a_no_clear_pipeline_write_collision: assert property (p_no_clear_pipeline_write_collision);

endmodule
