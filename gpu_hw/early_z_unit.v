`timescale 1ns / 1ps

module early_z_unit #(
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480,
    parameter int FB_SIZE       = SCREEN_WIDTH * SCREEN_HEIGHT,
    parameter int ADDR_W        = $clog2(FB_SIZE),
    parameter int Z_W           = 16,
    parameter int GEN_W         = 8,      // generation tag width — see clear note
    parameter int DRAIN_CYCLES  = 4       // pipeline flush window around a clear pulse
)(
    input  logic              clk,
    input  logic              rst_n,

    // Control
    input  logic              clear_zbuffer,    // single-cycle pulse: "start new frame"
    output logic              clear_done,       // pulses when the drain window ends
    output logic              pipeline_stall,

    // Depth test configuration
    input  logic [2:0]        depth_func_i,     // see depth_func_e below
    input  logic              z_write_enable_i, // depth-mask: 0 = pass through, never write Z

    // From rasterizer (before shader)
    input  logic              raster_valid,
    input  logic [15:0]       raster_x,
    input  logic [15:0]       raster_y,
    input  logic [Z_W-1:0]    raster_z,

    // To pixel shader (only if Z test passes)
    output logic              ez_valid,
    output logic [15:0]       ez_x,
    output logic [15:0]       ez_y,
    output logic [Z_W-1:0]    ez_z,

    // To framebuffer / late-Z (Z write happens here, color later)
    output logic              ez_z_write,
    output logic [ADDR_W-1:0] ez_z_addr,
    output logic [Z_W-1:0]    ez_z_wdata,

    // Stall from downstream
    input  logic              shader_stall
);

    // =====================================================================
    // DEPTH FUNCTION
    // =====================================================================
    typedef enum logic [2:0] {
        DF_NEVER    = 3'b000,
        DF_LESS     = 3'b001,
        DF_EQUAL    = 3'b010,
        DF_LEQUAL   = 3'b011,
        DF_GREATER  = 3'b100,
        DF_NOTEQUAL = 3'b101,
        DF_GEQUAL   = 3'b110,
        DF_ALWAYS   = 3'b111
    } depth_func_e;

    function automatic logic depth_compare(
        input logic [Z_W-1:0] new_z,
        input logic [Z_W-1:0] old_z,
        input logic [2:0]     func
    );
        case (func)
            DF_NEVER:    depth_compare = 1'b0;
            DF_LESS:     depth_compare = (new_z <  old_z);
            DF_EQUAL:    depth_compare = (new_z == old_z);
            DF_LEQUAL:   depth_compare = (new_z <= old_z);
            DF_GREATER:  depth_compare = (new_z >  old_z);
            DF_NOTEQUAL: depth_compare = (new_z != old_z);
            DF_GEQUAL:   depth_compare = (new_z >= old_z);
            DF_ALWAYS:   depth_compare = 1'b1;
            default:     depth_compare = 1'b0;
        endcase
    endfunction

    // =====================================================================
    // Z-BUFFER — single write port (stage 3 only). "Clear" never touches
    // this array; see the generation scheme below.
    // =====================================================================
    typedef struct packed {
        logic [GEN_W-1:0] gen;
        logic [Z_W-1:0]   z;
    } zentry_t;

    (* ram_style = "block" *)
    zentry_t z_buffer [0:FB_SIZE-1];

    // Power-up note: this relies on memory initializing with gen == '0
    // (true for FPGA BRAM with an initial block / .mem file). current_gen
    // resets to 1, so every location's power-on gen==0 reads as stale on
    // frame 1 — no sweep needed even for the very first frame. On an ASIC
    // flow with undefined power-on memory state you still need one real
    // init pass (or a POR-time guarantee) before trusting this.

    // =====================================================================
    // GENERATION-TAG FAST CLEAR
    // =====================================================================
    // Old design swept FB_SIZE addresses per clear — 307,200 cycles for
    // 640x480, ~18% of a 60fps frame budget spent writing Z_FAR. Here a
    // clear just bumps a counter; any entry whose stored tag doesn't match
    // current_gen is treated as if it held Z_FAR. Cost drops from
    // O(FB_SIZE) to O(pipeline depth).
    //
    // Trade-off: GEN_W is finite. A pixel untouched for 2^GEN_W clears in
    // a row wraps around and reads as "valid" with stale data. At GEN_W=8
    // that's 256 frames between touches on the same pixel — fine for
    // anything that redraws every frame, a real risk for a background
    // pixel that's genuinely never touched again. Widen GEN_W or force one
    // real sweep every 2^GEN_W clears if that matters for your workload.

    logic [GEN_W-1:0] current_gen;

    logic clear_zbuffer_prev, clear_start_pulse;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) clear_zbuffer_prev <= 1'b0;
        else        clear_zbuffer_prev <= clear_zbuffer;
    end
    assign clear_start_pulse = clear_zbuffer && !clear_zbuffer_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    current_gen <= {{(GEN_W-1){1'b0}}, 1'b1};
        else if (clear_start_pulse)    current_gen <= current_gen + 1'b1;
    end

    // =====================================================================
    // DRAIN WINDOW  — this is the actual bug fix
    // =====================================================================
    // 'draining' is COMBINATIONAL on clear_start_pulse (not a registered
    // flag that lags it by a cycle). That's the fix: previously s2 was
    // squashed by a version of 'draining' that only went high the cycle
    // AFTER the pulse, so a fragment already latched into s1 at the pulse
    // edge rode into s2 unsquashed and could commit a write a cycle later.
    // Gating s2's squash on the SAME combinational signal that gates s1
    // closes that gap — both are squashed on the pulse edge itself.
    localparam int DCW = $clog2(DRAIN_CYCLES + 1);
    logic [DCW-1:0] drain_cnt;
    logic           draining;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     drain_cnt <= '0;
        else if (clear_start_pulse)     drain_cnt <= DCW'(DRAIN_CYCLES);
        else if (drain_cnt != '0)       drain_cnt <= drain_cnt - 1'b1;
    end
    assign draining = (drain_cnt != '0) || clear_start_pulse;

    assign pipeline_stall = draining || shader_stall;
    assign clear_done     = (drain_cnt == DCW'(1));

    // =====================================================================
    // STAGE 1 — address calc + bounds check
    // =====================================================================
    logic              s1_valid;
    logic [ADDR_W-1:0] s1_addr;
    logic [15:0]       s1_x, s1_y;
    logic [Z_W-1:0]    s1_z;

    logic addr_in_bounds;
    assign addr_in_bounds = (raster_x < SCREEN_WIDTH) && (raster_y < SCREEN_HEIGHT);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_addr <= '0; s1_x <= '0; s1_y <= '0; s1_z <= '0;
        end else if (draining) begin
            s1_valid <= 1'b0;
        end else if (!shader_stall) begin
            s1_valid <= raster_valid && addr_in_bounds;
            if (raster_valid && addr_in_bounds) begin
                s1_addr <= (raster_y * SCREEN_WIDTH) + raster_x;
                s1_x    <= raster_x;
                s1_y    <= raster_y;
                s1_z    <= raster_z;
            end
        end
        // else: shader_stall -> freeze
    end

    // =====================================================================
    // STAGE 2 — read Z + generation tag, with same-cycle RAW forwarding
    // =====================================================================
    logic              s2_valid;
    logic [ADDR_W-1:0] s2_addr;
    logic [15:0]       s2_x, s2_y;
    logic [Z_W-1:0]    s2_z;
    logic [Z_W-1:0]    z_old;
    logic              z_old_valid;   // gen matched -> real compare, else treat as far

    logic              s3_commit_valid;
    logic [ADDR_W-1:0] s3_commit_addr;
    logic [Z_W-1:0]    s3_commit_z;

    logic z_read_raw_hit;
    assign z_read_raw_hit = s3_commit_valid && (s3_commit_addr == s1_addr);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_addr <= '0; s2_x <= '0; s2_y <= '0; s2_z <= '0;
            z_old <= '0; z_old_valid <= 1'b0;
        end else if (draining) begin
            s2_valid <= 1'b0;                     // <-- the fix: same-edge squash
        end else if (!shader_stall) begin
            s2_valid <= s1_valid;
            s2_addr  <= s1_addr;
            s2_x     <= s1_x;
            s2_y     <= s1_y;
            s2_z     <= s1_z;

            if (s1_valid) begin
                if (z_read_raw_hit) begin
                    z_old       <= s3_commit_z;
                    z_old_valid <= 1'b1;
                end else begin
                    z_old       <= z_buffer[s1_addr].z;
                    z_old_valid <= (z_buffer[s1_addr].gen == current_gen);
                end
            end
        end
    end

    // =====================================================================
    // STAGE 3 — depth test, single write port
    // =====================================================================
    logic s2_pass;
    assign s2_pass = s2_valid &&
                      (!z_old_valid || depth_compare(s2_z, z_old, depth_func_i));

    logic s2_do_write;
    assign s2_do_write = s2_pass && z_write_enable_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ez_valid <= 1'b0; ez_x <= '0; ez_y <= '0; ez_z <= '0;
            ez_z_write <= 1'b0; ez_z_addr <= '0; ez_z_wdata <= '0;
            s3_commit_valid <= 1'b0; s3_commit_addr <= '0; s3_commit_z <= '0;
        end else if (!shader_stall) begin
            ez_valid <= s2_pass;
            ez_x     <= s2_x;
            ez_y     <= s2_y;
            ez_z     <= s2_z;

            ez_z_write <= s2_do_write;
            ez_z_addr  <= s2_addr;
            ez_z_wdata <= s2_z;

            if (s2_do_write) begin
                z_buffer[s2_addr] <= '{gen: current_gen, z: s2_z};   // only writer, period
            end

            s3_commit_valid <= s2_do_write;
            s3_commit_addr  <= s2_addr;
            s3_commit_z     <= s2_z;
        end
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================
    property p_valid_implies_pass;
        @(posedge clk) disable iff (!rst_n)
        ez_valid |-> $past(s2_pass);
    endproperty
    a_valid_implies_pass: assert property (p_valid_implies_pass);

    property p_write_on_pass;
        @(posedge clk) disable iff (!rst_n)
        ez_z_write |-> $past(s2_do_write);
    endproperty
    a_write_on_pass: assert property (p_write_on_pass);

    // Direct regression test for the reported bug: nothing may be accepted
    // into s1 on the same edge draining is asserted, or any cycle after.
    property p_no_accept_during_drain;
        @(posedge clk) disable iff (!rst_n)
        draining |-> !s1_valid;
    endproperty
    a_no_accept_during_drain: assert property (p_no_accept_during_drain);

    property p_raw_bypass_correct;
        @(posedge clk) disable iff (!rst_n)
        (s1_valid && z_read_raw_hit) |=> (z_old == $past(s3_commit_z));
    endproperty
    a_raw_bypass_correct: assert property (p_raw_bypass_correct);

endmodule
