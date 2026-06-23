`timescale 1ns / 1ps

module pixel_shader (
    input  logic         clk,
    input  logic         rst_n,
    
    // Constant inputs for the current triangle (Latched during Setup)
    // inv_area = (1.0 / Total Area) in 0.32 fixed-point format
    input  logic [31:0]  inv_area, 
    
    // Color Attributes at each vertex (8-bit per channel)
    input  logic [7:0]   v0_r, input  logic [7:0] v0_g, input  logic [7:0] v0_b,
    input  logic [7:0]   v1_r, input  logic [7:0] v1_g, input  logic [7:0] v1_b,
    input  logic [7:0]   v2_r, input  logic [7:0] v2_g, input  logic [7:0] v2_b,
    
    // Stream input from Rasterizer Core
    input  logic         raster_valid,
    input  logic [15:0]  raster_x,
    input  logic [15:0]  raster_y,
    input  logic [31:0]  raster_e0,
    input  logic [31:0]  raster_e1,
    input  logic [31:0]  raster_e2,
    
    // Stream output to Output Merger (OM)
    output logic         ps_valid,
    output logic [15:0]  ps_x,
    output logic [15:0]  ps_y,
    output logic [7:0]   ps_r,
    output logic [7:0]   ps_g,
    output logic [7:0]   ps_b
);

    // Pipeline Stage 1 Registers: Compute Barycentric Weights
    // Weights are represented in 0.16 fixed-point format after multiplication
    logic         r1_valid;
    logic [15:0]  r1_x, r1_y;
    logic [15:0]  weight_alpha; // Normalized weight for V0
    logic [15:0]  weight_beta;  // Normalized weight for V1
    logic [15:0]  weight_gamma; // Normalized weight for V2

    // Intermediate 64-bit products for fixed-point math
    logic [63:0]  prod_alpha, prod_beta, prod_gamma;

    // --- Pipeline Stage 1: Weight Calculation (1 Clock Cycle) ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_valid     <= 1'b0;
            r1_x         <= '0;
            r1_y         <= '0;
            weight_alpha <= '0;
            weight_beta  <= '0;
            weight_gamma <= '0;
        end else begin
            r1_valid <= raster_valid;
            r1_x     <= raster_x;
            r1_y     <= raster_y;

            if (raster_valid) begin
                // Multiply edge values by the inverted area constant
                prod_alpha = raster_e1 * inv_area;
                prod_beta  = raster_e2 * inv_area;
                prod_gamma = raster_e0 * inv_area;
                
                // Truncate to extract the top fraction bits (assuming 16-bit weight precision)
                weight_alpha <= prod_alpha[47:32];
                weight_beta  <= prod_beta[47:32];
                weight_gamma <= prod_gamma[47:32];
            end
        end
    end

    // --- Pipeline Stage 2: Color Attribute Interpolation (1 Clock Cycle) ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ps_valid <= 1'b0;
            ps_x     <= '0;
            ps_y     <= '0;
            ps_r     <= '0;
            ps_g     <= '0;
            ps_b     <= '0;
        end else begin
            ps_valid <= r1_valid;
            ps_x     <= r1_x;
            ps_y     <= r1_y;

            if (r1_valid) begin
                // Linearly interpolate each color channel based on the weights
                // (Weight * 8-bit color) >> 16 normalizes the fixed-point back to 8-bit integers
                ps_r <= ((weight_alpha * v0_r) + (weight_beta * v1_r) + (weight_gamma * v2_r)) >> 16;
                ps_g <= ((weight_alpha * v0_g) + (weight_beta * v1_g) + (weight_gamma * v2_g)) >> 16;
                ps_b <= ((weight_alpha * v0_b) + (weight_beta * v1_b) + (weight_gamma * v2_b)) >> 16;
            end
        end
    end

endmodule
