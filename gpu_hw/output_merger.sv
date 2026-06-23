`timescale 1ns / 1ps

module output_merger (
    input  logic         clk,
    input  logic         rst_n,
    
    // Global Clear (Clears the Z-buffer to max depth at the start of a frame)
    input  logic         clear_zbuffer,
    output logic         clear_done,
    
    // Stream input from Pixel Shader (PS)
    input  logic         ps_valid,
    input  logic [15:0]  ps_x,
    input  logic [15:0]  ps_y,
    input  logic [23:0]  ps_color, // Combined R, G, B channels
    input  logic [15:0]  ps_z,     // 16-bit Depth value (smaller = closer)
    
    // Framebuffer Write Interface (To Color Memory)
    output logic         fb_we,
    output logic [18:0]  fb_addr,   // Supports up to 640x480 (307,200 addresses)
    output logic [23:0]  fb_wdata
);

    localparam int SCREEN_WIDTH  = 640;
    localparam int SCREEN_HEIGHT = 480;
    localparam int FB_SIZE       = SCREEN_WIDTH * SCREEN_HEIGHT;

    // --- State Machine for Z-Buffer Clearing ---
    enum logic { IDLE = 1'b0, CLEAR = 1'b1 } state;
    logic [18:0] clear_addr;

    // --- Internal Z-Buffer Memory (16-bit depth per pixel) ---
    // Instantiated as a dual-port RAM: Port A for RMW Pipeline, Port B for Clearing
    logic [15:0] z_buffer [0:FB_SIZE-1];
    
    // Pipeline Registers
    // Stage 1: Memory Address Generation & Read Trigger
    logic        r1_valid;
    logic [18:0] r1_addr;
    logic [23:0] r1_color;
    logic [15:0] r1_z;

    // Stage 2: Latched Data from Read & Comparison
    logic        r2_valid;
    logic [18:0] r2_addr;
    logic [23:0] r2_color;
    logic [15:0] r2_z;
    logic [15:0] z_old; // Retrieved from memory

    // Address Calculation Helper
    logic [18:0] calc_addr;
    assign calc_addr = (ps_y * SCREEN_WIDTH) + ps_x;

    // --- Z-Buffer Control & Pipeline Logic ---
    assign clear_done = (state == IDLE) && (clear_addr == '0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            clear_addr   <= '0;
            r1_valid     <= 1'b0;
            r2_valid     <= 1'b0;
            fb_we        <= 1'b0;
            fb_addr      <= '0;
            fb_wdata     <= '0;
        end else begin
            // Default Strobe
            fb_we <= 1'b0;

            // --- Z-Buffer Synchronous Clear Block ---
            if (clear_zbuffer) begin
                state      <= CLEAR;
                clear_addr <= '0;
            end else if (state == CLEAR) begin
                z_buffer[clear_addr] <= 16'hFFFF; // Set to maximum depth (far away)
                if (clear_addr < FB_SIZE - 1) begin
                    clear_addr <= clear_addr + 1;
                end else begin
                    state      <= IDLE;
                    clear_addr <= '0;
                end
            end

            // --- 3-Stage Read-Modify-Write Pipeline ---
            if (state == IDLE) begin
                
                // STAGE 1: Calculate Address and trigger RAM read latency cycle
                r1_valid <= ps_valid;
                if (ps_valid) begin
                    r1_addr  <= calc_addr;
                    r1_color <= ps_color;
                    r1_z     <= ps_z;
                end

                // STAGE 2: Read data becomes available from memory array
                r2_valid <= r1_valid;
                if (r1_valid) begin
                    r2_addr  <= r1_addr;
                    r2_color <= r1_color;
                    r2_z     <= r1_z;
                    z_old    <= z_buffer[r1_addr]; // BRAM Read Latency met here
                end

                // STAGE 3: Compare Depth and Commit/Write back to memories
                if (r2_valid) begin
                    // Z-Test: If new Z is less than (closer than) old Z, it passes!
                    if (r2_z < z_old) begin
                        // Update Z-buffer memory
                        z_buffer[r2_addr] <= r2_z;
                        
                        // Output commands to commit color to the Framebuffer
                        fb_we    <= 1'b1;
                        fb_addr  <= r2_addr;
                        fb_wdata <= r2_color;
                    end
                end
            end
        end
    end

endmodule
