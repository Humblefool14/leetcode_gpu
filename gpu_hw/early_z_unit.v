`timescale 1ns / 1ps

module early_z_unit #(
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480,
    parameter int FB_SIZE       = SCREEN_WIDTH * SCREEN_HEIGHT,
    parameter int ADDR_W        = $clog2(FB_SIZE),
    parameter int Z_W           = 16,
    parameter logic [Z_W-1:0] Z_FAR = {Z_W{1'b1}}
)(
    input  logic              clk,
    input  logic              rst_n,

    // Control
    input  logic              clear_zbuffer,
    output logic              clear_done,
    output logic              pipeline_stall,

    // From rasterizer (before shader)
    input  logic              raster_valid,
    input  logic [15:0]       raster_x,
    input  logic [15:0]       raster_y,
    input  logic [Z_W-1:0]    raster_z,

    // To pixel shader (only if Z passes)
    output logic              ez_valid,
    output logic [15:0]       ez_x,
    output logic [15:0]       ez_y,
    output logic [Z_W-1:0]    ez_z,

    // To late-Z / framebuffer (Z write happens here, color later)
    output logic              ez_z_write,
    output logic [ADDR_W-1:0] ez_z_addr,
    output logic [Z_W-1:0]    ez_z_wdata,

    // Stall from downstream
    input  logic              shader_stall
);

    // =====================================================================
    // Z-BUFFER MEMORY (read-modify-write for Early-Z)
    // =====================================================================
    (* ram_style = "block" *)
    logic [Z_W-1:0] z_buffer [0:FB_SIZE-1];

    // =====================================================================
    // CLEAR STATE MACHINE
    // =====================================================================
    typedef enum logic { IDLE = 1'b0, CLEAR = 1'b1 } state_t;
    state_t state;
    logic [ADDR_W-1:0] clear_addr;

    assign pipeline_stall = (state != IDLE);
    assign clear_done = clear_done_reg;

    logic clear_done_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            clear_addr <= '0;
            clear_done_reg <= 1'b0;
        end else begin
            clear_done_reg <= 1'b0;

            if (clear_zbuffer) begin
                state <= CLEAR;
                clear_addr <= '0;
            end else if (state == CLEAR) begin
                z_buffer[clear_addr] <= Z_FAR;
                if (clear_addr < FB_SIZE - 1) begin
                    clear_addr <= clear_addr + 1'b1;
                end else begin
                    state <= IDLE;
                    clear_done_reg <= 1'b1;
                end
            end
        end
    end

    // =====================================================================
    // 3-STAGE EARLY-Z PIPELINE
    // =====================================================================

    // Stage 1: Address calc + bounds check
    logic        s1_valid;
    logic [ADDR_W-1:0] s1_addr;
    logic [15:0] s1_x, s1_y;
    logic [Z_W-1:0] s1_z;

    logic addr_in_bounds;
    assign addr_in_bounds = (raster_x < SCREEN_WIDTH) && (raster_y < SCREEN_HEIGHT);

    always_ff @(posedge clk) begin
        if (state == IDLE && !shader_stall) begin
            s1_valid <= raster_valid && addr_in_bounds;
            if (raster_valid && addr_in_bounds) begin
                s1_addr <= (raster_y * SCREEN_WIDTH) + raster_x;
                s1_x <= raster_x;
                s1_y <= raster_y;
                s1_z <= raster_z;
            end
        end else begin
            s1_valid <= 1'b0;
        end
    end

    // Stage 2: Read Z from buffer
    logic        s2_valid;
    logic [ADDR_W-1:0] s2_addr;
    logic [15:0] s2_x, s2_y;
    logic [Z_W-1:0] s2_z;
    logic [Z_W-1:0] z_old;

    always_ff @(posedge clk) begin
        s2_valid <= s1_valid;
        s2_addr <= s1_addr;
        s2_x <= s1_x;
        s2_y <= s1_y;
        s2_z <= s1_z;

        if (s1_valid) begin
            z_old <= z_buffer[s1_addr];
        end
    end

    // Stage 3: Z comparison + write if closer
    logic s2_z_pass;

    assign s2_z_pass = (s2_z < z_old);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ez_valid <= 1'b0;
            ez_x <= '0;
            ez_y <= '0;
            ez_z <= '0;
            ez_z_write <= 1'b0;
            ez_z_addr <= '0;
            ez_z_wdata <= '0;
        end else begin
            ez_valid <= s2_valid && s2_z_pass;
            ez_x <= s2_x;
            ez_y <= s2_y;
            ez_z <= s2_z;

            // Write Z immediately (before shader runs)
            // This prevents later fragments from passing if they overlap
            ez_z_write <= s2_valid && s2_z_pass;
            ez_z_addr <= s2_addr;
            ez_z_wdata <= s2_z;

            if (s2_valid && s2_z_pass) begin
                z_buffer[s2_addr] <= s2_z;
            end
        end
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Safety: ez_valid implies Z passed
    property p_valid_implies_pass;
        @(posedge clk) disable iff (!rst_n)
        ez_valid |-> $past(s2_z_pass);
    endproperty
    a_valid_implies_pass: assert property (p_valid_implies_pass);

    // Safety: Z-write only on pass
    property p_write_on_pass;
        @(posedge clk) disable iff (!rst_n)
        ez_z_write |-> $past(s2_z_pass);
    endproperty
    a_write_on_pass: assert property (p_write_on_pass);

    // Safety: no Z-write during clear
    property p_no_write_in_clear;
        @(posedge clk) disable iff (!rst_n)
        (state == CLEAR) |-> !ez_z_write;
    endproperty
    a_no_write_in_clear: assert property (p_no_write_in_clear);

endmodule
