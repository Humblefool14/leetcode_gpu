`timescale 1ns / 1ps

module backface_culler #(
    parameter int WIDTH = 16
)(
    input  logic              clk,
    input  logic              rst_n,

    // From host_interface
    input  logic              start,
    input  logic signed [WIDTH-1:0] v0_x, v0_y,
    input  logic signed [WIDTH-1:0] v1_x, v1_y,
    input  logic signed [WIDTH-1:0] v2_x, v2_y,

    // To rasterizer_core (only if triangle faces camera)
    output logic              cull_pass,
    output logic              cull_done
);

    // Cross product: (v1 - v0) x (v2 - v0)
    // Positive = counter-clockwise (front-facing), Negative = clockwise (back-facing)
    // Assumes screen-space Y increases downward (standard for rasterization)

    logic signed [WIDTH:0] edge0_x, edge0_y;  // v1 - v0
    logic signed [WIDTH:0] edge1_x, edge1_y;  // v2 - v0
    logic signed [2*WIDTH:0] cross_product;  // edge0_x * edge1_y - edge0_y * edge1_x

    assign edge0_x = v1_x - v0_x;
    assign edge0_y = v1_y - v0_y;
    assign edge1_x = v2_x - v0_x;
    assign edge1_y = v2_y - v0_y;

    // Cross product sign determines facing
    // Positive = front-facing (pass), Negative or Zero = back-facing (cull)
    assign cross_product = (edge0_x * edge1_y) - (edge0_y * edge1_x);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cull_pass <= 1'b0;
            cull_done <= 1'b0;
        end else begin
            cull_done <= start;  // Single-cycle result
            cull_pass <= start && (cross_product > 0);  // Pass if CCW and non-degenerate
        end
    end

endmodule
