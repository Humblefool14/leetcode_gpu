`timescale 1ns / 1ps

module top_graphics_pipeline #(
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480,
    parameter int FB_ADDR_W     = 19,   // clog2(640*480)
    parameter int PIXEL_BITS    = 24    // RGB888
)(
    input  logic        clk,            // 25.175 MHz pixel clock
    input  logic        rst_n,

    // UART from external receiver (e.g., Xilinx UART lite)
    input  logic        uart_rx_valid,
    input  logic [31:0] uart_rx_data,

    // VGA Output to Monitor
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b,
    output logic        vga_hsync,
    output logic        vga_vsync,
    output logic        vga_de
);

    // =====================================================================
    // HOST INTERFACE → All triangle data + control
    // =====================================================================

    logic        host_start;
    logic        host_clear_z;
    logic [15:0] host_v0_x, host_v0_y;
    logic [15:0] host_v1_x, host_v1_y;
    logic [15:0] host_v2_x, host_v2_y;
    logic [7:0]  host_v0_r, host_v0_g, host_v0_b;
    logic [7:0]  host_v1_r, host_v1_g, host_v1_b;
    logic [7:0]  host_v2_r, host_v2_g, host_v2_b;
    logic [15:0] host_v0_z, host_v1_z, host_v2_z;
    logic [31:0] host_inv_area;

    logic        pipeline_busy;

    host_interface u_host (
        .clk            (clk),
        .rst_n          (rst_n),
        .uart_rx_valid  (uart_rx_valid),
        .uart_rx_data   (uart_rx_data),
        .reg_start      (host_start),
        .reg_clear_z    (host_clear_z),
        .reg_status     (),
        .reg_v0_x       (host_v0_x), .reg_v0_y (host_v0_y),
        .reg_v1_x       (host_v1_x), .reg_v1_y (host_v1_y),
        .reg_v2_x       (host_v2_x), .reg_v2_y (host_v2_y),
        .reg_v0_r       (host_v0_r), .reg_v0_g (host_v0_g), .reg_v0_b (host_v0_b),
        .reg_v1_r       (host_v1_r), .reg_v1_g (host_v1_g), .reg_v1_b (host_v1_b),
        .reg_v2_r       (host_v2_r), .reg_v2_g (host_v2_g), .reg_v2_b (host_v2_b),
        .reg_v0_z       (host_v0_z),
        .reg_v1_z       (host_v1_z),
        .reg_v2_z       (host_v2_z),
        .reg_inv_area   (host_inv_area),
        .reg_flat_color (),
        .pipeline_busy  (pipeline_busy)
    );

    // =====================================================================
    // RASTERIZER CORE → Outputs fragments with edge values
    // =====================================================================

    logic        raster_done;
    logic        frag_valid;
    logic [15:0] frag_x, frag_y;
    logic signed [31:0] frag_e0, frag_e1, frag_e2;

    rasterizer_core u_rasterizer (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (host_start),
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
    // PIXEL SHADER → Gouraud interpolation (Option B)
    // =====================================================================

    logic        ps_valid;
    logic [15:0] ps_x, ps_y;
    logic [7:0]  ps_r, ps_g, ps_b;
    logic [15:0] ps_z;

    pixel_shader u_shader (
        .clk         (clk),
        .rst_n       (rst_n),
        .inv_area    (host_inv_area),
        .v0_r        (host_v0_r), .v0_g (host_v0_g), .v0_b (host_v0_b),
        .v1_r        (host_v1_r), .v1_g (host_v1_g), .v1_b (host_v1_b),
        .v2_r        (host_v2_r), .v2_g (host_v2_g), .v2_b (host_v2_b),
        .v0_z        (host_v0_z),
        .v1_z        (host_v1_z),
        .v2_z        (host_v2_z),
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

    // =====================================================================
    // OUTPUT MERGER → Z-test + framebuffer write
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
        .ps_valid       (ps_valid),
        .ps_x           (ps_x),
        .ps_y           (ps_y),
        .ps_color       ({ps_r, ps_g, ps_b}),
        .ps_z           (ps_z),
        .fb_we          (om_fb_we),
        .fb_addr        (om_fb_addr),
        .fb_wdata       (om_fb_wdata)
    );

    // Back-pressure: stall rasterizer during Z-clear
    // (Your rasterizer_core has no stall input — add one, or rely on host not sending during clear)
    // For now: assert that we never stall unexpectedly
    // Future: add .stall(om_pipeline_stall) to rasterizer_core

    // =====================================================================
    // FRAMEBUFFER → Double buffered BRAM
    // =====================================================================

    logic        swap_buffers;
    logic        front_buffer_id;
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

    // =====================================================================
    // DISPLAY CONTROLLER → VGA timing + buffer swap
    // =====================================================================

    display_controller u_display (
        .clk            (clk),
        .rst_n          (rst_n),
        .fb_rd_addr     (disp_fb_rd_addr),
        .fb_rd_data     (disp_fb_rd_data),
        .swap_buffers   (swap_buffers),
        .vga_r          (vga_r),
        .vga_g          (vga_g),
        .vga_b          (vga_b),
        .vga_hsync      (vga_hsync),
        .vga_vsync      (vga_vsync),
        .vga_de         (vga_de)
    );

endmodule
