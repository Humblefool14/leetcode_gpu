module display_controller #(
    parameter H_ACTIVE   = 640,
    parameter H_FRONT    = 16,
    parameter H_SYNC     = 96,
    parameter H_BACK     = 48,
    parameter H_TOTAL    = 800,
    parameter V_ACTIVE   = 480,
    parameter V_FRONT    = 10,
    parameter V_SYNC     = 2,
    parameter V_BACK     = 33,
    parameter V_TOTAL    = 525,
    parameter ADDR_W     = 19,
    parameter DATA_W     = 24
)(
    input  logic              clk,          // 25.175 MHz pixel clock
    input  logic              rst_n,

    // To framebuffer_controller
    output logic [ADDR_W-1:0] fb_rd_addr,
    input  logic [DATA_W-1:0] fb_rd_data,
    output logic              swap_buffers,  // NEW: pulse during VBLANK

    // VGA Output
    output logic [7:0]        vga_r,
    output logic [7:0]        vga_g,
    output logic [7:0]        vga_b,
    output logic              vga_hsync,
    output logic              vga_vsync,
    output logic              vga_de
);

    // Counters
    logic [9:0] h_count;
    logic [9:0] v_count;

    // Timing regions
    logic h_active, v_active, pixel_active;
    logic in_vblank;  // NEW: true during vertical blanking interval

    assign h_active    = (h_count < H_ACTIVE);
    assign v_active    = (v_count < V_ACTIVE);
    assign pixel_active = h_active && v_active;
    assign in_vblank   = (v_count >= V_ACTIVE);  // In front porch, sync, or back porch

    // Horizontal counter
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            h_count <= '0;
        else if (h_count == H_TOTAL - 1)
            h_count <= '0;
        else
            h_count <= h_count + 1'b1;
    end

    // Vertical counter
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_count <= '0;
        end else if (h_count == H_TOTAL - 1) begin
            if (v_count == V_TOTAL - 1)
                v_count <= '0;
            else
                v_count <= v_count + 1'b1;
        end
    end

    // Framebuffer address (only during active video)
    always_ff @(posedge clk) begin
        if (pixel_active)
            fb_rd_addr <= v_count * H_ACTIVE + h_count;
    end

    // Swap buffers: single pulse at start of VBLANK (first line after active)
    // v_count == V_ACTIVE, h_count == 0: just entered vertical blanking
    logic swap_pending;  // Ensure one pulse per frame

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            swap_buffers <= 1'b0;
            swap_pending <= 1'b0;
        end else begin
            swap_buffers <= 1'b0;  // Default

            if (v_count == V_ACTIVE && h_count == 0 && !swap_pending) begin
                swap_buffers <= 1'b1;
                swap_pending <= 1'b1;
            end

            // Reset pending at start of next frame
            if (v_count == 0 && h_count == 0)
                swap_pending <= 1'b0;
        end
    end

    // VGA outputs (registered)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vga_hsync <= 1'b1;
            vga_vsync <= 1'b1;
            vga_de    <= 1'b0;
            vga_r     <= '0;
            vga_g     <= '0;
            vga_b     <= '0;
        end else begin
            vga_hsync <= ~((h_count >= H_ACTIVE + H_FRONT) &&
                           (h_count < H_ACTIVE + H_FRONT + H_SYNC));
            vga_vsync <= ~((v_count >= V_ACTIVE + V_FRONT) &&
                           (v_count < V_ACTIVE + V_FRONT + V_SYNC));
            vga_de    <= pixel_active;

            if (pixel_active) begin
                vga_r <= fb_rd_data[23:16];
                vga_g <= fb_rd_data[15:8];
                vga_b <= fb_rd_data[7:0];
            end else begin
                vga_r <= '0;
                vga_g <= '0;
                vga_b <= '0;
            end
        end
    end

    // Assertions
    property p_swap_in_vblank;
        @(posedge clk) disable iff (!rst_n)
        swap_buffers |-> in_vblank;
    endproperty
    a_swap_in_vblank: assert property (p_swap_in_vblank);

    property p_one_swap_per_frame;
        @(posedge clk) disable iff (!rst_n)
        swap_buffers |=> !swap_buffers[*0:$] ##1 (v_count == 0 && h_count == 0);
    endproperty
    a_one_swap_per_frame: assert property (p_one_swap_per_frame);

endmodule
