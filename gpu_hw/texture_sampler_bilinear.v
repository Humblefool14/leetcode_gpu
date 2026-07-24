`timescale 1ns / 1ps

module texture_sampler_bilinear #(
    parameter int TEX_WIDTH  = 256,   // must be power of 2
    parameter int TEX_HEIGHT = 256,
    parameter int TEX_DATA_W = 24,
    parameter int UV_W       = 16
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic              tex_valid,
    input  logic [UV_W-1:0]   tex_u, tex_v,
    output logic              samp_valid,
    output logic [TEX_DATA_W-1:0] samp_rgba
);

    (* ram_style = "block" *)
    logic [TEX_DATA_W-1:0] texture_mem [0:TEX_WIDTH*TEX_HEIGHT-1];

    localparam int U_INT_W = $clog2(TEX_WIDTH);   // 8
    localparam int V_INT_W = $clog2(TEX_HEIGHT);  // 8
    localparam int FRAC_W  = 8;                   // fractional precision used for blend weights

    initial begin
        assert (UV_W >= U_INT_W + FRAC_W)
        else $fatal(1, "UV_W=%0d too small for U_INT_W=%0d + FRAC_W=%0d", UV_W, U_INT_W, FRAC_W);
        assert (UV_W >= V_INT_W + FRAC_W)
        else $fatal(1, "UV_W=%0d too small for V_INT_W=%0d + FRAC_W=%0d", UV_W, V_INT_W, FRAC_W);
    end

    // =====================================================================
    // Stage 0: Split UV into integer texel coords + fractional blend weights
    // (TEX_WIDTH/TEX_HEIGHT power-of-2 -> direct bit-slice, no multiply,
    //  no truncation risk from an undersized u_scaled/v_scaled register)
    // =====================================================================
    logic [U_INT_W-1:0] u_base, u_next;
    logic [V_INT_W-1:0] v_base, v_next;
    logic [FRAC_W-1:0]  u_frac, v_frac;

    assign u_base = tex_u[UV_W-1 -: U_INT_W];
    assign v_base = tex_v[UV_W-1 -: V_INT_W];
    assign u_frac = tex_u[UV_W-U_INT_W-1 -: FRAC_W];
    assign v_frac = tex_v[UV_W-V_INT_W-1 -: FRAC_W];

    // Clamp at texture edge instead of wrapping (avoids right/bottom-edge
    // seam artifact from a naive u_base+1 rolling over to 0)
    assign u_next = (u_base == TEX_WIDTH-1)  ? u_base : (u_base + 1'b1);
    assign v_next = (v_base == TEX_HEIGHT-1) ? v_base : (v_base + 1'b1);

    // =====================================================================
    // Stage 1: Fetch 4 texels, register fractional weights + valid
    // =====================================================================
    logic [TEX_DATA_W-1:0] texel_00, texel_01, texel_10, texel_11;
    logic [FRAC_W-1:0]     frac_u_reg, frac_v_reg;
    logic                  s1_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid   <= 1'b0;
            texel_00   <= '0;
            texel_01   <= '0;
            texel_10   <= '0;
            texel_11   <= '0;
            frac_u_reg <= '0;
            frac_v_reg <= '0;
        end else begin
            s1_valid <= tex_valid;
            if (tex_valid) begin
                // TEX_WIDTH power-of-2 -> row*TEX_WIDTH+col is exactly a
                // concatenation, same trick as texture_sampler (nearest).
                texel_00 <= texture_mem[{v_base, u_base}];  // top-left
                texel_01 <= texture_mem[{v_base, u_next}];  // top-right
                texel_10 <= texture_mem[{v_next, u_base}];  // bottom-left
                texel_11 <= texture_mem[{v_next, u_next}];  // bottom-right
                frac_u_reg <= u_frac;
                frac_v_reg <= v_frac;
            end
        end
    end

    // =====================================================================
    // Stage 2: Bilinear interpolation
    // C = (1-v)*[(1-u)*C00 + u*C01] + v*[(1-u)*C10 + u*C11]
    // =====================================================================
    logic [7:0] inv_frac_u, inv_frac_v;
    assign inv_frac_u = 8'd255 - frac_u_reg;
    assign inv_frac_v = 8'd255 - frac_v_reg;

    // inv_frac_u + frac_u_reg == 255 always (complementary by construction),
    // so each weighted sum is bounded by 255*255 = 65025 -> fits in 16 bits.
    logic [15:0] r_top, r_bot, g_top, g_bot, b_top, b_bot;

    always_comb begin
        r_top = (inv_frac_u * texel_00[23:16]) + (frac_u_reg * texel_01[23:16]);
        r_bot = (inv_frac_u * texel_10[23:16]) + (frac_u_reg * texel_11[23:16]);
        g_top = (inv_frac_u * texel_00[15:8])  + (frac_u_reg * texel_01[15:8]);
        g_bot = (inv_frac_u * texel_10[15:8])  + (frac_u_reg * texel_11[15:8]);
        b_top = (inv_frac_u * texel_00[7:0])   + (frac_u_reg * texel_01[7:0]);
        b_bot = (inv_frac_u * texel_10[7:0])   + (frac_u_reg * texel_11[7:0]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            samp_valid <= 1'b0;
            samp_rgba  <= '0;
        end else begin
            samp_valid <= s1_valid;   // tracks the SAME pulse the data below is derived from
            if (s1_valid) begin
                samp_rgba[23:16] <= (inv_frac_v * r_top[15:8] + frac_v_reg * r_bot[15:8]) >> 8;
                samp_rgba[15:8]  <= (inv_frac_v * g_top[15:8] + frac_v_reg * g_bot[15:8]) >> 8;
                samp_rgba[7:0]   <= (inv_frac_v * b_top[15:8] + frac_v_reg * b_bot[15:8]) >> 8;
            end
        end
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Safety: pipeline latency is exactly 2 cycles, data and valid in lockstep
    property p_two_cycle_latency;
        @(posedge clk) disable iff (!rst_n)
        tex_valid |=> ##1 samp_valid;
    endproperty
    a_two_cycle_latency: assert property (p_two_cycle_latency);

    // Safety: texel addresses never index outside texture memory
    property p_addr_in_range;
        @(posedge clk) disable iff (!rst_n)
        tex_valid |-> ({v_base, u_base} < TEX_WIDTH*TEX_HEIGHT) &&
                       ({v_next, u_next} < TEX_WIDTH*TEX_HEIGHT);
    endproperty
    a_addr_in_range: assert property (p_addr_in_range);

`ifdef FPV
    // Coverage: actual blending occurs (both fractional weights non-zero,
    // i.e. not silently degenerating to nearest-neighbor as the old bug did)
    cover property (@(posedge clk) disable iff (!rst_n)
        tex_valid && (u_frac != 0) && (v_frac != 0));

    // Coverage: edge clamp path taken (u_base/v_base at texture boundary)
    cover property (@(posedge clk) disable iff (!rst_n)
        tex_valid && (u_base == TEX_WIDTH-1));
    cover property (@(posedge clk) disable iff (!rst_n)
        tex_valid && (v_base == TEX_HEIGHT-1));
`endif

endmodule
