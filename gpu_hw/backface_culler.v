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
    // NOTE: verify sign convention against actual pipeline stage (pre/post Y-flip)
    // before trusting the cull_pass polarity below.

    localparam int EDGE_W  = WIDTH + 1;       // room for v1-v0 subtraction
    localparam int PROD_W  = 2 * EDGE_W;      // room for signed*signed product
    localparam int CROSS_W = PROD_W + 1;      // extra bit for prod0 - prod1

    // ---------------------------------------------------------------
    // Stage 1: compute edge vectors, register them + valid bit
    // ---------------------------------------------------------------
    logic signed [EDGE_W-1:0] edge0_x_c, edge0_y_c;  // v1 - v0 (combinational)
    logic signed [EDGE_W-1:0] edge1_x_c, edge1_y_c;  // v2 - v0 (combinational)

    assign edge0_x_c = v1_x - v0_x;
    assign edge0_y_c = v1_y - v0_y;
    assign edge1_x_c = v2_x - v0_x;
    assign edge1_y_c = v2_y - v0_y;

    logic signed [EDGE_W-1:0] edge0_x_r1, edge0_y_r1;
    logic signed [EDGE_W-1:0] edge1_x_r1, edge1_y_r1;
    logic                     valid_r1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            edge0_x_r1 <= '0;
            edge0_y_r1 <= '0;
            edge1_x_r1 <= '0;
            edge1_y_r1 <= '0;
            valid_r1   <= 1'b0;
        end else begin
            edge0_x_r1 <= edge0_x_c;
            edge0_y_r1 <= edge0_y_c;
            edge1_x_r1 <= edge1_x_c;
            edge1_y_r1 <= edge1_y_c;
            valid_r1   <= start;
        end
    end

    // ---------------------------------------------------------------
    // Stage 2: compute cross-product partial products, register them
    // ---------------------------------------------------------------
    logic signed [PROD_W-1:0] prod0_c, prod1_c;  // combinational

    assign prod0_c = edge0_x_r1 * edge1_y_r1;
    assign prod1_c = edge0_y_r1 * edge1_x_r1;

    logic signed [PROD_W-1:0] prod0_r2, prod1_r2;
    logic                     valid_r2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod0_r2 <= '0;
            prod1_r2 <= '0;
            valid_r2 <= 1'b0;
        end else begin
            prod0_r2 <= prod0_c;
            prod1_r2 <= prod1_c;
            valid_r2 <= valid_r1;
        end
    end

    // ---------------------------------------------------------------
    // Stage 3: subtract, compare, register final result
    // ---------------------------------------------------------------
    logic signed [CROSS_W-1:0] cross_product_c;  // combinational

    assign cross_product_c = prod0_r2 - prod1_r2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cull_pass <= 1'b0;
            cull_done <= 1'b0;
        end else begin
            cull_done <= valid_r2;
            cull_pass <= valid_r2 && (cross_product_c > 0);
        end
    end

endmodule
