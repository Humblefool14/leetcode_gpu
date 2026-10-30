`timescale 1ns / 1ps
// ============================================================================
// early_z_unit -- fixed version (see the ad_rx doc, section 4, "your blocks").
//
// Fixes:
//  Z1  read-after-write hazard: the z_buffer read of stage 2 happens at the same
//      edge as stage 3's write; a pixel in s1 equal to the one in s2 read the
//      OLD depth.  Forwarding now comes from the write in flight (s2_do_write,
//      s2_addr), not from s3_commit (which had already reached the RAM).
//  Z2  Hi-Z soundness: a tile entry now carries a mask of the pixels written
//      this generation; tile_reject only when the mask is full.  The old entry
//      was seeded from the first write, so a later primitive could be rejected
//      over pixels still holding the clear depth.
//  Z3  generation wrap: after 2^GEN_W - 1 clears the tag wraps; every entry
//      (z_buffer and Hi-Z) is scrubbed to generation 0 first (pipeline_stall
//      held, clear_done at the end).  The same scrub runs after reset, so no
//      power-on RAM contents are assumed (the old ASIC caveat).
//  Z4  occ_tile_reject had two drivers (two always_ff blocks); one now.
//  Z5  tile queries outside the screen never reject (the old index wrapped).
//  Z6  a change of depth-function family starts a new generation (was a
//      driver contract: switching LESS <-> GREATER mid-frame culled wrongly).
//  Z7  synchronous active-low reset (the RX convention).
// Unchanged: the CSR map, the drain window, the pipeline and its stall.
// ============================================================================
module early_z_unit #(
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480,
    parameter int FB_SIZE       = SCREEN_WIDTH * SCREEN_HEIGHT,
    parameter int ADDR_W        = $clog2(FB_SIZE),
    parameter int Z_W           = 16,
    parameter int GEN_W         = 8,
    parameter int DRAIN_CYCLES  = 4,
    parameter int TILE_SIZE     = 8
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              clear_zbuffer,
    output logic              clear_done,
    output logic              pipeline_stall,
    input  logic              raster_valid,
    input  logic [15:0]       raster_x,
    input  logic [15:0]       raster_y,
    input  logic [Z_W-1:0]    raster_z,
    input  logic              tile_query_valid,
    input  logic [15:0]       tile_x,
    input  logic [15:0]       tile_y,
    input  logic [Z_W-1:0]    tile_z_lo,
    input  logic [Z_W-1:0]    tile_z_hi,
    output logic              tile_reject,
    output logic              ez_valid,
    output logic [15:0]       ez_x,
    output logic [15:0]       ez_y,
    output logic [Z_W-1:0]    ez_z,
    output logic              ez_z_write,
    output logic [ADDR_W-1:0] ez_z_addr,
    output logic [Z_W-1:0]    ez_z_wdata,
    input  logic              shader_stall,
    input  logic              csr_valid,
    input  logic              csr_we,
    input  logic [7:0]        csr_addr,
    input  logic [31:0]       csr_wdata,
    output logic [31:0]       csr_rdata,
    output logic              csr_ready,
    output logic              irq_o
);
    typedef enum logic [2:0] {
        DF_NEVER = 3'b000, DF_LESS = 3'b001, DF_EQUAL = 3'b010, DF_LEQUAL = 3'b011,
        DF_GREATER = 3'b100, DF_NOTEQUAL = 3'b101, DF_GEQUAL = 3'b110, DF_ALWAYS = 3'b111
    } depth_func_e;

    function automatic logic depth_compare(input logic [Z_W-1:0] n, input logic [Z_W-1:0] o, input logic [2:0] f);
        case (f)
            DF_NEVER: depth_compare = 1'b0;      DF_LESS:     depth_compare = (n <  o);
            DF_EQUAL: depth_compare = (n == o);  DF_LEQUAL:   depth_compare = (n <= o);
            DF_GREATER: depth_compare = (n > o); DF_NOTEQUAL: depth_compare = (n != o);
            DF_GEQUAL: depth_compare = (n >= o); default:     depth_compare = 1'b1;
        endcase
    endfunction
    function automatic logic is_less_family(input logic [2:0] f);    is_less_family    = (f == DF_LESS)    || (f == DF_LEQUAL); endfunction
    function automatic logic is_greater_family(input logic [2:0] f); is_greater_family = (f == DF_GREATER) || (f == DF_GEQUAL); endfunction

    localparam int TILES_X     = SCREEN_WIDTH  / TILE_SIZE;
    localparam int TILES_Y     = SCREEN_HEIGHT / TILE_SIZE;
    localparam int TILE_COUNT  = TILES_X * TILES_Y;
    localparam int TILE_ADDR_W = $clog2(TILE_COUNT);
    localparam int TS_SHIFT    = $clog2(TILE_SIZE);
    localparam int MASK_W      = TILE_SIZE * TILE_SIZE;

    logic [2:0] cfg_depth_func;
    logic       cfg_z_write_enable, cfg_early_z_disable, csr_clear_trigger;

    typedef struct packed { logic [GEN_W-1:0] gen; logic [Z_W-1:0] z; } zentry_t;
    typedef struct packed { logic [GEN_W-1:0] gen; logic [MASK_W-1:0] mask; logic [Z_W-1:0] z; } hentry_t;

    (* ram_style = "block" *) zentry_t z_buffer   [0:FB_SIZE-1];
    hentry_t                           hiz_buffer [0:TILE_COUNT-1];

    // ------------------------------------------------------------ generations, scrub (Z3, Z6)
    logic [GEN_W-1:0]  current_gen;
    logic              clear_req_prev, clear_start_pulse, fam_less_q, fam_valid_q, fam_change;
    logic              scrubbing;
    logic [ADDR_W-1:0] scrub_addr;

    assign fam_change = fam_valid_q && ((is_less_family(cfg_depth_func) && !fam_less_q) ||
                                        (is_greater_family(cfg_depth_func) && fam_less_q));
    always_ff @(posedge clk) begin
        if (!rst_n) clear_req_prev <= 1'b0;
        else        clear_req_prev <= (clear_zbuffer || csr_clear_trigger);
    end
    assign clear_start_pulse = ((clear_zbuffer || csr_clear_trigger) && !clear_req_prev) || fam_change;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_gen <= GEN_W'(1); scrubbing <= 1'b1; scrub_addr <= '0;
            fam_less_q <= 1'b1; fam_valid_q <= 1'b0;
        end else begin
            if (is_less_family(cfg_depth_func) || is_greater_family(cfg_depth_func)) begin
                fam_less_q <= is_less_family(cfg_depth_func); fam_valid_q <= 1'b1;
            end
            if (scrubbing) begin
                scrub_addr <= scrub_addr + 1'b1;
                if (scrub_addr == ADDR_W'(FB_SIZE - 1)) scrubbing <= 1'b0;
            end
            if (clear_start_pulse) begin
                if (current_gen == {GEN_W{1'b1}}) begin
                    current_gen <= GEN_W'(1); scrubbing <= 1'b1; scrub_addr <= '0;
                end else
                    current_gen <= current_gen + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ drain window
    localparam int DCW = $clog2(DRAIN_CYCLES + 1);
    logic [DCW-1:0] drain_cnt;
    logic           draining, scrub_was;
    always_ff @(posedge clk) begin
        if (!rst_n)                 drain_cnt <= '0;
        else if (clear_start_pulse) drain_cnt <= DCW'(DRAIN_CYCLES);
        else if (drain_cnt != '0)   drain_cnt <= drain_cnt - 1'b1;
    end
    always_ff @(posedge clk) scrub_was <= rst_n ? scrubbing : 1'b1;
    assign draining       = (drain_cnt != '0) || clear_start_pulse || scrubbing;
    assign pipeline_stall = draining || shader_stall;
    // done: the drain window has ended and no scrub is running (or a scrub just ended)
    assign clear_done     = ((drain_cnt == DCW'(1)) && !scrubbing) || (scrub_was && !scrubbing && drain_cnt == '0);

    // ------------------------------------------------------------ Hi-Z query (Z2, Z5)
    hentry_t                hiz_entry;
    logic                   hiz_stale, hiz_dir_supported, tile_in;
    logic [TILE_ADDR_W-1:0] tile_addr_q;
    assign tile_in      = (tile_x < TILES_X) && (tile_y < TILES_Y);
    assign tile_addr_q  = tile_y[TILE_ADDR_W-1:0] * TILES_X[TILE_ADDR_W-1:0] + tile_x[TILE_ADDR_W-1:0];
    assign hiz_entry    = hiz_buffer[tile_addr_q];
    assign hiz_stale    = (hiz_entry.gen != current_gen) || (hiz_entry.mask != {MASK_W{1'b1}});
    assign hiz_dir_supported = is_less_family(cfg_depth_func) || is_greater_family(cfg_depth_func);

    always_comb begin
        tile_reject = 1'b0;
        if (tile_query_valid && tile_in && hiz_dir_supported && !hiz_stale && !cfg_early_z_disable && !draining) begin
            if (is_less_family(cfg_depth_func)) tile_reject = (tile_z_lo > hiz_entry.z);
            else                                tile_reject = (tile_z_hi < hiz_entry.z);
        end
    end

    // ------------------------------------------------------------ stage 1
    logic s1_valid; logic [ADDR_W-1:0] s1_addr; logic [15:0] s1_x, s1_y; logic [Z_W-1:0] s1_z;
    logic addr_in_bounds;
    assign addr_in_bounds = (raster_x < SCREEN_WIDTH) && (raster_y < SCREEN_HEIGHT);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_valid <= 1'b0; s1_addr <= '0; s1_x <= '0; s1_y <= '0; s1_z <= '0;
        end else if (draining) begin
            s1_valid <= 1'b0;
        end else if (!shader_stall) begin
            s1_valid <= raster_valid && addr_in_bounds;
            if (raster_valid && addr_in_bounds) begin
                s1_addr <= ADDR_W'(raster_y * SCREEN_WIDTH + raster_x);
                s1_x <= raster_x; s1_y <= raster_y; s1_z <= raster_z;
            end
        end
    end

    // ------------------------------------------------------------ stage 2: read + forwarding (Z1)
    logic s2_valid; logic [ADDR_W-1:0] s2_addr; logic [15:0] s2_x, s2_y; logic [Z_W-1:0] s2_z;
    logic [Z_W-1:0] z_old; logic z_old_valid;
    logic s2_pass, s2_do_write, z_read_raw_hit;
    assign z_read_raw_hit = s1_valid && s2_do_write && (s2_addr == s1_addr);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s2_valid <= 1'b0; s2_addr <= '0; s2_x <= '0; s2_y <= '0; s2_z <= '0;
            z_old <= '0; z_old_valid <= 1'b0;
        end else if (draining) begin
            s2_valid <= 1'b0;
        end else if (!shader_stall) begin
            s2_valid <= s1_valid; s2_addr <= s1_addr; s2_x <= s1_x; s2_y <= s1_y; s2_z <= s1_z;
            if (s1_valid) begin
                if (z_read_raw_hit) begin
                    z_old <= s2_z; z_old_valid <= 1'b1;              // the write landing this edge
                end else begin
                    z_old <= z_buffer[s1_addr].z;
                    z_old_valid <= (z_buffer[s1_addr].gen == current_gen);
                end
            end
        end
    end

    // ------------------------------------------------------------ stage 3: test, writes (Z2, Z4)
    assign s2_pass = s2_valid && (cfg_early_z_disable || !z_old_valid || depth_compare(s2_z, z_old, cfg_depth_func));
    assign s2_do_write = s2_pass && cfg_z_write_enable && !cfg_early_z_disable && !draining && !shader_stall;

    logic [TILE_ADDR_W-1:0] s2_tile_addr;
    logic [$clog2(MASK_W)-1:0] s2_bit;
    assign s2_tile_addr = TILE_ADDR_W'((s2_y >> TS_SHIFT) * TILES_X + (s2_x >> TS_SHIFT));
    assign s2_bit       = {s2_y[TS_SHIFT-1:0], s2_x[TS_SHIFT-1:0]};

    hentry_t h_old, h_new;
    assign h_old = hiz_buffer[s2_tile_addr];
    always_comb begin
        h_new = h_old;
        if (h_old.gen != current_gen) begin
            h_new.gen = current_gen; h_new.mask = '0; h_new.z = s2_z;
        end else if (is_less_family(cfg_depth_func)) begin
            if (s2_z > h_old.z) h_new.z = s2_z;
        end else if (s2_z < h_old.z) h_new.z = s2_z;
        h_new.mask[s2_bit] = 1'b1;
    end

    logic [31:0] occ_total, occ_pass, occ_tile_reject;
    logic        cnt_reset;

    always_ff @(posedge clk) begin
        if (scrubbing) begin
            z_buffer[scrub_addr].gen <= '0;
            if (scrub_addr < ADDR_W'(TILE_COUNT)) hiz_buffer[scrub_addr[TILE_ADDR_W-1:0]].gen <= '0;
        end else if (s2_do_write) begin
            z_buffer[s2_addr] <= '{gen: current_gen, z: s2_z};
            hiz_buffer[s2_tile_addr] <= h_new;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ez_valid <= 1'b0; ez_x <= '0; ez_y <= '0; ez_z <= '0;
            ez_z_write <= 1'b0; ez_z_addr <= '0; ez_z_wdata <= '0;
            occ_total <= '0; occ_pass <= '0; occ_tile_reject <= '0;
        end else begin
            if (!shader_stall) begin
                ez_valid <= s2_pass && !draining; ez_x <= s2_x; ez_y <= s2_y; ez_z <= s2_z;
                ez_z_write <= s2_do_write; ez_z_addr <= s2_addr; ez_z_wdata <= s2_z;
            end
            if (cnt_reset) begin
                occ_total <= '0; occ_pass <= '0; occ_tile_reject <= '0;    // Z4: one driver
            end else begin
                if (!shader_stall && s2_valid) occ_total <= occ_total + 1'b1;
                if (!shader_stall && s2_pass)  occ_pass  <= occ_pass  + 1'b1;
                if (tile_query_valid && tile_reject) occ_tile_reject <= occ_tile_reject + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ CSR block (unchanged map)
    localparam bit [7:0] A_CTRL = 8'h00, A_STATUS = 8'h04, A_OCC_TOT = 8'h08, A_OCC_PSS = 8'h0C,
                         A_OCC_REJ = 8'h10, A_IRQ_EN = 8'h14, A_IRQ_ST = 8'h18, A_HIZ_INF = 8'h1C;
    logic irq_enable, irq_status_pend, clear_done_prev;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cfg_depth_func <= DF_LESS; cfg_z_write_enable <= 1'b1; cfg_early_z_disable <= 1'b0;
            csr_clear_trigger <= 1'b0; cnt_reset <= 1'b0; irq_enable <= 1'b0; irq_status_pend <= 1'b0;
            clear_done_prev <= 1'b0;
        end else begin
            csr_clear_trigger <= 1'b0; cnt_reset <= 1'b0;
            if (csr_valid && csr_we) begin
                case (csr_addr)
                    A_CTRL: begin
                        csr_clear_trigger <= csr_wdata[0]; cfg_early_z_disable <= csr_wdata[1];
                        cfg_depth_func <= csr_wdata[4:2]; cfg_z_write_enable <= csr_wdata[5];
                        cnt_reset <= csr_wdata[6];
                    end
                    A_IRQ_EN: irq_enable <= csr_wdata[0];
                    A_IRQ_ST: if (csr_wdata[0]) irq_status_pend <= 1'b0;
                    default: ;
                endcase
            end
            clear_done_prev <= clear_done;
            if (clear_done && !clear_done_prev) irq_status_pend <= 1'b1;
        end
    end
    assign irq_o = irq_enable && irq_status_pend;
    always_comb begin
        case (csr_addr)
            A_CTRL:    csr_rdata = {25'h0, cnt_reset, cfg_z_write_enable, cfg_depth_func, cfg_early_z_disable, 1'b0};
            A_STATUS:  csr_rdata = {29'h0, scrubbing, pipeline_stall, clear_done};
            A_OCC_TOT: csr_rdata = occ_total;
            A_OCC_PSS: csr_rdata = occ_pass;
            A_OCC_REJ: csr_rdata = occ_tile_reject;
            A_IRQ_EN:  csr_rdata = {31'h0, irq_enable};
            A_IRQ_ST:  csr_rdata = {31'h0, irq_status_pend};
            A_HIZ_INF: csr_rdata = {TILE_SIZE[7:0], TILES_Y[11:0], TILES_X[11:0]};
            default:   csr_rdata = 32'h0;
        endcase
    end
    assign csr_ready = 1'b1;

    // ------------------------------------------------------------ assertions
    a_valid_implies_pass:   assert property (@(posedge clk) disable iff (!rst_n) ez_valid |-> $past(s2_pass));
    a_write_on_pass:        assert property (@(posedge clk) disable iff (!rst_n) ez_z_write |-> $past(s2_do_write));
    a_no_accept_during_drain: assert property (@(posedge clk) disable iff (!rst_n) $past(draining) |-> !s1_valid);
    a_raw_forward:          assert property (@(posedge clk) disable iff (!rst_n)
                              (z_read_raw_hit && !shader_stall && !draining) |=> (z_old == $past(s2_z)) && z_old_valid);
    a_disable_never_writes: assert property (@(posedge clk) disable iff (!rst_n) cfg_early_z_disable |-> !s2_do_write);
    a_reject_needs_full:    assert property (@(posedge clk) disable iff (!rst_n)
                              tile_reject |-> hiz_entry.mask == {MASK_W{1'b1}} && hiz_entry.gen == current_gen);
    a_gen_nonzero:          assert property (@(posedge clk) disable iff (!rst_n) current_gen != '0);
endmodule
