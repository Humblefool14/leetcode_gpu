`timescale 1ns / 1ps
//==============================================================================
// parallel_rasterizer_top
//
// Two-lane parallel rasterization pipeline, structured after the paper's
// Figure 4 ("Parallel Rasterization Module"):
//
//   input --> [input buffer] --> [FIFO]-[AFIFO]-[rasterization module]-[AFIFO]-[FIFO] --\
//                    |                                                                    +--> [mux2] --> [output buffer] --> output
//             [input control]  --> [FIFO]-[AFIFO]-[rasterization module]-[AFIFO]-[FIFO] --/
//                                        (2nd lane, generated)
//
// Mapping onto this project's existing modules:
//   - "rasterization module" in the figure -> the FULL per-lane pipeline
//     (rasterizer_core + pixel_shader + output_merger), i.e. one lane
//     produces final framebuffer writes, not just raw fragments.
//   - "FIFO"  -> sync_fifo   (elastic buffer, single clock domain)
//   - "AFIFO" -> async_fifo  (existing CDC module, Gray-code pointers)
//
// Clock domains:
//   io_clk / io_rst_n     : triangle ingress + framebuffer-write egress
//   core_clk / core_rst_n : rasterizer_core / pixel_shader / output_merger
//                           (both lanes share the same core_clk/core_rst_n;
//                           only ONE async_fifo pair per lane crosses domains,
//                           same as the figure shows one AFIFO per side)
//
// Primitive classification (paper: "Primitives are classified as odd and
// even and rasterized in parallel"):
//   input_control keeps a free-running triangle counter. Lane assignment is
//   tri_count[0] (0 = even lane, 1 = odd lane). A triangle is only accepted
//   (tri_ready) when its target lane's ingress sync_fifo has room, so the
//   two lanes naturally load-balance one triangle at a time each.
//==============================================================================

package raster_pkg;

    // Packed triangle command -- everything a lane pipeline needs to run one
    // full raster+shade+OM pass. Width must match CMD_W below exactly.
    typedef struct packed {
        logic [31:0] inv_area;                          // 32
        logic [15:0] v2_z, v1_z, v0_z;                   // 48
        logic [7:0]  v2_b, v2_g, v2_r;                   // 24
        logic [7:0]  v1_b, v1_g, v1_r;                   // 24
        logic [7:0]  v0_b, v0_g, v0_r;                   // 24
        logic [15:0] v2_y, v2_x;                         // 32
        logic [15:0] v1_y, v1_x;                         // 32
        logic [15:0] v0_y, v0_x;                         // 32
    } tri_cmd_t;                                          // = 248 bits

    localparam int CMD_W = 248;

    // Packed framebuffer-write command produced by output_merger, carried
    // through the egress AFIFO/FIFO pair back to the io_clk domain.
    typedef struct packed {
        logic [23:0] fb_wdata; // 24
        logic [18:0] fb_addr;  // 19
        logic        fb_we;   // 1
    } fb_cmd_t;                // = 44 bits

    localparam int OUT_W = 44;

    localparam int NUM_LANES = 2;

endpackage : raster_pkg


//==============================================================================
// sync_fifo -- generic single-clock elastic buffer ("FIFO" boxes in Fig. 4)
// Same registered-read-data timing as async_fifo: rd_data is valid the cycle
// AFTER rd_en is asserted with !empty, so consumers must account for that
// one cycle of latency (mirrors this project's existing FIFO convention).
//==============================================================================
module sync_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 4     // power of 2
) (
    input  logic             clk,
    input  logic             rst_n,

    input  logic [WIDTH-1:0] wr_data,
    input  logic             wr_en,
    output logic             full,

    output logic [WIDTH-1:0] rd_data,
    input  logic             rd_en,
    output logic             empty
);

    localparam int AW = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [AW:0]      wr_ptr, rd_ptr;   // extra MSB for full/empty disambiguation
    logic [WIDTH-1:0] rd_data_reg;

    assign full  = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    assign empty = (wr_ptr == rd_ptr);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
        end else if (wr_en && !full) begin
            mem[wr_ptr[AW-1:0]] <= wr_data;
            wr_ptr               <= wr_ptr + 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr      <= '0;
            rd_data_reg <= '0;
        end else if (rd_en && !empty) begin
            rd_data_reg <= mem[rd_ptr[AW-1:0]];
            rd_ptr      <= rd_ptr + 1'b1;
        end
    end

    assign rd_data = rd_data_reg;

    // synthesis translate_off
    always_ff @(posedge clk) begin
        if (wr_en && full)  $error("[%0t] SYNC_FIFO: write to full FIFO!", $time);
        if (rd_en && empty) $error("[%0t] SYNC_FIFO: read from empty FIFO!", $time);
    end
    // synthesis translate_on

endmodule : sync_fifo


//==============================================================================
// lane_pipeline -- one column of Figure 4's "rasterization module" box, i.e.
// the FULL raster+shade+OM chain for one lane, living entirely in core_clk.
//
// Pop protocol from the ingress AFIFO: rd_en pulses for one cycle, data is
// valid one cycle later (registered read, per async_fifo's timing), so this
// is a small 3-state FSM: issue rd_en -> wait one cycle -> latch & start.
//==============================================================================
module lane_pipeline
    import raster_pkg::*;
(
    input  logic          core_clk,
    input  logic          core_rst_n,

    // Ingress: read side of this lane's input AFIFO (core_clk domain)
    input  logic          in_empty,
    input  logic [CMD_W-1:0] in_data,
    output logic          in_rd_en,

    // Egress: write side of this lane's output AFIFO (core_clk domain)
    output logic          out_wr_en,
    output logic [OUT_W-1:0] out_data,
    input  logic          out_full,

    output logic          lane_busy,
    output logic          lane_done   // pulse: rasterizer_core finished a triangle
);

    typedef enum logic [1:0] {L_IDLE, L_POP, L_LATCH, L_START} lstate_t;
    lstate_t lstate;

    tri_cmd_t cmd_r;

    logic core_start, core_busy, core_done;

    // -------------------------------------------------------------
    // Pop / dispatch FSM
    // -------------------------------------------------------------
    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            lstate     <= L_IDLE;
            in_rd_en   <= 1'b0;
            core_start <= 1'b0;
            cmd_r      <= '0;
        end else begin
            in_rd_en   <= 1'b0;
            core_start <= 1'b0;

            case (lstate)
                L_IDLE: begin
                    if (!in_empty && !core_busy) begin
                        in_rd_en <= 1'b1;
                        lstate   <= L_POP;
                    end
                end

                L_POP: begin
                    // in_data becomes valid THIS cycle (registered FIFO read)
                    lstate <= L_LATCH;
                end

                L_LATCH: begin
                    cmd_r  <= tri_cmd_t'(in_data);
                    lstate <= L_START;
                end

                L_START: begin
                    core_start <= 1'b1;
                    lstate     <= L_IDLE;
                end

                default: lstate <= L_IDLE;
            endcase
        end
    end

    assign lane_busy = (lstate != L_IDLE) || core_busy;
    assign lane_done = core_done;

    // -------------------------------------------------------------
    // Raster -> Shade -> Output-Merge chain (existing modules, reused
    // verbatim from rasterizer_shader_om_integration)
    // -------------------------------------------------------------
    logic        frag_valid;
    logic [15:0] frag_x, frag_y;
    logic [31:0] frag_e0, frag_e1, frag_e2;

    logic        ps_valid;
    logic [15:0] ps_x, ps_y;
    logic [7:0]  ps_r, ps_g, ps_b;
    logic [15:0] ps_z;

    logic        fb_we;
    logic [18:0] fb_addr;
    logic [23:0] fb_wdata;

    rasterizer_core u_rasterizer (
        .clk        (core_clk),
        .rst_n      (core_rst_n),
        .start      (core_start),
        .busy       (core_busy),
        .done       (core_done),
        .v0_x       (cmd_r.v0_x), .v0_y (cmd_r.v0_y),
        .v1_x       (cmd_r.v1_x), .v1_y (cmd_r.v1_y),
        .v2_x       (cmd_r.v2_x), .v2_y (cmd_r.v2_y),
        .frag_valid (frag_valid),
        .frag_x     (frag_x),
        .frag_y     (frag_y),
        .frag_e0    (frag_e0),
        .frag_e1    (frag_e1),
        .frag_e2    (frag_e2)
    );

    pixel_shader u_shader (
        .clk          (core_clk),
        .rst_n        (core_rst_n),
        .inv_area     (cmd_r.inv_area),
        .v0_r (cmd_r.v0_r), .v0_g (cmd_r.v0_g), .v0_b (cmd_r.v0_b),
        .v1_r (cmd_r.v1_r), .v1_g (cmd_r.v1_g), .v1_b (cmd_r.v1_b),
        .v2_r (cmd_r.v2_r), .v2_g (cmd_r.v2_g), .v2_b (cmd_r.v2_b),
        .v0_z         (cmd_r.v0_z),
        .v1_z         (cmd_r.v1_z),
        .v2_z         (cmd_r.v2_z),
        .raster_valid (frag_valid),
        .raster_x     (frag_x),
        .raster_y     (frag_y),
        .raster_e0    (frag_e0),
        .raster_e1    (frag_e1),
        .raster_e2    (frag_e2),
        .ps_valid     (ps_valid),
        .ps_x         (ps_x),
        .ps_y         (ps_y),
        .ps_r         (ps_r),
        .ps_g         (ps_g),
        .ps_b         (ps_b),
        .ps_z         (ps_z)
    );

    // pipeline_stall is wired to the egress AFIFO's full flag: this is the
    // exact backpressure path that port already exists for. When the CDC
    // FIFO fills up, output_merger freezes (holds Z-buffer state) instead
    // of dropping a pixel write.
    output_merger u_om (
        .clk            (core_clk),
        .rst_n          (core_rst_n),
        .clear_zbuffer  (1'b0),
        .clear_done     (),
        .pipeline_stall (out_full),
        .ps_valid       (ps_valid),
        .ps_x           (ps_x),
        .ps_y           (ps_y),
        .ps_color       ({ps_r, ps_g, ps_b}),
        .ps_z           (ps_z),
        .fb_we          (fb_we),
        .fb_addr        (fb_addr),
        .fb_wdata       (fb_wdata)
    );

    fb_cmd_t out_cmd;
    assign out_cmd.fb_we    = fb_we;
    assign out_cmd.fb_addr  = fb_addr;
    assign out_cmd.fb_wdata = fb_wdata;

    assign out_data  = out_cmd;
    // Only push a command when this lane actually produced a write, and the
    // egress FIFO isn't already full (guarded by pipeline_stall above too,
    // this is belt-and-suspenders against a same-cycle race).
    assign out_wr_en = fb_we && !out_full;

endmodule : lane_pipeline


//==============================================================================
// parallel_rasterizer_top
//==============================================================================
module parallel_rasterizer_top
    import raster_pkg::*;
#(
    parameter int IN_FIFO_DEPTH  = 4,
    parameter int OUT_FIFO_DEPTH = 4,
    parameter int CDC_SYNC_STAGES = 2
) (
    // ---------------- io_clk domain: triangle ingress ----------------
    input  logic        io_clk,
    input  logic        io_rst_n,

    input  logic        tri_valid,
    output logic         tri_ready,

    input  logic [15:0] v0_x, v0_y, v1_x, v1_y, v2_x, v2_y,
    input  logic [7:0]  v0_r, v0_g, v0_b,
    input  logic [7:0]  v1_r, v1_g, v1_b,
    input  logic [7:0]  v2_r, v2_g, v2_b,
    input  logic [15:0] v0_z, v1_z, v2_z,
    input  logic [31:0] inv_area,

    // ---------------- io_clk domain: framebuffer-write egress --------
    output logic        fb_we,
    output logic [18:0] fb_addr,
    output logic [23:0] fb_wdata,

    // ---------------- core_clk domain: raster+shade+OM ---------------
    input  logic        core_clk,
    input  logic        core_rst_n,

    // Aggregate/per-lane status (core_clk domain)
    output logic                     busy,          // OR of both lanes
    output logic                     done,          // OR of both lanes' done pulses
    output logic [NUM_LANES-1:0]     lane_busy_o,
    output logic [NUM_LANES-1:0]     lane_done_o
);

    // =========================================================================
    // Input buffer + input control: pack the triangle, classify odd/even,
    // and route into the selected lane's ingress sync_fifo.
    // =========================================================================
    tri_cmd_t tri_cmd;
    assign tri_cmd.v0_x = v0_x; assign tri_cmd.v0_y = v0_y;
    assign tri_cmd.v1_x = v1_x; assign tri_cmd.v1_y = v1_y;
    assign tri_cmd.v2_x = v2_x; assign tri_cmd.v2_y = v2_y;
    assign tri_cmd.v0_r = v0_r; assign tri_cmd.v0_g = v0_g; assign tri_cmd.v0_b = v0_b;
    assign tri_cmd.v1_r = v1_r; assign tri_cmd.v1_g = v1_g; assign tri_cmd.v1_b = v1_b;
    assign tri_cmd.v2_r = v2_r; assign tri_cmd.v2_g = v2_g; assign tri_cmd.v2_b = v2_b;
    assign tri_cmd.v0_z = v0_z; assign tri_cmd.v1_z = v1_z; assign tri_cmd.v2_z = v2_z;
    assign tri_cmd.inv_area = inv_area;

    logic [$clog2(NUM_LANES)-1:0] tri_lane_sel;   // = tri_count[0] for 2 lanes
    logic                         tri_count;      // free-running parity counter

    logic [NUM_LANES-1:0] in_fifo_full;

    // Ready only reflects the lane this triangle would actually land in --
    // the *other* lane being full must not block dispatch.
    assign tri_ready = !in_fifo_full[tri_lane_sel];

    always_ff @(posedge io_clk or negedge io_rst_n) begin
        if (!io_rst_n) begin
            tri_count <= 1'b0;
        end else if (tri_valid && tri_ready) begin
            tri_count <= ~tri_count;   // toggle even/odd assignment
        end
    end

    assign tri_lane_sel = tri_count;  // even triangles -> lane 0, odd -> lane 1

    // =========================================================================
    // Per-lane arrays (generate below fills these in)
    // =========================================================================
    logic [NUM_LANES-1:0]        in_fifo_wr_en;
    logic [CMD_W-1:0]            in_fifo_rd_data [NUM_LANES];
    logic [NUM_LANES-1:0]        in_afifo_full;

    logic [NUM_LANES-1:0]        in_afifo_rd_en_core;
    logic [NUM_LANES-1:0]        in_afifo_empty_core;
    logic [CMD_W-1:0]            in_afifo_rd_data_core [NUM_LANES];

    logic [NUM_LANES-1:0]        out_afifo_wr_en_core;
    logic [OUT_W-1:0]            out_afifo_wr_data_core [NUM_LANES];
    logic [NUM_LANES-1:0]        out_afifo_full_core;

    logic [NUM_LANES-1:0]        out_afifo_empty;
    logic [OUT_W-1:0]            out_afifo_rd_data [NUM_LANES];
    logic [NUM_LANES-1:0]        out_afifo_rd_en;

    logic [NUM_LANES-1:0]        out_fifo_full;
    logic [OUT_W-1:0]            out_fifo_rd_data [NUM_LANES];
    logic [NUM_LANES-1:0]        out_fifo_rd_en;
    logic [NUM_LANES-1:0]        out_fifo_empty;

    genvar g;
    generate
        for (g = 0; g < NUM_LANES; g++) begin : LANE

            // ---------------------------------------------------------
            // Ingress "FIFO" (io_clk domain, sync)
            // ---------------------------------------------------------
            sync_fifo #(.WIDTH(CMD_W), .DEPTH(IN_FIFO_DEPTH)) u_in_fifo (
                .clk     (io_clk),
                .rst_n   (io_rst_n),
                .wr_data (tri_cmd),
                .wr_en   (in_fifo_wr_en[g]),
                .full    (in_fifo_full[g]),
                .rd_data (in_fifo_rd_data[g]),
                .rd_en   (in_afifo_wr_en_pop[g]),   // defined below
                .empty   (in_fifo_empty[g])
            );

            assign in_fifo_wr_en[g] = tri_valid && tri_ready && (tri_lane_sel == g);

            // A tiny io_clk-side pump: whenever the ingress sync_fifo has
            // data and the ingress AFIFO (write side, io_clk) has room,
            // pop one and push it in. Registered-read timing means this is
            // a 2-state pump, same shape as the lane_pipeline pop FSM.
            logic in_fifo_empty_l;
            assign in_fifo_empty_l = in_fifo_empty[g];

            typedef enum logic [1:0] {P_IDLE, P_POP, P_PUSH} pstate_t;
            pstate_t pstate;
            logic in_afifo_wr_en_pop_r;

            always_ff @(posedge io_clk or negedge io_rst_n) begin
                if (!io_rst_n) begin
                    pstate               <= P_IDLE;
                    in_afifo_wr_en_pop_r <= 1'b0;
                end else begin
                    in_afifo_wr_en_pop_r <= 1'b0;
                    case (pstate)
                        P_IDLE: if (!in_fifo_empty_l && !in_afifo_full[g]) begin
                                    pstate <= P_POP;
                                end
                        P_POP: begin
                            pstate <= P_PUSH;
                        end
                        P_PUSH: begin
                            in_afifo_wr_en_pop_r <= 1'b1; // pushes in_fifo_rd_data (valid now)
                            pstate               <= P_IDLE;
                        end
                        default: pstate <= P_IDLE;
                    endcase
                end
            end

            wire in_afifo_wr_en_pop_g = (pstate == P_POP); // rd_en pulse for u_in_fifo
            assign in_afifo_wr_en_pop[g] = in_afifo_wr_en_pop_g;

            // ---------------------------------------------------------
            // Ingress "AFIFO" (io_clk -> core_clk CDC)
            // ---------------------------------------------------------
            async_fifo #(
                .DATA_WIDTH  (CMD_W),
                .DEPTH       (4),
                .AF_LEVEL    (1),
                .AE_LEVEL    (1),
                .SYNC_STAGES (CDC_SYNC_STAGES)
            ) u_in_afifo (
                .wr_clk         (io_clk),
                .wr_rst_n       (io_rst_n),
                .wr_data        (in_fifo_rd_data[g]),
                .wr_en          (in_afifo_wr_en_pop_r),
                .wr_full        (in_afifo_full[g]),
                .wr_almost_full (),
                .wr_count       (),

                .rd_clk         (core_clk),
                .rd_rst_n       (core_rst_n),
                .rd_data        (in_afifo_rd_data_core[g]),
                .rd_en          (in_afifo_rd_en_core[g]),
                .rd_empty       (in_afifo_empty_core[g]),
                .rd_almost_empty(),
                .rd_count       ()
            );

            // ---------------------------------------------------------
            // "rasterization module" (core_clk domain): full lane pipeline
            // ---------------------------------------------------------
            lane_pipeline u_lane (
                .core_clk   (core_clk),
                .core_rst_n (core_rst_n),
                .in_empty   (in_afifo_empty_core[g]),
                .in_data    (in_afifo_rd_data_core[g]),
                .in_rd_en   (in_afifo_rd_en_core[g]),
                .out_wr_en  (out_afifo_wr_en_core[g]),
                .out_data   (out_afifo_wr_data_core[g]),
                .out_full   (out_afifo_full_core[g]),
                .lane_busy  (lane_busy_o[g]),
                .lane_done  (lane_done_o[g])
            );

            // ---------------------------------------------------------
            // Egress "AFIFO" (core_clk -> io_clk CDC)
            // ---------------------------------------------------------
            async_fifo #(
                .DATA_WIDTH  (OUT_W),
                .DEPTH       (4),
                .AF_LEVEL    (1),
                .AE_LEVEL    (1),
                .SYNC_STAGES (CDC_SYNC_STAGES)
            ) u_out_afifo (
                .wr_clk         (core_clk),
                .wr_rst_n       (core_rst_n),
                .wr_data        (out_afifo_wr_data_core[g]),
                .wr_en          (out_afifo_wr_en_core[g]),
                .wr_full        (out_afifo_full_core[g]),
                .wr_almost_full (),
                .wr_count       (),

                .rd_clk         (io_clk),
                .rd_rst_n       (io_rst_n),
                .rd_data        (out_afifo_rd_data[g]),
                .rd_en          (out_afifo_rd_en[g]),
                .rd_empty       (out_afifo_empty[g]),
                .rd_almost_empty(),
                .rd_count       ()
            );

            // ---------------------------------------------------------
            // Egress "FIFO" (io_clk domain, sync) -- feeds mux2
            // ---------------------------------------------------------
            // Same pop-and-forward pump pattern as the ingress side.
            typedef enum logic [1:0] {E_IDLE, E_POP, E_PUSH} estate_t;
            estate_t estate;
            logic    out_fifo_wr_en_r;

            always_ff @(posedge io_clk or negedge io_rst_n) begin
                if (!io_rst_n) begin
                    estate            <= E_IDLE;
                    out_fifo_wr_en_r  <= 1'b0;
                end else begin
                    out_fifo_wr_en_r <= 1'b0;
                    case (estate)
                        E_IDLE: if (!out_afifo_empty[g] && !out_fifo_full[g]) begin
                                    estate <= E_POP;
                                end
                        E_POP:  estate <= E_PUSH;
                        E_PUSH: begin
                            out_fifo_wr_en_r <= 1'b1;  // pushes out_afifo_rd_data (valid now)
                            estate           <= E_IDLE;
                        end
                        default: estate <= E_IDLE;
                    endcase
                end
            end

            assign out_afifo_rd_en[g] = (estate == E_POP);

            sync_fifo #(.WIDTH(OUT_W), .DEPTH(OUT_FIFO_DEPTH)) u_out_fifo (
                .clk     (io_clk),
                .rst_n   (io_rst_n),
                .wr_data (out_afifo_rd_data[g]),
                .wr_en   (out_fifo_wr_en_r),
                .full    (out_fifo_full[g]),
                .rd_data (out_fifo_rd_data[g]),
                .rd_en   (out_fifo_rd_en[g]),
                .empty   (out_fifo_empty[g])
            );

        end : LANE
    endgenerate

    assign busy = |lane_busy_o;
    assign done = |lane_done_o;

    // =========================================================================
    // mux2 / output control / output buffer (io_clk domain)
    //
    // Round-robin arbitration between the two lanes' egress FIFOs. Same
    // registered-read-data convention as the FIFOs feeding it, so this is a
    // 3-state pop/latch/drive FSM, same shape as lane_pipeline's ingress pump.
    // =========================================================================
    typedef enum logic [1:0] {OC_IDLE, OC_POP, OC_DRIVE} oc_state_t;
    oc_state_t oc_state;

    logic rr_sel;        // round-robin pointer: which lane to try first
    logic served_lane;    // which lane is actually being popped this round

    fb_cmd_t fb_cmd_out;

    always_ff @(posedge io_clk or negedge io_rst_n) begin
        if (!io_rst_n) begin
            oc_state    <= OC_IDLE;
            rr_sel      <= 1'b0;
            served_lane <= 1'b0;
            out_fifo_rd_en <= '0;
            fb_we       <= 1'b0;
            fb_addr     <= '0;
            fb_wdata    <= '0;
        end else begin
            out_fifo_rd_en <= '0;
            fb_we          <= 1'b0; // default: single-cycle write strobe

            case (oc_state)
                OC_IDLE: begin
                    if (!out_fifo_empty[rr_sel]) begin
                        out_fifo_rd_en[rr_sel] <= 1'b1;
                        served_lane            <= rr_sel;
                        oc_state               <= OC_POP;
                    end else if (!out_fifo_empty[~rr_sel]) begin
                        out_fifo_rd_en[~rr_sel] <= 1'b1;
                        served_lane             <= ~rr_sel;
                        oc_state                <= OC_POP;
                    end
                end

                OC_POP: begin
                    // out_fifo_rd_data[served_lane] becomes valid THIS cycle
                    oc_state <= OC_DRIVE;
                end

                OC_DRIVE: begin
                    fb_cmd_out = fb_cmd_t'(out_fifo_rd_data[served_lane]);
                    fb_we      <= fb_cmd_out.fb_we;
                    fb_addr    <= fb_cmd_out.fb_addr;
                    fb_wdata   <= fb_cmd_out.fb_wdata;
                    rr_sel     <= ~served_lane;  // give the other lane priority next time
                    oc_state   <= OC_IDLE;
                end

                default: oc_state <= OC_IDLE;
            endcase
        end
    end

endmodule : parallel_rasterizer_top
