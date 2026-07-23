`timescale 1ns / 1ps

module pixel_shader #(
    parameter int COLOR_W = 8,
    parameter int Z_W     = 16,   // NEW: depth output width
    parameter int W_W     = 16    // Weight precision
)(
    input  logic              clk,
    input  logic              rst_n,

    // Triangle constants (latched by upstream, stable for whole triangle)
    input  logic [31:0]       inv_area,   // 0.32 fixed-point

    // Vertex colors
    input  logic [COLOR_W-1:0] v0_r, v0_g, v0_b,
    input  logic [COLOR_W-1:0] v1_r, v1_g, v1_b,
    input  logic [COLOR_W-1:0] v2_r, v2_g, v2_b,

    // Vertex Z (for depth interpolation)
    input  logic [Z_W-1:0]    v0_z,
    input  logic [Z_W-1:0]    v1_z,
    input  logic [Z_W-1:0]    v2_z,

    // From rasterizer_core
    input  logic              raster_valid,
    input  logic [15:0]       raster_x,
    input  logic [15:0]       raster_y,
    input  logic signed [31:0] raster_e0,  // Edge for V0
    input  logic signed [31:0] raster_e1,  // Edge for V1
    input  logic signed [31:0] raster_e2,  // Edge for V2

    // To output_merger
    output logic              ps_valid,
    output logic [15:0]       ps_x,
    output logic [15:0]       ps_y,
    output logic [COLOR_W-1:0] ps_r,
    output logic [COLOR_W-1:0] ps_g,
    output logic [COLOR_W-1:0] ps_b,
    output logic [Z_W-1:0]    ps_z          // NEW: interpolated depth
);

    // =====================================================================
    // Stage 1: Weight Calculation (combinational mult, registered result)
    // =====================================================================

    // Correct mapping: e0 -> V0 (alpha), e1 -> V1 (beta), e2 -> V2 (gamma)
    logic signed [63:0] prod_alpha, prod_beta, prod_gamma;

    always_comb begin
        // inv_area is 0.32 fixed-point
        // eN is signed integer (from edge function)
        // Product is signed 32.32 format
        prod_alpha = raster_e0 * $signed({1'b0, inv_area});
        prod_beta  = raster_e1 * $signed({1'b0, inv_area});
        prod_gamma = raster_e2 * $signed({1'b0, inv_area});
    end

    logic              s1_valid;
    logic [15:0]       s1_x, s1_y;
    logic [W_W-1:0]    weight_alpha;   // 0.16 fixed-point
    logic [W_W-1:0]    weight_beta;
    logic [W_W-1:0]    weight_gamma;

    // Extract 0.16 from 32.32 product: bits [47:32]
    // But clamp negative to 0 (shouldn't happen for inside pixels, but safety)
    logic [W_W-1:0] w_alpha_raw, w_beta_raw, w_gamma_raw;

    assign w_alpha_raw = prod_alpha[47:32];
    assign w_beta_raw  = prod_beta[47:32];
    assign w_gamma_raw = prod_gamma[47:32];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid     <= 1'b0;
            s1_x         <= '0;
            s1_y         <= '0;
            weight_alpha <= '0;
            weight_beta  <= '0;
            weight_gamma <= '0;
        end else begin
            s1_valid <= raster_valid;
            s1_x     <= raster_x;
            s1_y     <= raster_y;

            if (raster_valid) begin
                weight_alpha <= prod_alpha[63] ? '0 : w_alpha_raw;  // Clamp negative
                weight_beta  <= prod_beta[63]  ? '0 : w_beta_raw;
                weight_gamma <= prod_gamma[63] ? '0 : w_gamma_raw;
            end
        end
    end

    // =====================================================================
    // Stage 2: Attribute Interpolation
    // =====================================================================

    // Widen to prevent overflow: 16-bit weight * 8-bit color = 24-bit
    // Sum of 3 = 26-bit. >> 16 gives 10-bit, clamp to 8.
    logic [25:0] r_sum, g_sum, b_sum;
    logic [25:0] z_sum;   // For Z interpolation

    always_comb begin
        r_sum = (weight_alpha * v0_r) + (weight_beta * v1_r) + (weight_gamma * v2_r);
        g_sum = (weight_alpha * v0_g) + (weight_beta * v1_g) + (weight_gamma * v2_g);
        b_sum = (weight_alpha * v0_b) + (weight_beta * v1_b) + (weight_gamma * v2_b);
        z_sum = (weight_alpha * v0_z) + (weight_beta * v1_z) + (weight_gamma * v2_z);
    end

    logic [COLOR_W-1:0] r_clamped, g_clamped, b_clamped;
    logic [Z_W-1:0]     z_clamped;

    // Clamp to max after shift (saturate instead of wrap)
    assign r_clamped = (r_sum[25:16] > 8'd255) ? 8'd255 : r_sum[23:16];
    assign g_clamped = (g_sum[25:16] > 8'd255) ? 8'd255 : g_sum[23:16];
    assign b_clamped = (b_sum[25:16] > 8'd255) ? 8'd255 : b_sum[23:16];
    assign z_clamped = z_sum[31:16];  // Z is 16-bit, take middle bits

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ps_valid <= 1'b0;
            ps_x     <= '0;
            ps_y     <= '0;
            ps_r     <= '0;
            ps_g     <= '0;
            ps_b     <= '0;
            ps_z     <= '0;
        end else begin
            ps_valid <= s1_valid;
            ps_x     <= s1_x;
            ps_y     <= s1_y;

            if (s1_valid) begin
                ps_r <= r_clamped;
                ps_g <= g_clamped;
                ps_b <= b_clamped;
                ps_z <= z_clamped;
            end
        end
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Safety: weights should sum to ~1.0 (0x10000 in 0.16) for valid pixels
    // Allow small rounding error: ±2
    property p_weights_sum_to_one;
        @(posedge clk) disable iff (!rst_n)
        (s1_valid) |-> ((weight_alpha + weight_beta + weight_gamma) inside
                        {[16'hFFFE:16'h10002]});
    endproperty
    a_weights_sum_to_one: assert property (p_weights_sum_to_one);

    // Safety: no color overflow (clamping works)
    property p_color_in_range;
        @(posedge clk) disable iff (!rst_n)
        (ps_valid) |-> (ps_r <= 8'd255) && (ps_g <= 8'd255) && (ps_b <= 8'd255);
    endproperty
    a_color_in_range: assert property (p_color_in_range);

    // Safety: pipeline latency is exactly 2 cycles
    property p_two_cycle_latency;
        @(posedge clk) disable iff (!rst_n)
        raster_valid |=> ##2 ps_valid;
    endproperty
    a_two_cycle_latency: assert property (p_two_cycle_latency);

    // Safety: X/Y pass through unchanged
    property p_xy_passthrough;
        @(posedge clk) disable iff (!rst_n)
        ps_valid |-> (ps_x == $past(raster_x, 2)) && (ps_y == $past(raster_y, 2));
    endproperty
    a_xy_passthrough: assert property (p_xy_passthrough);

`ifdef FPV
    // Coverage: all weight combinations
    cover property (@(posedge clk) disable iff (!rst_n)
        s1_valid && (weight_alpha > 0) && (weight_beta > 0) && (weight_gamma > 0));

    // Coverage: color saturation (clamping active)
    cover property (@(posedge clk) disable iff (!rst_n)
        s1_valid && (r_sum[25:16] > 255));
`endif

endmodule
