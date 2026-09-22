`timescale 1ns / 1ps

module early_z_unit #(
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480,
    parameter int FB_SIZE       = SCREEN_WIDTH * SCREEN_HEIGHT,
    parameter int ADDR_W        = $clog2(FB_SIZE),
    parameter int Z_W           = 16,
    parameter int GEN_W         = 8,
    parameter int DRAIN_CYCLES  = 4,
    parameter int TILE_SIZE     = 8    // must be power of 2; must divide SCREEN_WIDTH/HEIGHT evenly
)(
    input  logic              clk,
    input  logic              rst_n,

    // Legacy direct trigger (kept for testbench / non-CSR use; ORed with CSR trigger)
    input  logic              clear_zbuffer,
    output logic              clear_done,
    output logic              pipeline_stall,

    // From rasterizer (before shader) — per pixel
    input  logic              raster_valid,
    input  logic [15:0]       raster_x,
    input  logic [15:0]       raster_y,
    input  logic [Z_W-1:0]    raster_z,

    // Coarse-stage HiZ query — one per candidate tile, before fine rasterization.
    // tile_x/tile_y are TILE-space coordinates (already divided by TILE_SIZE),
    // matching your Bin stage's output granularity.
    input  logic               tile_query_valid,
    input  logic [15:0]        tile_x,
    input  logic [15:0]        tile_y,
    input  logic [Z_W-1:0]     tile_z_lo,   // primitive's min Z within this tile
    input  logic [Z_W-1:0]     tile_z_hi,   // primitive's max Z within this tile
    output logic               tile_reject, // combinational, same-cycle as query

    // To pixel shader
    output logic              ez_valid,
    output logic [15:0]       ez_x,
    output logic [15:0]       ez_y,
    output logic [Z_W-1:0]    ez_z,

    // To framebuffer / late-Z
    output logic              ez_z_write,
    output logic [ADDR_W-1:0] ez_z_addr,
    output logic [Z_W-1:0]    ez_z_wdata,

    input  logic              shader_stall,

    // ============================================================
    // CSR bus — lightweight single-cycle synchronous register file.
    // Word-addressed (csr_addr steps by 4, byte address).
    // ============================================================
    input  logic               csr_valid,
    input  logic               csr_we,
    input  logic [7:0]         csr_addr,
    input  logic [31:0]        csr_wdata,
    output logic [31:0]        csr_rdata,
    output logic               csr_ready,
    output logic               irq_o
);

    // =====================================================================
    // DEPTH FUNCTION
    // =====================================================================
    typedef enum logic [2:0] {
        DF_NEVER    = 3'b000, DF_LESS     = 3'b001,
        DF_EQUAL    = 3'b010, DF_LEQUAL   = 3'b011,
        DF_GREATER  = 3'b100, DF_NOTEQUAL = 3'b101,
        DF_GEQUAL   = 3'b110, DF_ALWAYS   = 3'b111
    } depth_func_e;

    function automatic logic depth_compare(
        input logic [Z_W-1:0] new_z, input logic [Z_W-1:0] old_z, input logic [2:0] func
    );
        case (func)
            DF_NEVER: depth_compare = 1'b0;  DF_LESS:     depth_compare = (new_z <  old_z);
            DF_EQUAL: depth_compare = (new_z == old_z); DF_LEQUAL:   depth_compare = (new_z <= old_z);
            DF_GREATER: depth_compare = (new_z > old_z); DF_NOTEQUAL: depth_compare = (new_z != old_z);
            DF_GEQUAL: depth_compare = (new_z >= old_z); DF_ALWAYS:   depth_compare = 1'b1;
            default:  depth_compare = 1'b0;
        endcase
    endfunction

    function automatic logic is_less_family(input logic [2:0] f);
        is_less_family = (f == DF_LESS) || (f == DF_LEQUAL);
    endfunction
    function automatic logic is_greater_family(input logic [2:0] f);
        is_greater_family = (f == DF_GREATER) || (f == DF_GEQUAL);
    endfunction

    // =====================================================================
    // TILE GEOMETRY
    // =====================================================================
    localparam int TILES_X     = SCREEN_WIDTH  / TILE_SIZE;
    localparam int TILES_Y     = SCREEN_HEIGHT / TILE_SIZE;
    localparam int TILE_COUNT  = TILES_X * TILES_Y;
    localparam int TILE_ADDR_W = $clog2(TILE_COUNT);
    localparam int TS_SHIFT    = $clog2(TILE_SIZE);

    // =====================================================================
    // CONFIG REGISTERS (CSR-backed — see CSR block at bottom)
    // =====================================================================
    logic [2:0] cfg_depth_func;
    logic       cfg_z_write_enable;
    logic       cfg_early_z_disable;
    logic       csr_clear_trigger;      // one-cycle pulse from CTRL.start_clear

    // =====================================================================
    // Z-BUFFER + HIZ BUFFER — generation-tagged, single writer each
    // =====================================================================
    typedef struct packed { logic [GEN_W-1:0] gen; logic [Z_W-1:0] z; } zentry_t;

    (* ram_style = "block" *) zentry_t z_buffer   [0:FB_SIZE-1];
    (* ram_style = "block" *) zentry_t hiz_buffer [0:TILE_COUNT-1];
    // Power-up note (unchanged from before): relies on BRAM init'ing gen==0,
    // which reads as stale against current_gen==1 on frame 1. ASIC flows
    // without a guaranteed power-on memory state need one real init pass.

    logic [GEN_W-1:0] current_gen;

    logic clear_zbuffer_prev, clear_start_pulse;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) clear_zbuffer_prev <= 1'b0;
        else        clear_zbuffer_prev <= (clear_zbuffer || csr_clear_trigger);
    end
    assign clear_start_pulse = (clear_zbuffer || csr_clear_trigger) && !clear_zbuffer_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                 current_gen <= {{(GEN_W-1){1'b0}}, 1'b1};
        else if (clear_start_pulse) current_gen <= current_gen + 1'b1;
    end

    // =====================================================================
    // DRAIN WINDOW — combinational on the pulse, gates s1 AND s2 same edge
    // =====================================================================
    localparam int DCW = $clog2(DRAIN_CYCLES + 1);
    logic [DCW-1:0] drain_cnt;
    logic           draining;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  drain_cnt <= '0;
        else if (clear_start_pulse)  drain_cnt <= DCW'(DRAIN_CYCLES);
        else if (drain_cnt != '0)    drain_cnt <= drain_cnt - 1'b1;
    end
    assign draining       = (drain_cnt != '0) || clear_start_pulse;
    assign pipeline_stall = draining || shader_stall;
    assign clear_done     = (drain_cnt == DCW'(1));

    // =====================================================================
    // HIZ QUERY — coarse-stage tile occlusion test, combinational
    // =====================================================================
    zentry_t hiz_entry;
    logic    hiz_stale, hiz_dir_supported;
    logic [TILE_ADDR_W-1:0] tile_addr_q;

    assign tile_addr_q = tile_y[TILE_ADDR_W-1:0] * TILES_X[TILE_ADDR_W-1:0] + tile_x[TILE_ADDR_W-1:0]; // caller must bound-check tile_x/y
    assign hiz_entry    = hiz_buffer[tile_addr_q];
    assign hiz_stale     = (hiz_entry.gen != current_gen);
    assign hiz_dir_supported = is_less_family(cfg_depth_func) || is_greater_family(cfg_depth_func);

    always_comb begin
        tile_reject = 1'b0;
        if (tile_query_valid && hiz_dir_supported && !hiz_stale) begin
            if (is_less_family(cfg_depth_func))
                tile_reject = (tile_z_lo > hiz_entry.z); // conservative: primitive's nearest point still behind everything recorded
            else
                tile_reject = (tile_z_hi < hiz_entry.z); // greater-is-closer: primitive's best point still worse than worst recorded
        end
    end
    // Assumption, not enforced in hardware: cfg_depth_func stays within the
    // same monotonic family (LESS/LEQUAL or GREATER/GEQUAL) between clears.
    // Switching families mid-frame without a clear leaves hiz_buffer holding
    // a max under one convention that gets misread as a min under the other
    // — silently wrong culling, not a crash. Driver contract, not a hardware guard.

    // =====================================================================
    // STAGE 1
    // =====================================================================
    logic s1_valid; logic [ADDR_W-1:0] s1_addr; logic [15:0] s1_x, s1_y; logic [Z_W-1:0] s1_z;
    logic addr_in_bounds;
    assign addr_in_bounds = (raster_x < SCREEN_WIDTH) && (raster_y < SCREEN_HEIGHT);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0; s1_addr <= '0; s1_x <= '0; s1_y <= '0; s1_z <= '0;
        end else if (draining) begin
            s1_valid <= 1'b0;
        end else if (!shader_stall) begin
            s1_valid <= raster_valid && addr_in_bounds;
            if (raster_valid && addr_in_bounds) begin
                s1_addr <= (raster_y * SCREEN_WIDTH) + raster_x;
                s1_x <= raster_x; s1_y <= raster_y; s1_z <= raster_z;
            end
        end
    end

    // =====================================================================
    // STAGE 2 — read + RAW forwarding (unchanged logic from prior fix)
    // =====================================================================
    logic s2_valid; logic [ADDR_W-1:0] s2_addr; logic [15:0] s2_x, s2_y; logic [Z_W-1:0] s2_z;
    logic [Z_W-1:0] z_old; logic z_old_valid;
    logic s3_commit_valid; logic [ADDR_W-1:0] s3_commit_addr; logic [Z_W-1:0] s3_commit_z;

    logic z_read_raw_hit;
    assign z_read_raw_hit = s1_valid && s3_commit_valid && (s3_commit_addr == s1_addr);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0; s2_addr <= '0; s2_x <= '0; s2_y <= '0; s2_z <= '0;
            z_old <= '0; z_old_valid <= 1'b0;
        end else if (draining) begin
            s2_valid <= 1'b0;
        end else if (!shader_stall) begin
            s2_valid <= s1_valid; s2_addr <= s1_addr; s2_x <= s1_x; s2_y <= s1_y; s2_z <= s1_z;
            if (s1_valid) begin
                if (z_read_raw_hit) begin
                    z_old <= s3_commit_z; z_old_valid <= 1'b1;
                end else begin
                    z_old <= z_buffer[s1_addr].z;
                    z_old_valid <= (z_buffer[s1_addr].gen == current_gen);
                end
            end
        end
    end

    // =====================================================================
    // STAGE 3 — depth test, single write port each for z_buffer + hiz_buffer
    // =====================================================================
    logic s2_pass, s2_do_write;
    assign s2_pass = s2_valid &&
                      (cfg_early_z_disable || !z_old_valid ||
                       depth_compare(s2_z, z_old, cfg_depth_func));
    assign s2_do_write = s2_pass && cfg_z_write_enable && !cfg_early_z_disable;
    // early_z_disable forces s2_do_write low unconditionally: this draw's
    // fragments always reach the shader (s2_pass forced true) but never
    // speculatively commit Z or update HiZ — true depth write is deferred
    // to a late-Z stage downstream that isn't part of this module.

    logic [TILE_ADDR_W-1:0] s2_tile_addr;
    assign s2_tile_addr = (s2_y[15:TS_SHIFT]) * TILES_X[TILE_ADDR_W-1:0] + s2_x[15:TS_SHIFT];

    // Occlusion counters
    logic [31:0] occ_total, occ_pass, occ_tile_reject;
    logic        cnt_reset;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ez_valid <= 1'b0; ez_x <= '0; ez_y <= '0; ez_z <= '0;
            ez_z_write <= 1'b0; ez_z_addr <= '0; ez_z_wdata <= '0;
            s3_commit_valid <= 1'b0; s3_commit_addr <= '0; s3_commit_z <= '0;
            occ_total <= '0; occ_pass <= '0; occ_tile_reject <= '0;
        end else if (!shader_stall) begin
            ez_valid <= s2_pass; ez_x <= s2_x; ez_y <= s2_y; ez_z <= s2_z;
            ez_z_write <= s2_do_write; ez_z_addr <= s2_addr; ez_z_wdata <= s2_z;

            if (s2_do_write) begin
                z_buffer[s2_addr] <= '{gen: current_gen, z: s2_z};

                if (hiz_buffer[s2_tile_addr].gen != current_gen) begin
                    hiz_buffer[s2_tile_addr] <= '{gen: current_gen, z: s2_z};       // seed this frame's tile entry
                end else if (is_less_family(cfg_depth_func)) begin
                    if (s2_z > hiz_buffer[s2_tile_addr].z) hiz_buffer[s2_tile_addr].z <= s2_z;
                end else if (is_greater_family(cfg_depth_func)) begin
                    if (s2_z < hiz_buffer[s2_tile_addr].z) hiz_buffer[s2_tile_addr].z <= s2_z;
                end
            end

            s3_commit_valid <= s2_do_write; s3_commit_addr <= s2_addr; s3_commit_z <= s2_z;

            if (cnt_reset) begin
                occ_total <= '0; occ_pass <= '0; occ_tile_reject <= '0;
            end else begin
                if (s2_valid) occ_total <= occ_total + 1'b1;
                if (s2_pass)  occ_pass  <= occ_pass  + 1'b1;
            end
        end
    end

    // Tile-reject counter — independent clock domain of concern (combinational
    // query port, not gated by shader_stall), counted separately.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // occ_tile_reject already cleared above on reset
        end else if (cnt_reset) begin
            // handled in the block above on the same cycle; nothing to do here
        end else if (tile_query_valid && tile_reject) begin
            occ_tile_reject <= occ_tile_reject + 1'b1;
        end
    end

    // =====================================================================
    // CSR BLOCK
    // =====================================================================
    localparam bit [7:0] A_CTRL    = 8'h00;
    localparam bit [7:0] A_STATUS  = 8'h04;
    localparam bit [7:0] A_OCC_TOT = 8'h08;
    localparam bit [7:0] A_OCC_PSS = 8'h0C;
    localparam bit [7:0] A_OCC_REJ = 8'h10;
    localparam bit [7:0] A_IRQ_EN  = 8'h14;
    localparam bit [7:0] A_IRQ_ST  = 8'h18;
    localparam bit [7:0] A_HIZ_INF = 8'h1C;

    logic irq_enable, irq_status_pend, clear_done_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_depth_func      <= DF_LESS;
            cfg_z_write_enable  <= 1'b1;
            cfg_early_z_disable <= 1'b0;
            csr_clear_trigger   <= 1'b0;
            cnt_reset           <= 1'b0;
            irq_enable          <= 1'b0;
            irq_status_pend     <= 1'b0;
            clear_done_prev     <= 1'b0;
        end else begin
            csr_clear_trigger <= 1'b0;   // one-cycle pulse, default low
            cnt_reset         <= 1'b0;

            if (csr_valid && csr_we) begin
                case (csr_addr)
                    A_CTRL: begin
                        csr_clear_trigger   <= csr_wdata[0];
                        cfg_early_z_disable <= csr_wdata[1];
                        cfg_depth_func      <= csr_wdata[4:2];
                        cfg_z_write_enable  <= csr_wdata[5];
                        cnt_reset           <= csr_wdata[6];
                    end
                    A_IRQ_EN: irq_enable <= csr_wdata[0];
                    A_IRQ_ST: if (csr_wdata[0]) irq_status_pend <= 1'b0;  // W1C
                    default: ;
                endcase
            end

            // clear_done rising edge latches an IRQ pending bit
            clear_done_prev <= clear_done;
            if (clear_done && !clear_done_prev) irq_status_pend <= 1'b1;
        end
    end

    assign irq_o = irq_enable && irq_status_pend;

    always_comb begin
        csr_rdata = 32'h0;
        case (csr_addr)
            A_CTRL:    csr_rdata = {25'h0, cnt_reset, cfg_z_write_enable, cfg_depth_func, cfg_early_z_disable, 1'b0};
            A_STATUS:  csr_rdata = {30'h0, pipeline_stall, clear_done};
            A_OCC_TOT: csr_rdata = occ_total;
            A_OCC_PSS: csr_rdata = occ_pass;
            A_OCC_REJ: csr_rdata = occ_tile_reject;
            A_IRQ_EN:  csr_rdata = {31'h0, irq_enable};
            A_IRQ_ST:  csr_rdata = {31'h0, irq_status_pend};
            A_HIZ_INF: csr_rdata = {TILE_SIZE[7:0], TILES_Y[11:0], TILES_X[11:0]};
            default:   csr_rdata = 32'h0;
        endcase
    end
    assign csr_ready = 1'b1;   // combinational single-cycle register file

    // =====================================================================
    // ASSERTIONS
    // =====================================================================
    property p_valid_implies_pass;
        @(posedge clk) disable iff (!rst_n) ez_valid |-> $past(s2_pass);
    endproperty
    a_valid_implies_pass: assert property (p_valid_implies_pass);

    property p_write_on_pass;
        @(posedge clk) disable iff (!rst_n) ez_z_write |-> $past(s2_do_write);
    endproperty
    a_write_on_pass: assert property (p_write_on_pass);

    property p_no_accept_during_drain;
        @(posedge clk) disable iff (!rst_n) draining |-> !s1_valid;
    endproperty
    a_no_accept_during_drain: assert property (p_no_accept_during_drain);

    property p_raw_bypass_correct;
        @(posedge clk) disable iff (!rst_n)
        (s1_valid && z_read_raw_hit) |=> (z_old == $past(s3_commit_z));
    endproperty
    a_raw_bypass_correct: assert property (p_raw_bypass_correct);

    property p_early_z_disable_never_writes;
        @(posedge clk) disable iff (!rst_n) cfg_early_z_disable |-> !s2_do_write;
    endproperty
    a_early_z_disable_never_writes: assert property (p_early_z_disable_never_writes);

    property p_tile_reject_needs_family;
        @(posedge clk) disable iff (!rst_n) tile_reject |-> hiz_dir_supported;
    endproperty
    a_tile_reject_needs_family: assert property (p_tile_reject_needs_family);

endmodule
