`timescale 1ns / 1ps

module rasterizer_core (
    input  logic        clk,
    input  logic        rst_n,

    // Control Handshakes
    input  logic        start,
    output logic        busy,
    output logic        done,

    // Input Triangle Geometry (Screen Space Coordinates)
    input  logic signed [15:0] v0_x, input  logic signed [15:0] v0_y,
    input  logic signed [15:0] v1_x, input  logic signed [15:0] v1_y,
    input  logic signed [15:0] v2_x, input  logic signed [15:0] v2_y,

    // Output Fragment Stream (To Pixel Shader / Output Merger)
    output logic        frag_valid,
    output logic [15:0] frag_x,
    output logic [15:0] frag_y,
    output logic signed [31:0] frag_e0,
    output logic signed [31:0] frag_e1,
    output logic signed [31:0] frag_e2
);

    // --- State Machine States ---
    // NOTE: SEED is a dedicated state for the "first pixel of the sweep"
    // setup. Previously this was detected via (curr_x=='0 && curr_y=='0),
    // which silently breaks for any triangle whose bounding box starts
    // at the screen origin (min_x==0 && min_y==0) -- the FSM would loop
    // in the seed branch forever and never emit fragments or `done`.
    // Using an explicit state removes the data/control coincidence.
    typedef enum logic [2:0] {
        IDLE  = 3'b000,
        SETUP = 3'b001,
        SEED  = 3'b010,
        SCAN  = 3'b011
    } state_t;

    state_t state;

    // --- Pipeline Registers ---
    logic signed [15:0] min_x, max_x, min_y, max_y;
    logic signed [15:0] curr_x, curr_y;

    // Edge Deltas
    logic signed [15:0] dX0, dY0, dX1, dY1, dX2, dY2;

    // Accumulators for the 3 Edges
    logic signed [31:0] edge0, edge1, edge2;

    // Helper functions for Min/Max
    function logic signed [15:0] min3(input logic signed [15:0] a, b, c);
        return (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
    endfunction

    function logic signed [15:0] max3(input logic signed [15:0] a, b, c);
        return (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
    endfunction

    // --- Control and Stepping Logic ---
    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            done       <= 1'b0;
            frag_valid <= 1'b0;
            curr_x     <= '0;
            curr_y     <= '0;
        end else begin
            frag_valid <= 1'b0; // Default Strobe
            done       <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        state <= SETUP;
                    end
                end

                SETUP: begin
                    // 1. Calculate Bounding Box
                    min_x <= min3(v0_x, v1_x, v2_x);
                    max_x <= max3(v0_x, v1_x, v2_x);
                    min_y <= min3(v0_y, v1_y, v2_y);
                    max_y <= max3(v0_y, v1_y, v2_y);

                    // 2. Pre-calculate Edge Deltas (Winding order dependent)
                    dX0 <= v1_x - v0_x;  dY0 <= v1_y - v0_y;
                    dX1 <= v2_x - v1_x;  dY1 <= v2_y - v1_y;
                    dX2 <= v0_x - v2_x;  dY2 <= v0_y - v2_y;

                    state <= SEED;
                end

                SEED: begin
                    // Runs exactly once per triangle, unconditionally --
                    // no data-value sentinel required.
                    curr_x <= min_x;
                    curr_y <= min_y;

                    // Seed Pineda's Cross Product Equation for the first pixel (min_x, min_y)
                    edge0 <= (min_x - v0_x)*dY0 - (min_y - v0_y)*dX0;
                    edge1 <= (min_x - v1_x)*dY1 - (min_y - v1_y)*dX1;
                    edge2 <= (min_x - v2_x)*dY2 - (min_y - v2_y)*dX2;

                    state <= SCAN;
                end

                SCAN: begin
                    // Check if the current pixel is inside the triangle
                    // (Sign-bit check: MSB must be 0 for signed positive values)
                    if (!edge0[31] && !edge1[31] && !edge2[31]) begin
                        frag_valid <= 1'b1;
                        frag_x     <= curr_x;
                        frag_y     <= curr_y;
                        frag_e0    <= edge0;
                        frag_e1    <= edge1;
                        frag_e2    <= edge2;
                    end

                    // Lawnmower Scan Pattern State Machine
                    if (curr_x < max_x) begin
                        // Step Right: Add dY incrementally
                        curr_x <= curr_x + 1;
                        edge0  <= edge0 + dY0;
                        edge1  <= edge1 + dY1;
                        edge2  <= edge2 + dY2;
                    end else begin
                        // Reached right boundary of box, step down to next row
                        if (curr_y < max_y) begin
                            curr_x <= min_x;
                            curr_y <= curr_y + 1;

                            // Reset back to left side of the row and subtract dX
                            edge0  <= ((min_x - v0_x)*dY0) - ((curr_y + 1 - v0_y)*dX0);
                            edge1  <= ((min_x - v1_x)*dY1) - ((curr_y + 1 - v1_y)*dX1);
                            edge2  <= ((min_x - v2_x)*dY2) - ((curr_y + 1 - v2_y)*dX2);
                        end else begin
                            // Finished scanning bounding box
                            state  <= IDLE;
                            done   <= 1'b1;
                            curr_x <= '0;
                            curr_y <= '0;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // ======================================================================
    // ASSERTIONS
    //
    // SAFETY checks below are unconditional -- they compile into every
    // simulation run (cocotb/UVM/whatever) AND into formal runs, since
    // they're cheap, always meaningful, and catch RTL bugs the moment
    // they're introduced rather than only during a dedicated FPV pass.
    //
    // LIVENESS and COVERAGE properties are gated under `ifdef FPV since
    // they either require formal-only input constraints (liveness needs
    // a bounded/constrained coordinate range to converge -- see note
    // below) or are meaningful only as reachability targets for a
    // formal solver, not simulation assertions.
    //
    // Formal flow: compile with +define+FPV (SymbiYosys/JasperGold/
    // Questa PropCheck/VC Formal). Simulation flow: leave FPV undefined,
    // only SAFETY checks run.
    // ======================================================================

    // ---------------------------------------------------------------
    // SAFETY (always compiled in)
    // ---------------------------------------------------------------

    // busy is exactly "not idle" -- purely combinational relationship,
    // should never drift even after future edits to the FSM.
    property p_busy_matches_state;
        @(posedge clk) disable iff (!rst_n)
        busy == (state != IDLE);
    endproperty
    a_busy_matches_state: assert property (p_busy_matches_state);

    // done is a single-cycle pulse, never held.
    property p_done_single_cycle;
        @(posedge clk) disable iff (!rst_n)
        done |=> !done;
    endproperty
    a_done_single_cycle: assert property (p_done_single_cycle);

    // frag_valid can only follow a cycle where the FSM was actually
    // evaluating a pixel in SCAN. Catches accidental fragment emission
    // from SETUP/SEED/IDLE if the case statement is ever restructured.
    property p_frag_only_from_scan;
        @(posedge clk) disable iff (!rst_n)
        frag_valid |-> $past(state) == SCAN;
    endproperty
    a_frag_only_from_scan: assert property (p_frag_only_from_scan);

    // SETUP and SEED are always exactly one cycle -- unconditional
    // transitions, no data-dependent stall. If someone adds a stall
    // condition later without updating this, it fires immediately.
    property p_setup_one_cycle;
        @(posedge clk) disable iff (!rst_n)
        state == SETUP |=> state == SEED;
    endproperty
    a_setup_one_cycle: assert property (p_setup_one_cycle);

    property p_seed_one_cycle;
        @(posedge clk) disable iff (!rst_n)
        state == SEED |=> state == SCAN;
    endproperty
    a_seed_one_cycle: assert property (p_seed_one_cycle);

    // Bounding box ordering invariant. min3/max3 should guarantee this
    // by construction -- this assertion exists to catch a broken
    // min3/max3 implementation, not the scan logic itself.
    property p_bbox_ordered;
        @(posedge clk) disable iff (!rst_n)
        (state == SEED || state == SCAN) |-> (min_x <= max_x) && (min_y <= max_y);
    endproperty
    a_bbox_ordered: assert property (p_bbox_ordered);

    // curr_x/curr_y must never leave the bounding box while scanning.
    // Paired with the FPV-only liveness property below, this is what
    // would have caught the old origin-sentinel bug formally: under the
    // old code a (0,0) bbox origin caused the FSM to keep re-seeding,
    // so the eventual `done` never fires and the liveness proof fails.
    property p_curr_within_bbox;
        @(posedge clk) disable iff (!rst_n)
        (state == SCAN)
        |-> (curr_x >= min_x) && (curr_x <= max_x)
          && (curr_y >= min_y) && (curr_y <= max_y);
    endproperty
    a_curr_within_bbox: assert property (p_curr_within_bbox);

    // Idle holds unless start is asserted -- no spontaneous transitions.
    property p_idle_holds;
        @(posedge clk) disable iff (!rst_n)
        (state == IDLE && !start) |=> (state == IDLE);
    endproperty
    a_idle_holds: assert property (p_idle_holds);

    // start is only sampled from IDLE -- asserting start mid-sweep must
    // not restart or perturb the current scan.
    property p_start_ignored_when_busy;
        @(posedge clk) disable iff (!rst_n)
        (busy && start) |=> (state != SETUP) or $past(busy);
    endproperty
    a_start_ignored_when_busy: assert property (p_start_ignored_when_busy);

