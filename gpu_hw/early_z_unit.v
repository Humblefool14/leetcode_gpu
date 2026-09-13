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
    input  logic              clear_zbuffer,   // expected as a single-cycle pulse
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
    logic clear_done_reg;

    // Edge-detect clear_zbuffer so a caller holding it high doesn't restart
    // the clear sweep every cycle.
    logic clear_zbuffer_prev, clear_start_pulse;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) clear_zbuffer_prev <= 1'b0;
        else        clear_zbuffer_prev <= clear_zbuffer;
    end
    assign clear_start_pulse = clear_zbuffer && !clear_zbuffer_prev;

    assign pipeline_stall = (state != IDLE) || shader_stall;
    assign clear_done     = clear_done_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            clear_addr     <= '0;
            clear_done_reg <= 1'b0;
        end else begin
            clear_done_reg <= 1'b0;

            if (clear_start_pulse) begin
                state      <= CLEAR;
                clear_addr <= '0;
            end else if (state == CLEAR) begin
                z_buffer[clear_addr] <= Z_FAR;
                if (clear_addr < FB_SIZE - 1) begin
                    clear_addr <= clear_addr + 1'b1;
                end else begin
                    state          <= IDLE;
                    clear_done_reg <= 1'b1;
                end
            end
        end
    end

    // Drain-squash: kill anything already in flight the cycle a clear starts,
    // and for one cycle after (covers both s1 and s2 latches).
    logic draining;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    draining <= 1'b0;
        else if (clear_start_pulse)    draining <= 1'b1;
        else                           draining <= 1'b0;
    end

    // =====================================================================
    // 3-STAGE EARLY-Z PIPELINE
    // =====================================================================

    // Stage 1: Address calc + bounds check
    logic              s1_valid;
    logic [ADDR_W-1:0] s1_addr;
    logic [15:0]       s1_x, s1_y;
    logic [Z_W-1:0]    s1_z;

    logic addr_in_bounds;
    assign addr_in_bounds = (raster_x < SCREEN_WIDTH) && (raster_y < SCREEN_HEIGHT);

    // Accept new work only when: not clearing, not mid-clear-start, and
    // downstream isn't stalled. On stall we freeze (hold current s1
    // contents) rather than squash, so nothing already valid is dropped.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_addr  <= '0;
            s1_x     <= '0;
            s1_y     <= '0;
            s1_z     <= '0;
        end else if (state == IDLE && !clear_start_pulse && !draining) begin
            if (!shader_stall) begin
                s1_valid <= raster_valid && addr_in_bounds;
                if (raster_valid && addr_in_bounds) begin
                    s1_addr <= (raster_y * SCREEN_WIDTH) + raster_x;
                    s1_x    <= raster_x;
                    s1_y    <= raster_y;
                    s1_z    <= raster_z;
                end
            end
            // else: shader_stall high -> hold s1_* unchanged (freeze)
        end else begin
            // entering/inside clear or clear-start pulse: squash
            s1_valid <= 1'b0;
        end
    end

    // Stage 2: Read Z from buffer, with RAW bypass against the fragment
    // currently committing in stage 3 this same cycle.
    logic              s2_valid;
    logic [ADDR_W-1:0] s2_addr;
    logic [15:0]       s2_x, s2_y;
    logic [Z_W-1:0]    s2_z;
    logic [Z_W-1:0]    z_old;

    // Stage-3 commit info, declared here so stage 2 can see this cycle's
    // in-flight write for forwarding (see stage 3 below for the drivers).
    logic              s3_commit_valid;
    logic [ADDR_W-1:0] s3_commit_addr;
    logic [Z_W-1:0]    s3_commit_z;

    logic z_read_raw_hit;
    assign z_read_raw_hit = s3_commit_valid && (s3_commit_addr == s1_addr);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_addr  <= '0;
            s2_x     <= '0;
            s2_y     <= '0;
            s2_z     <= '0;
            z_old    <= '0;
        end else if (draining) begin
            // squash anything stage 1 handed us the cycle clear started
            s2_valid <= 1'b0;
        end else if (!shader_stall) begin
            s2_valid <= s1_valid;
            s2_addr  <= s1_addr;
            s2_x     <= s1_x;
            s2_y     <= s1_y;
            s2_z     <= s1_z;

            if (s1_valid) begin
                // Forward stage 3's in-flight write if it's the same address,
                // instead of reading stale (pre-write) memory contents.
                z_old <= z_read_raw_hit ? s3_commit_z : z_buffer[s1_addr];
            end
        end
        // else: shader_stall high -> hold s2_* unchanged (freeze)
    end

    // Stage 3: Z comparison + write if closer
    logic s2_z_pass;
    assign s2_z_pass = s2_valid && (s2_z < z_old);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ez_valid        <= 1'b0;
            ez_x            <= '0;
            ez_y            <= '0;
            ez_z            <= '0;
            ez_z_write      <= 1'b0;
            ez_z_addr       <= '0;
            ez_z_wdata      <= '0;
            s3_commit_valid <= 1'b0;
            s3_commit_addr  <= '0;
            s3_commit_z     <= '0;
        end else if (!shader_stall) begin
            ez_valid <= s2_z_pass;
            ez_x     <= s2_x;
            ez_y     <= s2_y;
            ez_z     <= s2_z;

            // Write Z immediately (before shader runs) so later fragments
            // to the same pixel see the update via the RAW bypass above.
            ez_z_write <= s2_z_pass;
            ez_z_addr  <= s2_addr;
            ez_z_wdata <= s2_z;

            if (s2_z_pass) begin
                z_buffer[s2_addr] <= s2_z;
            end

            // Publish this cycle's commit for stage 2's bypass mux next cycle.
            s3_commit_valid <= s2_z_pass;
            s3_commit_addr  <= s2_addr;
            s3_commit_z     <= s2_z;
        end
        // else: shader_stall high -> hold ez_*/commit_* unchanged (freeze),
        // and critically do NOT re-issue z_buffer write while frozen.
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    property p_valid_implies_pass;
        @(posedge clk) disable iff (!rst_n)
        ez_valid |-> $past(s2_z_pass);
    endproperty
    a_valid_implies_pass: assert property (p_valid_implies_pass);

    property p_write_on_pass;
        @(posedge clk) disable iff (!rst_n)
        ez_z_write |-> $past(s2_z_pass);
    endproperty
    a_write_on_pass: assert property (p_write_on_pass);

    property p_no_write_in_clear;
        @(posedge clk) disable iff (!rst_n)
        (state == CLEAR) |-> !ez_z_write;
    endproperty
    a_no_write_in_clear: assert property (p_no_write_in_clear);

    // New: no fragment accepted at stage 1 during clear or clear-start
    property p_no_accept_during_clear;
        @(posedge clk) disable iff (!rst_n)
        (state == CLEAR || draining) |-> !s1_valid;
    endproperty
    a_no_accept_during_clear: assert property (p_no_accept_during_clear);

    // New: RAW bypass correctness — if stage 2 reads the same address stage 3
    // is committing this cycle, z_old next cycle must equal the committed value.
    property p_raw_bypass_correct;
        @(posedge clk) disable iff (!rst_n)
        (s1_valid && z_read_raw_hit) |=> (z_old == $past(s3_commit_z));
    endproperty
    a_raw_bypass_correct: assert property (p_raw_bypass_correct);

endmodule
