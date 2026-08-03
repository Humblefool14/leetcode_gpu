`timescale 1ns / 1ps
import tess_common_pkg::*;

// Fixed-function tessellator.
//
// IMPORTANT SIMPLIFICATION: this implements *uniform/regular* subdivision --
// one integer level for the quad domain's two axes (from tess_level_inner),
// or one integer level for the triangle domain (from tess_level_outer[0],
// assumed uniform across edges). It does NOT implement the full GL/D3D spec
// algorithm, which independently subdivides each edge at its own outer level
// (with fractional_odd/fractional_even spacing) and stitches a crack-free
// transition to a differently-tessellated interior. That algorithm is
// substantially more hardware (per-edge LUTs, a stitching ring generator,
// degenerate-triangle collapse logic) and is a natural follow-up if you need
// spec-exact behavior (e.g. adjacent patches with different edge tess levels
// must not crack). This block is suitable where all edges of a patch share a
// level (common for e.g. uniform terrain tessellation) or where minor
// cracking is acceptable.
//
// Two-phase streaming output:
//   Phase 1 (POINTS): emits every domain point (u,v,w) with a sequential
//     point_idx, assigned in generation order (row-major). No closed-form
//     index arithmetic is needed downstream -- indices are just "the order
//     points came out in", which is also the order TES should consume them.
//   Phase 2 (INDICES): emits one triangle (as three point_idx references)
//     per cycle it's accepted.
//
// Triangle-domain row bookkeeping: row start indices are captured into a
// small internal table (row_start[]) during Phase 1 and reused during Phase 2
// to compute neighbor-row references, avoiding triangular-number division in
// hardware.
module tess_fixed_function #(
    parameter int MAX_LEVEL   = 32,             // clamp for both u/v (quad) and level (tri)
    parameter int POINT_IDX_W = 11,             // must hold (MAX_LEVEL+1)^2 - 1
    parameter int LVL_W       = $clog2(MAX_LEVEL+1)
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic               start,
    input  logic                domain_is_quad,   // 0 = triangle domain, 1 = quad domain
    input  logic [DATA_W-1:0]   tess_level_outer [0:3],  // Q16.16; only [0] used (tri, uniform)
    input  logic [DATA_W-1:0]   tess_level_inner [0:1],  // Q16.16; [0]=level_u,[1]=level_v (quad)
    output logic                busy,

    output logic                point_valid,
    input  logic                point_ready,
    output logic [POINT_IDX_W-1:0] point_idx,
    output logic [DATA_W-1:0]   point_u,
    output logic [DATA_W-1:0]   point_v,
    output logic [DATA_W-1:0]   point_w,          // barycentric 3rd coord (tri); 0 for quad
    output logic                points_done,       // 1-cycle pulse, total_points valid this cycle
    output logic [POINT_IDX_W-1:0] total_points,

    output logic                tri_valid,
    input  logic                tri_ready,
    output logic [POINT_IDX_W-1:0] tri_i0, tri_i1, tri_i2,
    output logic                tris_done,         // 1-cycle pulse, total_tris valid this cycle
    output logic [POINT_IDX_W-1:0] total_tris
);

    // ---- level conversion: round Q16.16 to nearest int, clamp [1, MAX_LEVEL] ----
    function automatic logic [LVL_W-1:0] fp_to_level(logic [DATA_W-1:0] fp);
        logic [DATA_W-1:0] rounded;
        int unsigned lvl;
        begin
            rounded = fp + (ONE_FP >> 1);
            lvl = rounded >> FRAC_BITS;
            if (lvl < 1) lvl = 1;
            if (lvl > MAX_LEVEL) lvl = MAX_LEVEL;
            return lvl[LVL_W-1:0];
        end
    endfunction

    logic [LVL_W-1:0] level_u, level_v, level_tri;
    assign level_u   = fp_to_level(tess_level_inner[0]);
    assign level_v   = fp_to_level(tess_level_inner[1]);
    assign level_tri = fp_to_level(tess_level_outer[0]);

    // row_start table: for the triangle domain, row j (j=0..level_tri) has
    // (level_tri - j + 1) points; row_start[j] = index of first point in row j.
    logic [POINT_IDX_W-1:0] row_start [0:MAX_LEVEL];

    typedef enum logic [2:0] {
        ST_IDLE, ST_PTS_QUAD, ST_PTS_TRI, ST_PTS_DONE,
        ST_IDX_QUAD, ST_IDX_TRI, ST_IDX_DONE
    } state_t;
    state_t state, next_state;

    // quad point-gen counters
    logic [LVL_W-1:0] q_row, q_col;
    // tri point-gen counters
    logic [LVL_W-1:0] t_row, t_col;
    logic [POINT_IDX_W-1:0] pt_cnt;

    // quad index-gen counters
    logic [LVL_W-1:0] qi_row, qi_col;
    logic              qi_second_tri;
    // tri index-gen counters
    logic [LVL_W-1:0] ti_row, ti_col;
    logic              ti_second_tri;
    logic [POINT_IDX_W-1:0] tri_cnt;

    logic [LVL_W-1:0] cur_level, cur_level_v;
    assign cur_level   = domain_is_quad ? level_u : level_tri;
    assign cur_level_v = domain_is_quad ? level_v : level_tri;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            q_row <= '0; q_col <= '0; t_row <= '0; t_col <= '0; pt_cnt <= '0;
            qi_row <= '0; qi_col <= '0; qi_second_tri <= 1'b0;
            ti_row <= '0; ti_col <= '0; ti_second_tri <= 1'b0; tri_cnt <= '0;
            total_points <= '0; total_tris <= '0;
        end else begin
            state <= next_state;

            unique case (state)
                ST_IDLE: if (start) begin
                    pt_cnt <= '0;
                    q_row <= '0; q_col <= '0;
                    t_row <= '0; t_col <= '0;
                end

                ST_PTS_QUAD: if (point_ready) begin
                    row_start[q_row] <= pt_cnt; // harmless redundant write per row, cheap
                    pt_cnt <= pt_cnt + 1'b1;
                    if (q_col == level_u) begin
                        q_col <= '0;
                        q_row <= q_row + 1'b1;
                    end else begin
                        q_col <= q_col + 1'b1;
                    end
                end

                ST_PTS_TRI: if (point_ready) begin
                    if (t_col == 0) row_start[t_row] <= pt_cnt;
                    pt_cnt <= pt_cnt + 1'b1;
                    if (t_col == (level_tri - t_row)) begin
                        t_col <= '0;
                        t_row <= t_row + 1'b1;
                    end else begin
                        t_col <= t_col + 1'b1;
                    end
                end

                ST_PTS_DONE: begin
                    total_points <= pt_cnt;
                    tri_cnt <= '0;
                    qi_row <= '0; qi_col <= '0; qi_second_tri <= 1'b0;
                    ti_row <= '0; ti_col <= '0; ti_second_tri <= 1'b0;
                end

                ST_IDX_QUAD: if (tri_ready) begin
                    tri_cnt <= tri_cnt + 1'b1;
                    if (!qi_second_tri) begin
                        qi_second_tri <= 1'b1;
                    end else begin
                        qi_second_tri <= 1'b0;
                        if (qi_col == level_u - 1) begin
                            qi_col <= '0;
                            qi_row <= qi_row + 1'b1;
                        end else begin
                            qi_col <= qi_col + 1'b1;
                        end
                    end
                end

                ST_IDX_TRI: if (tri_ready) begin
                    tri_cnt <= tri_cnt + 1'b1;
                    // row ti_row has (level_tri-ti_row+1) pts, row ti_row+1 has (level_tri-ti_row) pts.
                    // "upward" cells: level_tri-ti_row of them; "downward" cells: level_tri-ti_row-1.
                    if (!ti_second_tri && (ti_col < (level_tri - ti_row - 1))) begin
                        // this cell also has a downward triangle -> emit it next
                        ti_second_tri <= 1'b1;
                    end else begin
                        ti_second_tri <= 1'b0;
                        if (ti_col == (level_tri - ti_row - 1)) begin
                            ti_col <= '0;
                            ti_row <= ti_row + 1'b1;
                        end else begin
                            ti_col <= ti_col + 1'b1;
                        end
                    end
                end

                ST_IDX_DONE: total_tris <= tri_cnt;

                default: ;
            endcase
        end
    end

    always_comb begin
        next_state = state;
        busy = 1'b1;
        case (state)
            ST_IDLE:      begin busy = 1'b0; if (start) next_state = domain_is_quad ? ST_PTS_QUAD : ST_PTS_TRI; end
            ST_PTS_QUAD:  if (point_ready && q_row == level_v && q_col == level_u) next_state = ST_PTS_DONE;
            ST_PTS_TRI:   if (point_ready && t_row == level_tri && t_col == 0)     next_state = ST_PTS_DONE;
            ST_PTS_DONE:  next_state = domain_is_quad ? ST_IDX_QUAD : ST_IDX_TRI;
            ST_IDX_QUAD:  if (tri_ready && qi_second_tri && qi_row == level_v-1 && qi_col == level_u-1) next_state = ST_IDX_DONE;
            ST_IDX_TRI:   if (tri_ready && !ti_second_tri && ti_row == level_tri-1 && ti_col == 0 &&
                               (level_tri - ti_row - 1) == 0) next_state = ST_IDX_DONE;
            ST_IDX_DONE:  next_state = ST_IDLE;
            default:      next_state = ST_IDLE;
        endcase
    end

    // ---- point outputs ----
    always_comb begin
        point_valid = (state == ST_PTS_QUAD) || (state == ST_PTS_TRI);
        point_idx   = pt_cnt;
        points_done = (state == ST_PTS_DONE);
        if (state == ST_PTS_QUAD) begin
            point_u = q_col * (ONE_FP / (level_u == 0 ? 1 : level_u)); // note: integer div, see caveat below
            point_v = q_row * (ONE_FP / (level_v == 0 ? 1 : level_v));
            point_w = '0;
        end else begin
            point_u = t_col * (ONE_FP / (level_tri == 0 ? 1 : level_tri));
            point_v = t_row * (ONE_FP / (level_tri == 0 ? 1 : level_tri));
            point_w = ONE_FP - point_u - point_v;
        end
    end

    // ---- triangle-index outputs ----
    logic [POINT_IDX_W-1:0] q_stride;
    assign q_stride = level_u + 1;

    always_comb begin
        tri_valid = (state == ST_IDX_QUAD) || (state == ST_IDX_TRI);
        tris_done = (state == ST_IDX_DONE);
        tri_i0 = '0; tri_i1 = '0; tri_i2 = '0;

        if (state == ST_IDX_QUAD) begin
            automatic logic [POINT_IDX_W-1:0] i00, i10, i01, i11;
            i00 = qi_row * q_stride + qi_col;
            i10 = i00 + 1;
            i01 = i00 + q_stride;
            i11 = i01 + 1;
            if (!qi_second_tri) begin
                tri_i0 = i00; tri_i1 = i10; tri_i2 = i11;
            end else begin
                tri_i0 = i00; tri_i1 = i11; tri_i2 = i01;
            end
        end else if (state == ST_IDX_TRI) begin
            automatic logic [POINT_IDX_W-1:0] rs0, rs1;
            rs0 = row_start[ti_row];
            rs1 = row_start[ti_row + 1];
            if (!ti_second_tri) begin
                // upward triangle
                tri_i0 = rs0 + ti_col;
                tri_i1 = rs0 + ti_col + 1;
                tri_i2 = rs1 + ti_col;
            end else begin
                // downward triangle
                tri_i0 = rs0 + ti_col + 1;
                tri_i1 = rs1 + ti_col + 1;
                tri_i2 = rs1 + ti_col;
            end
        end
    end

    assert property (@(posedge clk) disable iff (!rst_n)
        (state == ST_PTS_QUAD || state == ST_PTS_TRI) |-> ##[1:2050] state == ST_PTS_DONE);

endmodule
