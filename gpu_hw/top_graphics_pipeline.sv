module top_graphics_pipeline #(
    parameter WIDTH = 32,
    parameter DATA_WIDTH = 24,
    parameter ADDR_WIDTH = 19
)(
    input  wire        clk,      // 25.175 MHz for VGA
    input  wire        rst_n,
    
    // UART from Host PC
    input  wire        uart_rx,
    output wire        uart_tx,
    
    // VGA Output
    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire        vga_de
);

// Internal signals
wire [WIDTH-1:0] reg_v0_x, reg_v0_y;
wire [WIDTH-1:0] reg_v1_x, reg_v1_y;
wire [WIDTH-1:0] reg_v2_x, reg_v2_y;
wire [WIDTH-1:0] reg_color;
wire             reg_start;
wire             pipeline_busy;

// Triangle setup outputs
wire             setup_done;
wire [WIDTH-1:0] x_min, x_max, y_min, y_max;
wire [WIDTH-1:0] e0_init, e1_init, e2_init;
wire [WIDTH-1:0] dX0, dY0, dX1, dY1, dX2, dY2;

// Rasterizer control
wire             load_init;
wire             step_right;
wire             step_down;
wire             inside0, inside1, inside2;
wire             pixel_valid;
wire [WIDTH-1:0] pixel_x, pixel_y;

// Framebuffer
wire [ADDR_WIDTH-1:0] fb_wr_addr;
wire [DATA_WIDTH-1:0] fb_wr_data;
wire                  fb_wr_en;
wire [ADDR_WIDTH-1:0] fb_rd_addr;
wire [DATA_WIDTH-1:0] fb_rd_data;

// ============================================================================
// HOST INTERFACE
// ============================================================================
host_interface u_host (
    .clk            (clk),
    .rst_n          (rst_n),
    .uart_rx        (uart_rx),
    .uart_tx        (uart_tx),
    .uart_rx_valid  (/* connect to UART receiver */),
    .uart_rx_data   (/* connect to UART receiver */),
    .reg_start      (reg_start),
    .reg_v0_x       (reg_v0_x),
    .reg_v0_y       (reg_v0_y),
    .reg_v1_x       (reg_v1_x),
    .reg_v1_y       (reg_v1_y),
    .reg_v2_x       (reg_v2_x),
    .reg_v2_y       (reg_v2_y),
    .reg_color      (reg_color),
    .pipeline_busy  (pipeline_busy),
    .reg_status     ()
);

// ============================================================================
// TRIANGLE SETUP
// ============================================================================
triangle_setup u_setup (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (reg_start),
    .v0_x       (reg_v0_x),
    .v0_y       (reg_v0_y),
    .v1_x       (reg_v1_x),
    .v1_y       (reg_v1_y),
    .v2_x       (reg_v2_x),
    .v2_y       (reg_v2_y),
    .setup_done (setup_done),
    .x_min      (x_min),
    .x_max      (x_max),
    .y_min      (y_min),
    .y_max      (y_max),
    .e0_init    (e0_init),
    .e1_init    (e1_init),
    .e2_init    (e2_init),
    .dX0        (dX0),
    .dY0        (dY0),
    .dX1        (dX1),
    .dY1        (dY1),
    .dX2        (dX2),
    .dY2        (dY2)
);

// ============================================================================
// RASTERIZER CORE
// ============================================================================
rasterizer_core u_rasterizer (
    .clk         (clk),
    .rst_n       (rst_n),
    .setup_done  (setup_done),
    .x_min       (x_min),
    .x_max       (x_max),
    .y_min       (y_min),
    .y_max       (y_max),
    .e0_init     (e0_init),
    .e1_init     (e1_init),
    .e2_init     (e2_init),
    .dX0         (dX0),
    .dY0         (dY0),
    .dX1         (dX1),
    .dY1         (dY1),
    .dX2         (dX2),
    .dY2         (dY2),
    .load_init   (load_init),
    .step_right  (step_right),
    .step_down   (step_down),
    .inside0     (inside0),
    .inside1     (inside1),
    .inside2     (inside2),
    .pixel_valid (pixel_valid),
    .pixel_x     (pixel_x),
    .pixel_y     (pixel_y)
);

// ============================================================================
// EDGE EVALUATORS (3 instances)
// ============================================================================
edge_evaluator u_edge0 (
    .clk         (clk),
    .rst_n       (rst_n),
    .e_init      (e0_init),
    .load_init   (load_init),
    .dX          (dX0),
    .dY          (dY0),
    .step_right  (step_right),
    .step_down   (step_down),
    .e_value     (),
    .is_inside   (inside0)
);

edge_evaluator u_edge1 (
    .clk         (clk),
    .rst_n       (rst_n),
    .e_init      (e1_init),
    .load_init   (load_init),
    .dX          (dX1),
    .dY          (dY1),
    .step_right  (step_right),
    .step_down   (step_down),
    .e_value     (),
    .is_inside   (inside1)
);

edge_evaluator u_edge2 (
    .clk         (clk),
    .rst_n       (rst_n),
    .e_init      (e2_init),
    .load_init   (load_init),
    .dX          (dX2),
    .dY          (dY2),
    .step_right  (step_right),
    .step_down   (step_down),
    .e_value     (),
    .is_inside   (inside2)
);

// ============================================================================
// FRAMEBUFFER ADDRESS & DATA GENERATION
// ============================================================================
assign fb_wr_en   = pixel_valid;
assign fb_wr_addr = (pixel_y[ADDR_WIDTH-1:0] * 640) + pixel_x[ADDR_WIDTH-1:0];
assign fb_wr_data = reg_color[23:0]; // RGB from host interface

// ============================================================================
// FRAMEBUFFER (Dual-Port BRAM)
// ============================================================================
framebuffer_controller u_fb (
    .clk      (clk),
    .rst_n    (rst_n),
    .wr_en    (fb_wr_en),
    .wr_addr  (fb_wr_addr),
    .wr_data  (fb_wr_data),
    .rd_addr  (fb_rd_addr),
    .rd_data  (fb_rd_data)
);

// ============================================================================
// DISPLAY CONTROLLER
// ============================================================================
display_controller u_display (
    .clk       (clk),
    .rst_n     (rst_n),
    .fb_addr   (fb_rd_addr),
    .fb_data   (fb_rd_data),
    .vga_r     (vga_r),
    .vga_g     (vga_g),
    .vga_b     (vga_b),
    .vga_hsync (vga_hsync),
    .vga_vsync (vga_vsync),
    .vga_de    (vga_de)
);

// Pipeline busy signal
assign pipeline_busy = (u_rasterizer.state != u_rasterizer.IDLE);

endmodule
