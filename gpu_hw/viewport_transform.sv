`timescale 1ns / 1ps

module viewport_transform #(
    parameter int NDC_WIDTH     = 18,  // signed NDC fixed-point width (Qm.NDC_FRAC, margin outside -1..1 for near-clip epsilon)
    parameter int NDC_FRAC      = 16,  // fractional bits of NDC input
    parameter int SCR_WIDTH     = 24,  // width of screen-space fixed-point coords/params
    parameter int SUBPIXEL_BITS = 8    // fractional (subpixel) bits in screen-space output, for rasterizer precision
)(
    input  logic              clk,
    input  logic              rst_n,

    // From clip/cull stage
    input  logic              start,
    input  logic signed [NDC_WIDTH-1:0] ndc_x, ndc_y, ndc_z,

    // Viewport config — held steady for the duration of a draw.
    // NOTE: if these can change while vertices are in-flight in this pipeline,
    // you need a stall/drain on config update, or results for in-flight
    // vertices will silently mix old/new viewport state.
    input  logic signed [SCR_WIDTH-1:0] vp_half_width,   // width/2,  subpixel-scaled (Q?.SUBPIXEL_BITS)
    input  logic signed [SCR_WIDTH-1:0] vp_half_height,  // height/2, subpixel-scaled
    input  logic signed [SCR_WIDTH-1:0] vp_center_x,     // x0 + width/2,  subpixel-scaled
    input  logic signed [SCR_WIDTH-1:0] vp_center_y,     // y0 + height/2, subpixel-scaled
    input  logic signed [SCR_WIDTH-1:0] vp_depth_scale,  // maps ndc_z range -> output depth range
    input  logic signed [SCR_WIDTH-1:0] vp_depth_bias,

    // To triangle_setup
    output logic signed [SCR_WIDTH-1:0] screen_x, screen_y, screen_z,
    output logic              vp_done
);

    // ---------------------------------------------------------------
    // Width bookkeeping
    // ---------------------------------------------------------------
    // NDC values are sign-extended by 1 bit before use: ndc_y needs the
    // extra headroom to negate safely (Y-flip) without overflow at the
    // most-negative input value; x and z get the same width for symmetry.
    localparam int NDC_EXT_W  = NDC_WIDTH + 1;
    localparam int PROD_W     = NDC_EXT_W + SCR_WIDTH;   // full-precision product
    localparam int SHIFT      = NDC_FRAC;                // realign frac bits: product has NDC_FRAC+SUBPIXEL_BITS frac bits, want SUBPIXEL_BITS
    localparam int SHIFTED_W  = PROD_W - SHIFT;
    localparam int SUM_W      = SHIFTED_W + 1;           // guard bit for the add-bias stage

    // ---------------------------------------------------------------
    // Stage 1: sign-extend NDC inputs, apply Y-flip to ndc_y, register
    // ---------------------------------------------------------------
    logic signed [NDC_EXT_W-1:0] ndc_x_ext_c, ndc_y_ext_c, ndc_z_ext_c;
    logic signed [NDC_EXT_W-1:0] ndc_y_neg_c;

    assign ndc_x_ext_c = {ndc_x[NDC_WIDTH-1], ndc_x};
    assign ndc_y_ext_c = {ndc_y[NDC_WIDTH-1], ndc_y};
    assign ndc_z_ext_c = {ndc_z[NDC_WIDTH-1], ndc_z};
    assign ndc_y_neg_c = -ndc_y_ext_c;  // NDC is Y-up; screen space is Y-down

    logic signed [NDC_EXT_W-1:0] ndc_x_r1, ndc_y_r1, ndc_z_r1;
    logic                        valid_r1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ndc_x_r1 <= '0;
            ndc_y_r1 <= '0;
            ndc_z_r1 <= '0;
            valid_r1 <= 1'b0;
        end else begin
            ndc_x_r1 <= ndc_x_ext_c;
            ndc_y_r1 <= ndc_y_neg_c;
            ndc_z_r1 <= ndc_z_ext_c;
            valid_r1 <= start;
        end
    end

    // ---------------------------------------------------------------
    // Stage 2: multiply by half-extents / depth scale, register product
    // ---------------------------------------------------------------
    logic signed [PROD_W-1:0] prod_x_c, prod_y_c, prod_z_c;

    assign prod_x_c = ndc_x_r1 * vp_half_width;
    assign prod_y_c = ndc_y_r1 * vp_half_height;
    assign prod_z_c = ndc_z_r1 * vp_depth_scale;

    logic signed [PROD_W-1:0] prod_x_r2, prod_y_r2, prod_z_r2;
    logic                     valid_r2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_x_r2 <= '0;
            prod_y_r2 <= '0;
            prod_z_r2 <= '0;
            valid_r2  <= 1'b0;
        end else begin
            prod_x_r2 <= prod_x_c;
            prod_y_r2 <= prod_y_c;
            prod_z_r2 <= prod_z_c;
            valid_r2  <= valid_r1;
        end
    end

    // ---------------------------------------------------------------
    // Stage 3: realign fractional bits (shift), add center/bias, register
    // ---------------------------------------------------------------
    logic signed [SHIFTED_W-1:0] shifted_x_c, shifted_y_c, shifted_z_c;
    logic signed [SUM_W-1:0]     sum_x_c, sum_y_c, sum_z_c;

    // Arithmetic right-shift realigns product's (NDC_FRAC+SUBPIXEL_BITS)
    // fractional bits down to SUBPIXEL_BITS, matching vp_center_*/vp_depth_bias format.
    assign shifted_x_c = prod_x_r2 >>> SHIFT;
    assign shifted_y_c = prod_y_r2 >>> SHIFT;
    assign shifted_z_c = prod_z_r2 >>> SHIFT;

    assign sum_x_c = shifted_x_c + vp_center_x;
    assign sum_y_c = shifted_y_c + vp_center_y;
    assign sum_z_c = shifted_z_c + vp_depth_bias;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            screen_x <= '0;
            screen_y <= '0;
            screen_z <= '0;
            vp_done  <= 1'b0;
        end else begin
            // Truncating the guard bit here — if a vertex can legitimately
            // land outside the viewport (e.g. clip didn't fully constrain
            // it), consider clamping/saturating instead of dropping the MSB.
            screen_x <= sum_x_c[SCR_WIDTH-1:0];
            screen_y <= sum_y_c[SCR_WIDTH-1:0];
            screen_z <= sum_z_c[SCR_WIDTH-1:0];
            vp_done  <= valid_r2;
        end
    end

endmodule
