`timescale 1ns / 1ps

module shadow_map #(
    parameter int SHADOW_W    = 256,   // Shadow map resolution
    parameter int SHADOW_H    = 256,
    parameter int SHADOW_ADDR_W = $clog2(SHADOW_W * SHADOW_H),
    parameter int Z_W         = 16
)(
    input  logic              clk,
    input  logic              rst_n,

    // Control
    input  logic              shadow_pass_start,  // Begin shadow pass
    output logic              shadow_pass_busy,
    output logic              shadow_pass_done,

    // Triangle input (from host, light-space)
    input  logic              tri_valid,
    input  logic [15:0]       v0_x, v0_y,  // Light-space screen coords
    input  logic [15:0]       v1_x, v1_y,
    input  logic [15:0]       v2_x, v2_y,
    input  logic [Z_W-1:0]    v0_z, v1_z, v2_z,  // Light-space depth

    // Shadow map output (to shader)
    output logic              shadow_ready,
    output logic [Z_W-1:0]    shadow_z_out [0:SHADOW_W*SHADOW_H-1]  // Or read port
);

    // Shadow Z-buffer (single buffer, no double buffering needed)
    (* ram_style = "block" *)
    logic [Z_W-1:0] shadow_buffer [0:SHADOW_W*SHADOW_H-1];

    // Simple rasterizer for shadow pass (depth only, no color)
    // Reuse your rasterizer_core with:
    // - Output: Z only (no color/texture)
    // - Write to shadow_buffer instead of framebuffer

    // State machine
    typedef enum logic [1:0] {
        IDLE,
        RASTERIZING,
        DONE
    } shadow_state_t;

    shadow_state_t state;

    // Simplified: use a mini-rasterizer or reuse main rasterizer
    // For now: stub that accepts one triangle at a time

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            shadow_pass_busy <= 1'b0;
            shadow_pass_done <= 1'b0;
        end else begin
            shadow_pass_done <= 1'b0;

            case (state)
                IDLE: begin
                    if (shadow_pass_start) begin
                        state <= RASTERIZING;
                        shadow_pass_busy <= 1'b1;
                        // Clear shadow buffer to max depth
                        // (or clear before starting)
                    end
                end

                RASTERIZING: begin
                    if (tri_valid) begin
                        // Rasterize triangle to shadow_buffer
                        // Write minimum Z per pixel
                        // ... (instantiate simplified rasterizer)
                    end else begin
                        state <= DONE;
                    end
                end

                DONE: begin
                    shadow_pass_busy <= 1'b0;
                    shadow_pass_done <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    // Read port for main shader
    logic [SHADOW_ADDR_W-1:0] shadow_rd_addr;
    logic [Z_W-1:0]           shadow_rd_data;

    always_ff @(posedge clk) begin
        shadow_rd_data <= shadow_buffer[shadow_rd_addr];
    end

    // Export read interface
    assign shadow_ready = (state == IDLE);

endmodule
