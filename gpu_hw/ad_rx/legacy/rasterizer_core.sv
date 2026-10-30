`timescale 1ns / 1ps
// ============================================================================
// rasterizer_core -- fixed version (see the ad_rx doc, section 4, "your blocks").
//
// Fixes:
//  F1  widths: a 16-bit coordinate difference needs 17 bits (dX/dY were 16 and
//      wrapped); a product of two 17-bit values needs 34; E = 2 products + 1
//      needs EW = 36 bits (edge accumulators were 32 and overflowed).
//  F2  coverage at the pixel CENTRE: the edge functions are evaluated in
//      half-pixel units, 2E(x+1/2, y+1/2) (the old code sampled the corner).
//  F3  both windings: a clockwise triangle has its edges negated (the old code
//      rejected every clockwise triangle); CULL_CW = 1 culls them instead.
//  F4  top-left rule: pixels exactly on a right or bottom edge are excluded
//      (bias 1), so two triangles sharing an edge never both cover a pixel.
//  F5  no multiplies per row: the row start is an accumulator (+dY per pixel,
//      -dX per row); the products happen once, in SEED.
//  F6  the bounding box is clipped to [0, SCREEN_W) x [0, SCREEN_H): the old
//      code emitted negative coordinates on unsigned frag_x/frag_y.
//  F7  degenerate (zero-area) triangles finish without scanning.
//  F8  synchronous active-low reset (the RX convention).
//  F9  p_start_ignored_when_busy was vacuous ($past(busy) is implied by its own
//      antecedent); rewritten.  The "no pixel inside" cover now requires no frag.
// ============================================================================
module rasterizer_core #(
  parameter int SCREEN_W = 640,
  parameter int SCREEN_H = 480,
  parameter bit CULL_CW  = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  output logic        busy,
  output logic        done,
  input  logic signed [15:0] v0_x, input logic signed [15:0] v0_y,
  input  logic signed [15:0] v1_x, input logic signed [15:0] v1_y,
  input  logic signed [15:0] v2_x, input logic signed [15:0] v2_y,
  output logic        frag_valid,
  output logic [15:0] frag_x,
  output logic [15:0] frag_y,
  output logic signed [35:0] frag_e0,                // 2E at the centre (half-pixel units)
  output logic signed [35:0] frag_e1,
  output logic signed [35:0] frag_e2
);
  localparam int EW = 36;

  typedef enum logic [2:0] {IDLE, SETUP, SEED, SCAN} state_t;
  state_t state;

  logic signed [16:0] min_x, max_x, min_y, max_y, curr_x, curr_y;
  logic signed [16:0] dX [3], dY [3];               // edge deltas (F1: 17 bits)
  logic signed [16:0] px [3], py [3];               // edge start points
  logic signed [EW-1:0] e [3], erow [3];
  logic signed [EW-1:0] bias [3];
  logic signed [33:0]   area;

  function automatic logic signed [16:0] min3(input logic signed [16:0] a, b, c);
    return (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
  endfunction
  function automatic logic signed [16:0] max3(input logic signed [16:0] a, b, c);
    return (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
  endfunction

  logic signed [16:0] x0, y0, x1, y1, x2, y2;
  assign x0 = v0_x; assign y0 = v0_y; assign x1 = v1_x; assign y1 = v1_y; assign x2 = v2_x; assign y2 = v2_y;

  assign busy = (state != IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE; done <= 1'b0; frag_valid <= 1'b0; curr_x <= '0; curr_y <= '0;
    end else begin
      frag_valid <= 1'b0;
      done       <= 1'b0;
      case (state)
        IDLE: if (start) state <= SETUP;

        SETUP: begin
          logic signed [16:0] bx0, by0, bx1, by1;
          // F6: box clipped to the screen
          bx0 = min3(x0, x1, x2); bx1 = max3(x0, x1, x2);
          by0 = min3(y0, y1, y2); by1 = max3(y0, y1, y2);
          min_x <= (bx0 < 0) ? 17'sd0 : bx0;
          min_y <= (by0 < 0) ? 17'sd0 : by0;
          max_x <= (bx1 > SCREEN_W - 1) ? 17'(SCREEN_W - 1) : bx1;
          max_y <= (by1 > SCREEN_H - 1) ? 17'(SCREEN_H - 1) : by1;
          area  <= (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
          px[0] <= x0; py[0] <= y0; px[1] <= x1; py[1] <= y1; px[2] <= x2; py[2] <= y2;
          dX[0] <= x1 - x0; dY[0] <= y1 - y0;
          dX[1] <= x2 - x1; dY[1] <= y2 - y1;
          dX[2] <= x0 - x2; dY[2] <= y0 - y2;
          state <= SEED;
        end

        SEED: begin
          // F7 zero area, F3 culling, F6 empty clipped box
          if (area == 0 || (CULL_CW && area < 0) || min_x > max_x || min_y > max_y) begin
            state <= IDLE; done <= 1'b1;
          end else begin
            for (int i = 0; i < 3; i++) begin
              // 2E at (min_x + 1/2, min_y + 1/2), F2; edges negated for clockwise, F3
              logic signed [EW-1:0] v;
              logic signed [EW-1:0] a, b;
              a = (area > 0) ? -EW'(dY[i]) : EW'(dY[i]);          // E = a (x - px) + b (y - py)
              b = (area > 0) ?  EW'(dX[i]) : -EW'(dX[i]);
              v = a * EW'(2 * (min_x - px[i]) + 1) + b * EW'(2 * (min_y - py[i]) + 1);
              // F4: top-left edges (a > 0, or a == 0 and b > 0) keep E = 0
              bias[i] <= ((a > 0) || (a == 0 && b > 0)) ? '0 : EW'(1);
              e[i]    <= v;
              erow[i] <= v;
            end
            curr_x <= min_x; curr_y <= min_y;
            state <= SCAN;
          end
        end

        SCAN: begin
          if ((e[0] - bias[0] >= 0) && (e[1] - bias[1] >= 0) && (e[2] - bias[2] >= 0)) begin
            frag_valid <= 1'b1;
            frag_x <= curr_x[15:0]; frag_y <= curr_y[15:0];
            frag_e0 <= e[0]; frag_e1 <= e[1]; frag_e2 <= e[2];
          end
          // F5: steps only; a = -dY (ccw) per pixel in x, b = dX per pixel in y, doubled units
          if (curr_x < max_x) begin
            curr_x <= curr_x + 1;
            for (int i = 0; i < 3; i++) e[i] <= e[i] + 2 * ((area > 0) ? -EW'(dY[i]) : EW'(dY[i]));
          end else if (curr_y < max_y) begin
            curr_x <= min_x; curr_y <= curr_y + 1;
            for (int i = 0; i < 3; i++) begin
              erow[i] <= erow[i] + 2 * ((area > 0) ? EW'(dX[i]) : -EW'(dX[i]));
              e[i]    <= erow[i] + 2 * ((area > 0) ? EW'(dX[i]) : -EW'(dX[i]));
            end
          end else begin
            state <= IDLE; done <= 1'b1;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end

  // ======================================================================
  // ASSERTIONS (SVA; SAFETY always, LIVENESS/COVER under FPV)
  // ======================================================================
  a_busy_matches_state: assert property (@(posedge clk) disable iff (!rst_n) busy == (state != IDLE));
  a_done_single_cycle:  assert property (@(posedge clk) disable iff (!rst_n) done |=> !done);
  a_frag_only_from_scan: assert property (@(posedge clk) disable iff (!rst_n) frag_valid |-> $past(state) == SCAN);
  a_setup_one_cycle:    assert property (@(posedge clk) disable iff (!rst_n) state == SETUP |=> state == SEED);
  a_curr_within_bbox:   assert property (@(posedge clk) disable iff (!rst_n)
                          state == SCAN |-> curr_x >= min_x && curr_x <= max_x && curr_y >= min_y && curr_y <= max_y);
  a_on_screen:          assert property (@(posedge clk) disable iff (!rst_n)
                          frag_valid |-> frag_x < SCREEN_W && frag_y < SCREEN_H);
  a_idle_holds:         assert property (@(posedge clk) disable iff (!rst_n) (state == IDLE && !start) |=> state == IDLE);
  // F9: SETUP is entered only from IDLE: a start while busy never restarts the scan
  a_start_ignored_when_busy: assert property (@(posedge clk) disable iff (!rst_n)
                          (state != IDLE && start) |=> state != SETUP);
`ifdef FPV
  a_eventually_done: assert property (@(posedge clk) disable iff (!rst_n) (state == IDLE && start) |=> s_eventually done);
  c_origin_bbox:     cover property (@(posedge clk) disable iff (!rst_n) (state == SEED) && min_x == 0 && min_y == 0 ##[1:$] done);
  c_one_pixel:       cover property (@(posedge clk) disable iff (!rst_n) (state == SEED) && min_x == max_x && min_y == max_y ##[1:$] done);
  c_no_pixel:        cover property (@(posedge clk) disable iff (!rst_n) (state == SCAN) ##1 (!frag_valid)[*1:$] ##0 done);
`endif
endmodule
