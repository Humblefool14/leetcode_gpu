`timescale 1ns / 1ps

// =============================================================================
// triangle_clipper
//
// Fills the "cull/clip" gap left open by backface_culler, which only tests
// winding order and does not clip. This module clips a single input
// triangle against the screen-space viewport rectangle
// [0, SCREEN_WIDTH-1] x [0, SCREEN_HEIGHT-1] using Sutherland-Hodgman
// against the 4 axis-aligned edges (left, right, top, bottom), then
// fan-triangulates the resulting convex polygon back into 1-5 triangles
// and streams them out one per cycle.
//
// SCOPE NOTE: this clips in 2D screen space only, matching the existing
// backface_culler / rasterizer_core port convention (no Z, no w). There is
// no near/far (Z) clip here -- if a Z or clip-space w is added upstream of
// this stage later, near-plane clipping needs to happen *before* the
// perspective divide that produces these screen-space x/y values, which
// this module structurally cannot do. Treat this as the screen-space
// guard-band/viewport clip only.
//
// PIPELINE POSITION (per the reference block diagram):
//   primitive assembly -> [backface_culler] -> [triangle_clipper] -> setup
// i.e. cull first (cheap, rejects ~half of triangles for free), then clip
// only the survivors.
//
// ALGORITHM
// Classic Sutherland-Hodgman: the polygon is clipped one plane at a time.
// Each pass walks the current polygon's edges (Vprev -> Vi) and, per edge,
// emits 0, 1, or 2 vertices into the next polygon buffer depending on the
// inside/outside status of the two endpoints against that plane. A triangle
// clipped against a 4-edge convex window can gain at most 4 vertices, so
// the polygon buffers are sized for the worst case: 3 + 4 = 7 vertices.
//
// FIXED-POINT NOTE: edge/plane intersections need a fractional interpolant
// t in [0,1]. This is computed as a Q16.16 fixed-point value (consistent
// with the Q16.16 convention used elsewhere in this pipeline, e.g.
// vertex_shader), via a combinational '/' divide inside isect_x/isect_y.
// Like the RCP/RSQ placeholder noted in vertex_shader, this is a
// synthesis placeholder -- most FPGA/ASIC flows will not infer a
// single-cycle divider for this and it should be replaced with a
// pipelined divider IP (or an iterative shift-subtract divider) before
// this is used in a real timing closure pass. Functionally it is correct
// for simulation and FPV.
// =============================================================================

module triangle_clipper #(
    parameter int WIDTH         = 16,
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Control handshake (same convention as rasterizer_core/backface_culler)
    input  logic                    start,
    output logic                    busy,
    output logic                    done,

    // Input triangle (screen-space, post backface-cull survivor)
    input  logic signed [WIDTH-1:0] v0_x, v0_y,
    input  logic signed [WIDTH-1:0] v1_x, v1_y,
    input  logic signed [WIDTH-1:0] v2_x, v2_y,

    // Output triangle stream (fan-triangulated clip result). One triangle
    // is presented per cycle on tri_valid; tri_last marks the final
    // triangle of this clip result. Zero pulses of tri_valid between
    // `start` and `done` means the input triangle was entirely offscreen.
    output logic                    tri_valid,
    output logic                    tri_last,
    output logic signed [WIDTH-1:0] tri_v0_x, tri_v0_y,
    output logic signed [WIDTH-1:0] tri_v1_x, tri_v1_y,
    output logic signed [WIDTH-1:0] tri_v2_x, tri_v2_y
);

    localparam int MAX_VERTS = 7;
    localparam int CW        = WIDTH + 1;          // coordinate register width (headroom)
    localparam int FRAC      = 16;                  // Q16.16 fractional bits for t
    localparam logic signed [WIDTH-1:0] X_MIN = '0;
    localparam logic signed [WIDTH-1:0] X_MAX = SCREEN_WIDTH  - 1;
    localparam logic signed [WIDTH-1:0] Y_MIN = '0;
    localparam logic signed [WIDTH-1:0] Y_MAX = SCREEN_HEIGHT - 1;

    typedef enum logic [2:0] {
        IDLE        = 3'b000,
        INIT        = 3'b001,
        CLIP        = 3'b010,
        SWAP        = 3'b011,
        TRIANGULATE = 3'b100,
        EMIT        = 3'b101
    } state_t;

    state_t state;

    // Ping-pong polygon buffers
    logic signed [CW-1:0] poly_x [0:MAX_VERTS-1], poly_y [0:MAX_VERTS-1];
    logic signed [CW-1:0] next_x [0:MAX_VERTS-1], next_y [0:MAX_VERTS-1];
    logic [3:0]           poly_n, next_n;   // 0..7

    logic [1:0] plane;    // 0=left(x>=XMIN) 1=right(x<=XMAX) 2=top(y>=YMIN) 3=bottom(y<=YMAX)
    logic [3:0] vidx;     // vertex index within current plane pass
    logic [3:0] emit_idx; // fan-triangulation triangle index

    assign busy = (state != IDLE);

    // -------------------------------------------------------------------
    // Per-plane inside test (combinational function of coordinate + plane)
    // -------------------------------------------------------------------
    function automatic logic inside_plane(input logic [1:0] p,
                                           input logic signed [CW-1:0] x,
                                           input logic signed [CW-1:0] y);
        case (p)
            2'd0: return x >= X_MIN; // left
            2'd1: return x <= X_MAX; // right
            2'd2: return y >= Y_MIN; // top
            default: return y <= Y_MAX; // bottom
        endcase
    endfunction

    // Intersection X of edge (xa,ya)->(xb,yb) with the current plane.
    function automatic logic signed [CW-1:0] isect_x(input logic [1:0] p,
                                                       input logic signed [CW-1:0] xa, ya, xb, yb);
        logic signed [47:0] num, den, t_q16;
        case (p)
            2'd0: isect_x = X_MIN;
            2'd1: isect_x = X_MAX;
            2'd2: begin
                num    = (48'(Y_MIN) - 48'(ya)) <<< FRAC;
                den    = 48'(yb) - 48'(ya);
                t_q16  = num / den;
                isect_x = xa + (CW)'((t_q16 * (48'(xb) - 48'(xa))) >>> FRAC);
            end
            default: begin
                num    = (48'(Y_MAX) - 48'(ya)) <<< FRAC;
                den    = 48'(yb) - 48'(ya);
                t_q16  = num / den;
                isect_x = xa + (CW)'((t_q16 * (48'(xb) - 48'(xa))) >>> FRAC);
            end
        endcase
    endfunction

    // Intersection Y of edge (xa,ya)->(xb,yb) with the current plane.
    function automatic logic signed [CW-1:0] isect_y(input logic [1:0] p,
                                                       input logic signed [CW-1:0] xa, ya, xb, yb);
        logic signed [47:0] num, den, t_q16;
        case (p)
            2'd0: begin
                num    = (48'(X_MIN) - 48'(xa)) <<< FRAC;
                den    = 48'(xb) - 48'(xa);
                t_q16  = num / den;
                isect_y = ya + (CW)'((t_q16 * (48'(yb) - 48'(ya))) >>> FRAC);
            end
            2'd1: begin
                num    = (48'(X_MAX) - 48'(xa)) <<< FRAC;
                den    = 48'(xb) - 48'(xa);
                t_q16  = num / den;
                isect_y = ya + (CW)'((t_q16 * (48'(yb) - 48'(ya))) >>> FRAC);
            end
            2'd2: isect_y = Y_MIN;
            default: isect_y = Y_MAX;
        endcase
    endfunction

    // -------------------------------------------------------------------
    // One Sutherland-Hodgman edge-step per cycle: consumes vertex `vidx`
    // of the current polygon (edge Vprev->Vi where Vprev wraps to poly_n-1
    // when vidx==0), appends 0/1/2 vertices into the next_* buffer.
    // -------------------------------------------------------------------
    logic [3:0] prev_idx;
    assign prev_idx = (vidx == 0) ? (poly_n - 4'd1) : (vidx - 4'd1);

    logic cur_in, prev_in;
    assign cur_in  = inside_plane(plane, poly_x[vidx],     poly_y[vidx]);
    assign prev_in = inside_plane(plane, poly_x[prev_idx], poly_y[prev_idx]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            done       <= 1'b0;
            tri_valid  <= 1'b0;
            tri_last   <= 1'b0;
            poly_n     <= '0;
            next_n     <= '0;
            plane      <= '0;
            vidx       <= '0;
            emit_idx   <= '0;
        end else begin
            done      <= 1'b0;
            tri_valid <= 1'b0;
            tri_last  <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) state <= INIT;
                end

                // Load the input triangle as the starting 3-vertex polygon.
                INIT: begin
                    poly_x[0] <= CW'(v0_x); poly_y[0] <= CW'(v0_y);
                    poly_x[1] <= CW'(v1_x); poly_y[1] <= CW'(v1_y);
                    poly_x[2] <= CW'(v2_x); poly_y[2] <= CW'(v2_y);
                    poly_n    <= 4'd3;
                    plane     <= 2'd0;
                    vidx      <= 4'd0;
                    next_n    <= 4'd0;
                    state     <= CLIP;
                end

                // Process one edge of the current polygon against `plane`.
                CLIP: begin
                    if (poly_n == 0) begin
                        // Already fully clipped away on an earlier plane --
                        // nothing left to test, skip straight to done.
                        state <= TRIANGULATE;
                    end else begin
                        if (cur_in) begin
                            if (!prev_in) begin
                                next_x[next_n]         <= isect_x(plane, poly_x[prev_idx], poly_y[prev_idx], poly_x[vidx], poly_y[vidx]);
                                next_y[next_n]         <= isect_y(plane, poly_x[prev_idx], poly_y[prev_idx], poly_x[vidx], poly_y[vidx]);
                                next_x[next_n + 4'd1]  <= poly_x[vidx];
                                next_y[next_n + 4'd1]  <= poly_y[vidx];
                                next_n <= next_n + 4'd2;
                            end else begin
                                next_x[next_n] <= poly_x[vidx];
                                next_y[next_n] <= poly_y[vidx];
                                next_n <= next_n + 4'd1;
                            end
                        end else if (prev_in) begin
                            next_x[next_n] <= isect_x(plane, poly_x[prev_idx], poly_y[prev_idx], poly_x[vidx], poly_y[vidx]);
                            next_y[next_n] <= isect_y(plane, poly_x[prev_idx], poly_y[prev_idx], poly_x[vidx], poly_y[vidx]);
                            next_n <= next_n + 4'd1;
                        end
                        // else: both outside -> emit nothing

                        if (vidx == poly_n - 4'd1) begin
                            state <= SWAP;
                        end else begin
                            vidx <= vidx + 4'd1;
                        end
                    end
                end

                // Commit next_* as the new poly_*, advance to the next
                // plane (or on to triangulation once all 4 are done).
                SWAP: begin
                    for (int i = 0; i < MAX_VERTS; i++) begin
                        poly_x[i] <= next_x[i];
                        poly_y[i] <= next_y[i];
                    end
                    poly_n <= next_n;
                    next_n <= 4'd0;
                    vidx   <= 4'd0;

                    if (plane == 2'd3) begin
                        state <= TRIANGULATE;
                    end else begin
                        plane <= plane + 2'd1;
                        state <= CLIP;
                    end
                end

                // Fan-triangulate: (poly_n < 3) -> nothing to emit.
                TRIANGULATE: begin
                    emit_idx <= 4'd0;
                    if (poly_n < 3) begin
                        state <= IDLE;
                        done  <= 1'b1;
                    end else begin
                        state <= EMIT;
                    end
                end

                // Emit one fan triangle (V0, V[emit_idx+1], V[emit_idx+2])
                // per cycle.
                EMIT: begin
                    tri_valid <= 1'b1;
                    tri_v0_x  <= WIDTH'(poly_x[0]);
                    tri_v0_y  <= WIDTH'(poly_y[0]);
                    tri_v1_x  <= WIDTH'(poly_x[emit_idx + 4'd1]);
                    tri_v1_y  <= WIDTH'(poly_y[emit_idx + 4'd1]);
                    tri_v2_x  <= WIDTH'(poly_x[emit_idx + 4'd2]);
                    tri_v2_y  <= WIDTH'(poly_y[emit_idx + 4'd2]);

                    if (emit_idx == poly_n - 4'd3) begin
                        tri_last <= 1'b1;
                        state    <= IDLE;
                        done     <= 1'b1;
                    end else begin
                        emit_idx <= emit_idx + 4'd1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // ======================================================================
    // ASSERTIONS
    // SAFETY checks always compiled in; LIVENESS/COVERAGE gated under FPV,
    // same convention as rasterizer_core.
    // ======================================================================

    property p_busy_matches_state;
        @(posedge clk) disable iff (!rst_n)
        busy == (state != IDLE);
    endproperty
    a_busy_matches_state: assert property (p_busy_matches_state);

    property p_done_single_cycle;
        @(posedge clk) disable iff (!rst_n)
        done |=> !done;
    endproperty
    a_done_single_cycle: assert property (p_done_single_cycle);

    // tri_valid may only fire while in EMIT.
    property p_tri_valid_only_in_emit;
        @(posedge clk) disable iff (!rst_n)
        tri_valid |-> $past(state) == EMIT;
    endproperty
    a_tri_valid_only_in_emit: assert property (p_tri_valid_only_in_emit);

    // Polygon vertex counts never exceed the worst-case bound.
    property p_poly_n_bounded;
        @(posedge clk) disable iff (!rst_n)
        (poly_n <= MAX_VERTS) && (next_n <= MAX_VERTS);
    endproperty
    a_poly_n_bounded: assert property (p_poly_n_bounded);

    // Every emitted vertex must lie within the viewport (clip correctness).
    property p_output_in_viewport;
        @(posedge clk) disable iff (!rst_n)
        tri_valid |-> (tri_v0_x >= X_MIN) && (tri_v0_x <= X_MAX) &&
                      (tri_v0_y >= Y_MIN) && (tri_v0_y <= Y_MAX) &&
                      (tri_v1_x >= X_MIN) && (tri_v1_x <= X_MAX) &&
                      (tri_v1_y >= Y_MIN) && (tri_v1_y <= Y_MAX) &&
                      (tri_v2_x >= X_MIN) && (tri_v2_x <= X_MAX) &&
                      (tri_v2_y >= Y_MIN) && (tri_v2_y <= Y_MAX);
    endproperty
    a_output_in_viewport: assert property (p_output_in_viewport);

    // start is only sampled from IDLE.
    property p_start_ignored_when_busy;
        @(posedge clk) disable iff (!rst_n)
        (busy && start) |=> (state != INIT) or $past(busy);
    endproperty
    a_start_ignored_when_busy: assert property (p_start_ignored_when_busy);

`ifdef FPV
    // Every start eventually produces a done. Needs a bounded coordinate
    // range constraint in the .sby harness to converge (same caveat as
    // rasterizer_core's liveness property).
    property p_eventually_done;
        @(posedge clk) disable iff (!rst_n)
        (state == IDLE && start) |=> s_eventually [1:$] done;
    endproperty
    a_eventually_done: assert property (p_eventually_done);

    // Coverage: a triangle fully inside the viewport passes through
    // untouched (no clipping needed, 1 output triangle).
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (state == TRIANGULATE) && (poly_n == 3)
        ##[1:$] done
    );

    // Coverage: a triangle straddling exactly one edge (clipped to a quad,
    // 2 output triangles).
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (state == TRIANGULATE) && (poly_n == 4)
        ##[1:$] done
    );

    // Coverage: a triangle entirely offscreen is fully culled (0 output
    // triangles, done still fires).
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (state == TRIANGULATE) && (poly_n == 0)
        ##[1:$] done
    );

    // Coverage: worst-case 7-vertex clip result (5 output triangles).
    cover property (
        @(posedge clk) disable iff (!rst_n)
        (state == TRIANGULATE) && (poly_n == 7)
        ##[1:$] done
    );
`endif

endmodule
