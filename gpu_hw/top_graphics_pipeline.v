`timescale 1ns / 1ps

module top_graphics_pipeline #(
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480,
    parameter int FB_ADDR_W     = 19,
    parameter int PIXEL_BITS    = 24,
    parameter bit USE_BILINEAR  = 0,
    parameter int TEX_WIDTH     = 256,
    parameter int TEX_HEIGHT    = 256
)(
    // Clock — direct input, no PLL for now
    input  logic        clk,
    input  logic        rst_n,

    // Stub register interface (replace with UART later)
    input  logic        host_wr_en,
    input  logic [7:0]  host_wr_addr,
    input  logic [31:0] host_wr_data,

    // VGA Output
    output logic [7:0]  vga_r, vga_g, vga_b,
    output logic        vga_hsync, vga_vsync, vga_de
);

    // =====================================================================
    // HOST INTERFACE (Stub — no UART/PLL)
    // =====================================================================
    logic        host_start, host_clear_z, host_tex_load;
    logic [15:0] host_v0_x, host_v0_y, host_v1_x, host_v1_y, host_v2_x, host_v2_y;
    logic [7:0]  host_v0_r, host_v0_g, host_v0_b;
    logic [7:0]  host_v1_r, host_v1_g, host_v1_b;
    logic [7:0]  host_v2_r, host_v2_g, host_v2_b;
    logic [15:0] host_v0_z, host_v1_z, host_v2_z;
    logic [15:0] host_v0_u, host_v0_v, host_v1_u, host_v1_v, host_v2_u, host_v2_v;
    logic [31:0] host_inv_area;
    logic [23:0] host_flat_color;
    logic        pipeline_busy;

    host_interface_stub u_host (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_en          (host_wr_en),
        .wr_addr        (host_wr_addr),
        .wr_data        (host_wr_data),
        .reg_start      (host_start),
        .reg_clear_z    (host_clear_z),
        .reg_v0_x       (host_v0_x), .reg_v0_y (host_v0_y),
        .reg_v1_x       (host_v1_x), .reg_v1_y (host_v1_y),
        .reg_v2_x       (host_v2_x), .reg_v2_y (host_v2_y),
        .reg_v0_r       (host_v0_r), .reg_v0_g (host_v0_g), .reg_v0_b (host_v0_b),
        .reg_v1_r       (host_v1_r), .reg_v1_g (host_v1_g), .reg_v1_b (host_v1_b),
        .reg_v2_r       (host_v2_r), .reg_v2_g (host_v2_g), .reg_v2_b (host_v2_b),
        .reg_v0_z       (host_v0_z), .reg_v1_z (host_v1_z), .reg_v2_z (host_v2_z),
        .reg_v0_u       (host_v0_u), .reg_v0_v (host_v0_v),
        .reg_v1_u       (host_v1_u), .reg_v1_v (host_v1_v),
        .reg_v2_u       (host_v2_u), .reg_v2_v (host_v2_v),
        .reg_inv_area   (host_inv_area),
        .reg_flat_color (host_flat_color),
        .reg_tex_load   (host_tex_load),
        .pipeline_busy  (pipeline_busy)
    );

    // =====================================================================
    // BACKFACE CULLING
    // =====================================================================
    logic cull_pass, cull_done;

    backface_culler u_cull (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (host_start),
        .v0_x     (host_v0_x), .v0_y (host_v0_y),
        .v1_x     (host_v1_x), .v1_y (host_v1_y),
        .v2_x     (host_v2_x), .v2_y (host_v2_y),
        .cull_pass(cull_pass),
        .cull_done(cull_done)
    );

    logic rasterizer_start;
    assign rasterizer_start = cull_done && cull_pass;

    // =====================================================================
    // RASTERIZER CORE
    // =====================================================================
    logic        raster_done;
    logic        frag_valid;
    logic [15:0] frag_x, frag_y;
    logic signed [31:0] frag_e0, frag_e1, frag_e2;

    rasterizer_core u_rasterizer (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (rasterizer_start),
        .busy       (pipeline_busy),
        .done       (raster_done),
        .v0_x       (host_v0_x), .v0_y (host_v0_y),
        .v1_x       (host_v1_x), .v1_y (host_v1_y),
        .v2_x       (host_v2_x), .v2_y (host_v2_y),
        .frag_valid (frag_valid),
        .frag_x     (frag_x),
        .frag_y     (frag_y),
        .frag_e0    (frag_e0),
        .frag_e1    (frag_e1),
        .frag_e2    (frag_e2)
    );

    // =====================================================================
    // PIXEL SHADER (with UV)
    // =====================================================================
    logic        ps_valid;
    logic [15:0] ps_x, ps_y;
    logic [7:0]  ps_r, ps_g, ps_b;
    logic [15:0] ps_z;
    logic        ps_tex_valid;
    logic [15:0] ps_u, ps_v;

    pixel_shader #(
        .UV_W(16)
    ) u_shader (
        .clk          (clk),
        .rst_n        (rst_n),
        .inv_area     (host_inv_area),
        .v0_r (host_v0_r), .v0_g (host_v0_g), .v0_b (host_v0_b),
        .v1_r (host_v1_r), .v1_g (host_v1_g), .v1_b (host_v1_b),
        .v2_r (host_v2_r), .v2_g (host_v2_g), .v2_b (host_v2_b),
        .v0_u (host_v0_u), .v0_v (host_v0_v),
        .v1_u (host_v1_u), .v1_v (host_v1_v),
        .v2_u (host_v2_u), .v2_v (host_v2_v),
        .v0_z (host_v0_z), .v1_z (host_v1_z), .v2_z (host_v2_z),
        .raster_valid (frag_valid),
        .raster_x     (frag_x),
        .raster_y     (frag_y),
        .raster_e0    (frag_e0),
        .raster_e1    (frag_e1),
        .raster_e2    (frag_e2),
        .ps_valid     (ps_valid),
        .ps_x         (ps_x),
        .ps_y         (ps_y),
        .ps_r         (ps_r),
        .ps_g         (ps_g),
        .ps_b         (ps_b),
        .ps_z         (ps_z),
        .ps_tex_valid (ps_tex_valid),
        .ps_u         (ps_u),
        .ps_v         (ps_v)
    );

    // =====================================================================
    // TEXTURE SYSTEM
    // =====================================================================
    logic        tex_bram_we;
    logic [15:0] tex_bram_waddr;
    logic [23:0] tex_bram_wdata;
    logic [15:0] tex_bram_raddr;
    logic [23:0] tex_bram_rdata;

    // Texture BRAM
    texture_bram u_tex_bram (
        .clk     (clk),
        .we_a    (tex_bram_we),
        .addr_a  (tex_bram_waddr),
        .wdata_a (tex_bram_wdata),
        .addr_b  (tex_bram_raddr),
        .rdata_b (tex_bram_rdata)
    );

    // Texture Loader (stubbed — no UART, use initial $readmemh or testbench)
    texture_loader u_tex_loader (
        .clk            (clk),
        .rst_n          (rst_n),
        .uart_rx_valid  (1'b0),     // Stubbed
        .uart_rx_data   (8'b0),     // Stubbed
        .tex_load_start (host_tex_load),
        .tex_load_busy  (),
        .tex_load_done  (),
        .tex_we         (tex_bram_we),
        .tex_waddr      (tex_bram_waddr),
        .tex_wdata      (tex_bram_wdata)
    );

    // Texture Sampler
    logic        tex_samp_valid;
    logic [23:0] tex_samp_rgba;

    texture_sampler #(
        .BILINEAR(USE_BILINEAR)
    ) u_tex_sampler (
        .clk        (clk),
        .rst_n      (rst_n),
        .tex_valid  (ps_tex_valid),
        .tex_u      (ps_u),
        .tex_v      (ps_v),
        .samp_valid (tex_samp_valid),
        .samp_rgba  (tex_samp_rgba),
        .bram_addr  (tex_bram_raddr),
        .bram_rdata (tex_bram_rdata)
    );

    // =====================================================================
    // COLOR MODULATION
    // =====================================================================
    logic        mod_valid;
    logic [7:0]  mod_r, mod_g, mod_b;

    color_modulate u_mod (
        .clk         (clk),
        .rst_n       (rst_n),
        .vcolor_valid(ps_valid),
        .vcolor_r    (ps_r),
        .vcolor_g    (ps_g),
        .vcolor_b    (ps_b),
        .tcolor_valid(tex_samp_valid),
        .tcolor_r    (tex_samp_rgba[23:16]),
        .tcolor_g    (tex_samp_rgba[15:8]),
        .tcolor_b    (tex_samp_rgba[7:0]),
        .mod_valid   (mod_valid),
        .mod_r       (mod_r),
        .mod_g       (mod_g),
        .mod_b       (mod_b)
    );

    // =====================================================================
    // OUTPUT MERGER
    // =====================================================================
    logic        om_fb_we;
    logic [FB_ADDR_W-1:0] om_fb_addr;
    logic [PIXEL_BITS-1:0] om_fb_wdata;
    logic        om_clear_done;
    logic        om_pipeline_stall;

    output_merger u_om (
        .clk            (clk),
        .rst_n          (rst_n),
        .clear_zbuffer  (host_clear_z),
        .clear_done     (om_clear_done),
        .pipeline_stall (om_pipeline_stall),
        .ps_valid       (mod_valid),
        .ps_x           (ps_x),
        .ps_y           (ps_y),
        .ps_color       ({mod_r, mod_g, mod_b}),
        .ps_z           (ps_z),
        .fb_we          (om_fb_we),
        .fb_addr        (om_fb_addr),
        .fb_wdata       (om_fb_wdata)
    );

    // =====================================================================
    // FRAMEBUFFER + DISPLAY
    // =====================================================================
    logic swap_buffers, front_buffer_id;
    logic [FB_ADDR_W-1:0]  disp_fb_rd_addr;
    logic [PIXEL_BITS-1:0] disp_fb_rd_data;

    framebuffer_controller u_fb (
        .clk            (clk),
        .rst_n          (rst_n),
        .swap_buffers   (swap_buffers),
        .front_buffer_id(front_buffer_id),
        .wr_en          (om_fb_we),
        .wr_addr        (om_fb_addr),
        .wr_data        (om_fb_wdata),
        .rd_addr        (disp_fb_rd_addr),
        .rd_data        (disp_fb_rd_data)
    );

    display_controller u_display (
        .clk        (clk),
        .rst_n      (rst_n),
        .fb_rd_addr (disp_fb_rd_addr),
        .fb_rd_data (disp_fb_rd_data),
        .swap_buffers(swap_buffers),
        .vga_r      (vga_r),
        .vga_g      (vga_g),
        .vga_b      (vga_b),
        .vga_hsync  (vga_hsync),
        .vga_vsync  (vga_vsync),
        .vga_de     (vga_de)
    );

endmodule
