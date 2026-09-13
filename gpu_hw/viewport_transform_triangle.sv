`timescale 1ns / 1ps

module viewport_transform_triangle #(
    parameter int NDC_WIDTH     = 18,
    parameter int NDC_FRAC      = 16,
    parameter int SCR_WIDTH     = 24,
    parameter int SUBPIXEL_BITS = 8,
    parameter int NUM_VERTS     = 3   // triangle = 3; kept as a parameter in case you
                                       // reuse this for a quad/line primitive later
)(
    input  logic              clk,
    input  logic              rst_n,

    // From clip/cull stage — one triangle's worth of NDC vertices, same start pulse
    input  logic              start,
    input  logic signed [NDC_WIDTH-1:0] ndc_x [NUM_VERTS],
    input  logic signed [NDC_WIDTH-1:0] ndc_y [NUM_VERTS],
    input  logic signed [NDC_WIDTH-1:0] ndc_z [NUM_VERTS],

    // Shared viewport config across all lanes
    input  logic signed [SCR_WIDTH-1:0] vp_half_width,
    input  logic signed [SCR_WIDTH-1:0] vp_half_height,
    input  logic signed [SCR_WIDTH-1:0] vp_center_x,
    input  logic signed [SCR_WIDTH-1:0] vp_center_y,
    input  logic signed [SCR_WIDTH-1:0] vp_depth_scale,
    input  logic signed [SCR_WIDTH-1:0] vp_depth_bias,

    // To triangle_setup — all vertices land together, same cycle
    output logic signed [SCR_WIDTH-1:0] screen_x [NUM_VERTS],
    output logic signed [SCR_WIDTH-1:0] screen_y [NUM_VERTS],
    output logic signed [SCR_WIDTH-1:0] screen_z [NUM_VERTS],
    output logic              vp_done   // single done; all lanes share start/latency
);

    // Per-lane done, only to catch a lane-desync bug in sim — not consumed downstream.
    logic vp_done_lane [NUM_VERTS];

    genvar i;
    generate
        for (i = 0; i < NUM_VERTS; i++) begin : gen_vp_lane
            viewport_transform #(
                .NDC_WIDTH(NDC_WIDTH), .NDC_FRAC(NDC_FRAC),
                .SCR_WIDTH(SCR_WIDTH), .SUBPIXEL_BITS(SUBPIXEL_BITS)
            ) u_lane (
                .clk(clk), .rst_n(rst_n), .start(start),
                .ndc_x(ndc_x[i]), .ndc_y(ndc_y[i]), .ndc_z(ndc_z[i]),
                .vp_half_width(vp_half_width), .vp_half_height(vp_half_height),
                .vp_center_x(vp_center_x), .vp_center_y(vp_center_y),
                .vp_depth_scale(vp_depth_scale), .vp_depth_bias(vp_depth_bias),
                .screen_x(screen_x[i]), .screen_y(screen_y[i]), .screen_z(screen_z[i]),
                .vp_done(vp_done_lane[i])
            );
        end
    endgenerate

    // synthesis translate_off
    always_ff @(posedge clk) begin
        if (rst_n) begin
            for (int k = 1; k < NUM_VERTS; k++) begin
                if (vp_done_lane[k] !== vp_done_lane[0]) begin
                    $error("viewport_transform_triangle: lane %0d done desynced from lane 0 (%0d vs %0d) at time %0t",
                           k, vp_done_lane[k], vp_done_lane[0], $time);
                end
            end
        end
    end
    // synthesis translate_on

    assign vp_done = vp_done_lane[0];

endmodule
