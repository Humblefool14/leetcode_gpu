`timescale 1ns / 1ps

module output_merger #(
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480,
    parameter int FB_SIZE       = SCREEN_WIDTH * SCREEN_HEIGHT,
    parameter int ADDR_W        = $clog2(FB_SIZE),      // 19
    parameter int DATA_W        = 24,                   // RGB888
    parameter int Z_W           = 16,                   // Depth width
    parameter logic [Z_W-1:0] Z_FAR = {Z_W{1'b1}}     // Max depth = far away
)(
    input  logic              clk,
    input  logic              rst_n,

    // Control
    input  logic              clear_zbuffer,
    output logic              clear_done,
    output logic              pipeline_stall,           // Back-pressure to upstream

    // Pixel Shader input
    input  logic              ps_valid,
    input  logic [15:0]       ps_x,
    input  logic [15:0]       ps_y,
    input  logic [DATA_W-1:0] ps_color,
    input  logic [Z_W-1:0]    ps_z,

    // Framebuffer output
    output logic              fb_we,
    output logic [ADDR_W-1:0] fb_addr,
    output logic [DATA_W-1:0] fb_wdata
);

    // -----------------------------------------------------------------
    // Z-Buffer Memory (inferred dual-port BRAM)
    // Port A: RMW pipeline (read + write)
    // Port B: Clear sweep (write only)
    // -----------------------------------------------------------------
    (* ram_style = "block" *)
    logic [Z_W-1:0] z_buffer [0:FB_SIZE-1];

    // -----------------------------------------------------------------
    // State Machine
    // -----------------------------------------------------------------
    typedef enum logic { IDLE = 1'b0, CLEAR = 1'b1 } state_t;
    state_t state, next_state;

    logic [ADDR_W-1:0] clear_addr;
    logic              clear_done_reg;

    // -----------------------------------------------------------------
    // Address & Bounds Checking
    // -----------------------------------------------------------------
    logic [ADDR_W-1:0] calc_addr;
    logic              addr_in_bounds;

    assign calc_addr     = (ps_y * SCREEN_WIDTH) + ps_x;
    assign addr_in_bounds = (ps_x < SCREEN_WIDTH) && (ps_y < SCREEN_HEIGHT);

    // -----------------------------------------------------------------
    // 3-Stage RMW Pipeline Registers
    // -----------------------------------------------------------------
    // Stage 1: Address calc + read trigger
    logic        s1_valid;
    logic [ADDR_W-1:0] s1_addr;
    logic [DATA_W-1:0] s1_color;
    logic [Z_W-1:0]    s1_z;

    // Stage 2: Read data latch
    logic        s2_valid;
    logic [ADDR_W-1:0] s2_addr;
    logic [DATA_W-1:0] s2_color;
    logic [Z_W-1:0]    s2_z;
    logic [Z_W-1:0]    z_old;

    // -----------------------------------------------------------------
    // State Machine (registered)
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE:  if (clear_zbuffer) next_state = CLEAR;
            CLEAR: if (clear_addr == FB_SIZE - 1) next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    // -----------------------------------------------------------------
    // Pipeline Stall & Clear Done
    // -----------------------------------------------------------------
    assign pipeline_stall = (state != IDLE) || clear_zbuffer;
    assign clear_done     = clear_done_reg;

    // -----------------------------------------------------------------
    // Main Sequential Logic
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clear_addr   <= '0;
            clear_done_reg <= 1'b0;

            s1_valid <= 1'b0;
            s2_valid <= 1'b0;

            fb_we    <= 1'b0;
            fb_addr  <= '0;
            fb_wdata <= '0;
        end else begin
            // Defaults
            fb_we          <= 1'b0;
            clear_done_reg <= 1'b0;

            // --- Clear Logic ---
            if (state == CLEAR) begin
                z_buffer[clear_addr] <= Z_FAR;

                if (clear_addr < FB_SIZE - 1) begin
                    clear_addr <= clear_addr + 1'b1;
                end else begin
                    clear_addr     <= '0;
                    clear_done_reg <= 1'b1;
                end
            end

            // --- RMW Pipeline (only when IDLE and not being asked to clear) ---
            if (state == IDLE && !clear_zbuffer) begin

                // Stage 1: Latch input, bounds check
                s1_valid <= ps_valid && addr_in_bounds;
                if (ps_valid && addr_in_bounds) begin
                    s1_addr  <= calc_addr;
                    s1_color <= ps_color;
                    s1_z     <= ps_z;
                end

                // Stage 2: BRAM read latency
                s2_valid <= s1_valid;
                if (s1_valid) begin
                    s2_addr  <= s1_addr;
                    s2_color <= s1_color;
                    s2_z     <= s1_z;
                    z_old    <= z_buffer[s1_addr];
                end

                // Stage 3: Z-test + write
                if (s2_valid) begin
                    if (s2_z < z_old) begin
                        z_buffer[s2_addr] <= s2_z;
                        fb_we    <= 1'b1;
                        fb_addr  <= s2_addr;
                        fb_wdata <= s2_color;
                    end
                end
            end else begin
                // Stall: flush pipeline
                s1_valid <= 1'b0;
                s2_valid <= 1'b0;
            end
        end
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Safety: fb_we implies s2_valid was high 1 cycle ago
    property p_write_follows_valid;
        @(posedge clk) disable iff (!rst_n)
        fb_we |-> $past(s2_valid);
    endproperty
    a_write_follows_valid: assert property (p_write_follows_valid);

    // Safety: clear_done is single-cycle pulse
    property p_clear_done_pulse;
        @(posedge clk) disable iff (!rst_n)
        clear_done |=> !clear_done;
    endproperty
    a_clear_done_pulse: assert property (p_clear_done_pulse);

    // Safety: no framebuffer write during CLEAR
    property p_no_write_during_clear;
        @(posedge clk) disable iff (!rst_n)
        (state == CLEAR) |-> !fb_we;
    endproperty
    a_no_write_during_clear: assert property (p_no_write_during_clear);

    // Safety: stall implies no new work accepted
    property p_stall_blocks_input;
        @(posedge clk) disable iff (!rst_n)
        pipeline_stall |=> !s1_valid;
    endproperty
    a_stall_blocks_input: assert property (p_stall_blocks_input);

    // Safety: addresses always in bounds when valid
    property p_addr_in_bounds;
        @(posedge clk) disable iff (!rst_n)
        (s1_valid || s2_valid || fb_we) |-> (fb_addr < FB_SIZE);
    endproperty
    a_addr_in_bounds: assert property (p_addr_in_bounds);

    // Safety: Z-buffer write only when IDLE
    property p_zwrite_only_idle;
        @(posedge clk) disable iff (!rst_n)
        $changed(z_buffer[s2_addr]) |-> (state == IDLE);
    endproperty
    a_zwrite_only_idle: assert property (p_zwrite_only_idle);

`ifdef FPV
    // Liveness: clear_zbuffer eventually produces clear_done
    property p_clear_finishes;
        @(posedge clk) disable iff (!rst_n)
        clear_zbuffer |=> s_eventually clear_done;
    endproperty
    a_clear_finishes: assert property (p_clear_finishes);

    // Liveness: valid pixel eventually produces write or drop (Z-fail)
    property p_pixel_resolves;
        @(posedge clk) disable iff (!rst_n)
        (ps_valid && addr_in_bounds && !pipeline_stall)
        |=> s_eventually (fb_we || !s2_valid);
    endproperty
    a_pixel_resolves: assert property (p_pixel_resolves);

    // Coverage: Z-test pass
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (s2_valid && (s2_z < z_old) && fb_we)
    );

    // Coverage: Z-test fail
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (s2_valid && (s2_z >= z_old) && !fb_we)
    );

    // Coverage: out-of-bounds drop
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (ps_valid && !addr_in_bounds && !s1_valid)
    );
`endif

endmodule
