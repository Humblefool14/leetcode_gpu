module rasterizer_shader_om_integration (
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        start,
    output logic        busy,
    output logic        done,

    // Triangle input (from host)
    input  logic [15:0] v0_x, v0_y, v1_x, v1_y, v2_x, v2_y,

    // Vertex colors for Gouraud
    input  logic [7:0]  v0_r, v0_g, v0_b,
    input  logic [7:0]  v1_r, v1_g, v1_b,
    input  logic [7:0]  v2_r, v2_g, v2_b,

    // Vertex Z for depth interpolation
    input  logic [15:0] v0_z, v1_z, v2_z,

    // Triangle constant: 1/area in 0.32 fixed-point
    input  logic [31:0] inv_area,

    // Framebuffer output
    output logic        fb_we,
    output logic [18:0] fb_addr,
    output logic [23:0] fb_wdata
);

    // Rasterizer → Shader
    logic        frag_valid;
    logic [15:0] frag_x, frag_y;
    logic [31:0] frag_e0, frag_e1, frag_e2;

    // Shader → OM
    logic        ps_valid;
    logic [15:0] ps_x, ps_y;
    logic [7:0]  ps_r, ps_g, ps_b;
    logic [15:0] ps_z;

    // Rasterizer Core
    rasterizer_core u_rasterizer (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .busy       (busy),
        .done       (done),
        .v0_x       (v0_x), .v0_y (v0_y),
        .v1_x       (v1_x), .v1_y (v1_y),
        .v2_x       (v2_x), .v2_y (v2_y),
        .frag_valid (frag_valid),
        .frag_x     (frag_x),
        .frag_y     (frag_y),
        .frag_e0    (frag_e0),
        .frag_e1    (frag_e1),
        .frag_e2    (frag_e2)
    );

    // Pixel Shader
    pixel_shader u_shader (
        .clk         (clk),
        .rst_n       (rst_n),
        .inv_area    (inv_area),
        .v0_r (v0_r), .v0_g (v0_g), .v0_b (v0_b),
        .v1_r (v1_r), .v1_g (v1_g), .v1_b (v1_b),
        .v2_r (v2_r), .v2_g (v2_g), .v2_b (v2_b),
        .v0_z        (v0_z),
        .v1_z        (v1_z),
        .v2_z        (v2_z),
        .raster_valid(frag_valid),
        .raster_x    (frag_x),
        .raster_y    (frag_y),
        .raster_e0   (frag_e0),
        .raster_e1   (frag_e1),
        .raster_e2   (frag_e2),
        .ps_valid    (ps_valid),
        .ps_x        (ps_x),
        .ps_y        (ps_y),
        .ps_r        (ps_r),
        .ps_g        (ps_g),
        .ps_b        (ps_b),
        .ps_z        (ps_z)
    );

    // Output Merger
    output_merger u_om (
        .clk            (clk),
        .rst_n          (rst_n),
        .clear_zbuffer  (1'b0),
        .clear_done     (),
        .pipeline_stall (1'b0),
        .ps_valid       (ps_valid),
        .ps_x           (ps_x),
        .ps_y           (ps_y),
        .ps_color       ({ps_r, ps_g, ps_b}),
        .ps_z           (ps_z),
        .fb_we          (fb_we),
        .fb_addr        (fb_addr),
        .fb_wdata       (fb_wdata)
    );

endmodule
