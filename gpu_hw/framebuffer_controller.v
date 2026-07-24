`timescale 1ns / 1ps

module framebuffer_controller #(
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480,
    parameter int PIXEL_BITS    = 24,           // RGB888
    parameter int ADDR_W        = 19,           // 640*480 = 307200
    parameter int DATA_W        = 24
)(
    input  logic              clk,
    input  logic              rst_n,

    // Buffer swap control (from display_controller, during VBLANK)
    input  logic              swap_buffers,     // Pulse for one cycle
    output logic              front_buffer_id,  // 0 = buf0 front, 1 = buf1 front

    // Rasterizer / Output Merger (Write Port)
    input  logic              wr_en,
    input  logic [ADDR_W-1:0] wr_addr,        // 0 to 307199 (within one buffer)
    input  logic [DATA_W-1:0] wr_data,

    // Display Controller (Read Port)
    input  logic [ADDR_W-1:0] rd_addr,          // 0 to 307199 (within one buffer)
    output logic [DATA_W-1:0] rd_data
);

    localparam int FB_SIZE = SCREEN_WIDTH * SCREEN_HEIGHT;

    // Two framebuffers — inferred as dual-port BRAMs
    (* ram_style = "block" *)
    logic [DATA_W-1:0] buffer0 [0:FB_SIZE-1];
    (* ram_style = "block" *)
    logic [DATA_W-1:0] buffer1 [0:FB_SIZE-1];

    // Swap state
    logic buf0_is_front;  // 1 = buffer0 is front (display reads), buffer1 is back (rasterizer writes)

    // Physical addresses: offset by buffer base
    logic [ADDR_W:0] wr_phys_addr;  // Extra bit for buffer select
    logic [ADDR_W:0] rd_phys_addr;

    // Write routing: always writes to back buffer
    logic wr_to_buf0;  // 1 = write to buffer0, 0 = write to buffer1
    logic [ADDR_W-1:0] wr_offset;

    assign wr_to_buf0 = buf0_is_front ? 1'b0 : 1'b1;  // Write to opposite of front
    assign wr_offset  = wr_addr;

    // Read routing: always reads from front buffer
    logic rd_from_buf0;
    logic [ADDR_W-1:0] rd_offset;

    assign rd_from_buf0 = buf0_is_front ? 1'b1 : 1'b0;
    assign rd_offset      = rd_addr;

    // Buffer swap (during VBLANK only — safe because display is not reading visible pixels)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf0_is_front <= 1'b1;  // Buffer0 starts as front
        end else if (swap_buffers) begin
            buf0_is_front <= ~buf0_is_front;
        end
    end

    assign front_buffer_id = buf0_is_front;

    // =====================================================================
    // WRITE PORT (to back buffer)
    // =====================================================================
    always_ff @(posedge clk) begin
        if (wr_en) begin
            if (wr_to_buf0)
                buffer0[wr_offset] <= wr_data;
            else
                buffer1[wr_offset] <= wr_data;
        end
    end

    // =====================================================================
    // READ PORT (from front buffer) — registered for clean timing
    // =====================================================================
    logic [DATA_W-1:0] rd_buf0, rd_buf1;

    always_ff @(posedge clk) begin
        rd_buf0 <= buffer0[rd_offset];
        rd_buf1 <= buffer1[rd_offset];
    end

    assign rd_data = rd_from_buf0 ? rd_buf0 : rd_buf1;

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Safety: swap only happens during VBLANK (rd_addr in vertical blank region)
    // This is checked at top level, but good to document here

    // Safety: no write to front buffer (would cause tearing)
    property p_no_write_to_front;
        @(posedge clk) disable iff (!rst_n)
        wr_en |-> (wr_to_buf0 != buf0_is_front);  // Write target != front buffer
    endproperty
    a_no_write_to_front: assert property (p_no_write_to_front);

    // Safety: read always from front buffer
    property p_read_from_front;
        @(posedge clk) disable iff (!rst_n)
        (rd_from_buf0 == buf0_is_front);
    endproperty
    a_read_from_front: assert property (p_read_from_front);

endmodule
