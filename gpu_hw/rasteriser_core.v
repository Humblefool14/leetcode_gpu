`timescale 1ns / 1ps

module rasterizer_core (
    input  logic        clk,
    input  logic        rst_n,
    
    // Control Handshakes
    input  logic        start,
    output logic        busy,
    output logic        done,
    
    // Input Triangle Geometry (Screen Space Coordinates)
    input  logic signed [15:0] v0_x, input  logic signed [15:0] v0_y,
    input  logic signed [15:0] v1_x, input  logic signed [15:0] v1_y,
    input  logic signed [15:0] v2_x, input  logic signed [15:0] v2_y,
    
    // Output Fragment Stream (To Pixel Shader / Output Merger)
    output logic        frag_valid,
    output logic [15:0] frag_x,
    output logic [15:0] frag_y,
    output logic signed [31:0] frag_e0,
    output logic signed [31:0] frag_e1,
    output logic signed [31:0] frag_e2
);

    // --- State Machine States ---
    typedef enum logic [1:0] {
        IDLE  = 2'b00,
        SETUP = 2'b01,
        SCAN  = 2'b10
    } state_t;
    
    state_t state;

    // --- Pipeline Registers ---
    logic signed [15:0] min_x, max_x, min_y, max_y;
    logic signed [15:0] curr_x, curr_y;
    
    // Edge Deltas
    logic signed [15:0] dX0, dY0, dX1, dY1, dX2, dY2;
    
    // Accumulators for the 3 Edges
    logic signed [31:0] edge0, edge1, edge2;

    // Helper functions for Min/Max
    function logic signed [15:0] min3(input logic signed [15:0] a, b, c);
        return (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
    endfunction

    function logic signed [15:0] max3(input logic signed [15:0] a, b, c);
        return (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
    endfunction

    // --- Control and Stepping Logic ---
    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            done       <= 1'b0;
            frag_valid <= 1'b0;
            curr_x     <= '0;
            curr_y     <= '0;
        end else begin
            frag_valid <= 1'b0; // Default Strobe
            done       <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        state <= SETUP;
                    end
                end

                SETUP: begin
                    // 1. Calculate Bounding Box
                    min_x <= min3(v0_x, v1_x, v2_x);
                    max_x <= max3(v0_x, v1_x, v2_x);
                    min_y <= min3(v0_y, v1_y, v2_y);
                    max_y <= max3(v0_y, v1_y, v2_y);
                    
                    // 2. Pre-calculate Edge Deltas (Winding order dependent)
                    dX0 <= v1_x - v0_x;  dY0 <= v1_y - v0_y;
                    dX1 <= v2_x - v1_x;  dY1 <= v2_y - v1_y;
                    dX2 <= v0_x - v2_x;  dY2 <= v0_y - v2_y;
                    
                    state <= SCAN;
                end

                SCAN: begin
                    // Initialize counters and edge calculations on entering SCAN
                    if (curr_x == '0 && curr_y == '0) begin
                        curr_x <= min_x;
                        curr_y <= min_y;
                        
                        // Seed Pineda's Cross Product Equation for the first pixel (min_x, min_y)
                        edge0 <= (min_x - v0_x)*dY0 - (min_y - v0_y)*dX0;
                        edge1 <= (min_x - v1_x)*dY1 - (min_y - v1_y)*dX1;
                        edge2 <= (min_x - v2_x)*dY2 - (min_y - v2_y)*dX2;
                    end else begin
                        // Check if the current pixel is inside the triangle
                        // (Sign-bit check: MSB must be 0 for signed positive values)
                        if (!edge0[31] && !edge1[31] && !edge2[31]) begin
                            frag_valid <= 1'b1;
                            frag_x     <= curr_x;
                            frag_y     <= curr_y;
                            frag_e0    <= edge0;
                            frag_e1    <= edge1;
                            frag_e2    <= edge2;
                        end

                        // Lawnmower Scan Pattern State Machine
                        if (curr_x < max_x) begin
                            // Step Right: Add dY incrementally
                            curr_x <= curr_x + 1;
                            edge0  <= edge0 + dY0;
                            edge1  <= edge1 + dY1;
                            edge2  <= edge2 + dY2;
                        end else begin
                            // Reached right boundary of box, step down to next row
                            if (curr_y < max_y) begin
                                curr_x <= min_x;
                                curr_y <= curr_y + 1;
                                
                                // Reset back to left side of the row and subtract dX
                                edge0  <= ((min_x - v0_x)*dY0) - ((curr_y + 1 - v0_y)*dX0);
                                edge1  <= ((min_x - v1_x)*dY1) - ((curr_y + 1 - v1_y)*dX1);
                                edge2  <= ((min_x - v2_x)*dY2) - ((curr_y + 1 - v2_y)*dX2);
                            end else begin
                                // Finished scanning bounding box
                                state  <= IDLE;
                                done   <= 1'b1;
                                curr_x <= '0;
                                curr_y <= '0;
                            end
                        end
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