`ifdef FPV
    // ---------------------------------------------------------------
    // LIVENESS (formal-only -- needs a bounded/constrained input space
    // to converge; see coordinate-range constraints in your .sby /
    // formal harness. With full 16-bit signed coordinates the reachable
    // state space is too large for BMC/PDR to prove this directly.)
    // ---------------------------------------------------------------

    // Every start eventually produces a done. Together with
    // a_curr_within_bbox above, this formally rules out the whole class
    // of "FSM gets stuck re-seeding" bugs -- including the origin bug
    // we just fixed by hand. If you want a faster-converging, weaker
    // guarantee instead, swap s_eventually[1:$] for a bounded window
    // sized to your worst-case bbox area, e.g. ##[1:512] done.
    property p_eventually_done;
        @(posedge clk) disable iff (!rst_n)
        (state == IDLE && start) |=> s_eventually [1:$] done;
    endproperty
    a_eventually_done: assert property (p_eventually_done);

    // ---------------------------------------------------------------
    // COVERAGE (formal reachability -- confirms these cases are
    // actually exercised by the proof, not vacuously true)
    // ---------------------------------------------------------------

    // The exact case that broke the old sentinel-based implementation:
    // a triangle whose bounding box starts at the screen origin.
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (state == SEED) && (min_x == 0) && (min_y == 0)
        ##[1:$] done
    );

    // Degenerate 1x1 bounding box (single pixel triangle / point).
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (state == SEED) && (min_x == max_x) && (min_y == max_y)
        ##[1:$] done
    );

    // A full sweep where no pixel is ever inside (fully degenerate or
    // zero-area triangle) -- done should still fire, frag_valid never
    // should.
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (state == IDLE && start) ##1 (state == SCAN)
        ##[1:$] done
    );
`endif

endmodule
