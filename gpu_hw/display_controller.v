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
    // NOTE: this module assumes a 1-cycle SYNCHRONOUS READ (registered
    // output) memory, i.e. fb_rd_data is valid one clk after fb_rd_addr
    // is presented. If framebuffer_controller instead does a combinational
    // (async) read, remove the extra pipeline stage below and drive
    // vga_de/vga_r/vga_g/vga_b directly off pixel_active as in the
    // original version.
    output logic [ADDR_W-1:0] fb_rd_addr,
    input  logic [DATA_W-1:0] fb_rd_data,
    output logic              swap_buffers,  // pulse during VBLANK

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
    logic in_vblank;  // true during vertical blanking interval

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
    // Registered off pixel_active => fb_rd_addr is valid 1 cycle after
    // the counters that generated it. With a 1-cycle sync-read memory,
    // fb_rd_data therefore lands 1 cycle after THAT (2 cycles total from
    // the originating h_count/v_count). The output stage below is delayed
    // by a matching 2 cycles so vga_de/RGB line up with fb_rd_data.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fb_rd_addr <= '0;
        else if (pixel_active)
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

    // Second pipeline stage: delay counters/pixel_active by 1 extra cycle
    // to match the memory's read latency, so vga_de and RGB assert on the
    // same cycle fb_rd_data actually returns valid data for fb_rd_addr.
    logic [9:0] h_count_d, v_count_d;
    logic       pixel_active_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_count_d      <= '0;
            v_count_d      <= '0;
            pixel_active_d <= 1'b0;
        end else begin
            h_count_d      <= h_count;
            v_count_d      <= v_count;
            pixel_active_d <= pixel_active;
        end
    end

    // VGA outputs (registered), driven from the delayed counters so they
    // align with fb_rd_data's arrival time.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vga_hsync <= 1'b1;
            vga_vsync <= 1'b1;
            vga_de    <= 1'b0;
            vga_r     <= '0;
            vga_g     <= '0;
            vga_b     <= '0;
        end else begin
            vga_hsync <= ~((h_count_d >= H_ACTIVE + H_FRONT) &&
                           (h_count_d < H_ACTIVE + H_FRONT + H_SYNC));
            vga_vsync <= ~((v_count_d >= V_ACTIVE + V_FRONT) &&
                           (v_count_d < V_ACTIVE + V_FRONT + V_SYNC));
            vga_de    <= pixel_active_d;

            if (pixel_active_d) begin
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

    // Exactly one swap_buffers pulse per frame: once asserted, it must stay
    // low until the cycle where the next frame begins (v_count==0, h_count==0).
    property p_one_swap_per_frame;
        @(posedge clk) disable iff (!rst_n)
        swap_buffers |=> !swap_buffers throughout (##1 (v_count == 0 && h_count == 0))[->1];
    endproperty
    a_one_swap_per_frame: assert property (p_one_swap_per_frame);

endmodule
