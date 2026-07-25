`timescale 1ns / 1ps

module texture_sampler #(
    parameter int TEX_WIDTH  = 256,
    parameter int TEX_HEIGHT = 256,
    parameter int TEX_DATA_W = 24,
    parameter int UV_W       = 16,
    parameter bit BILINEAR   = 0,   // NOTE: not yet implemented (nearest-neighbor only below)

    // Derived. Declared in the parameter port list (not the body) so it can
    // legally be used to size the I/O ports below.
    localparam int TEX_ADDR_W = $clog2(TEX_WIDTH * TEX_HEIGHT),
    localparam int U_INT_W    = $clog2(TEX_WIDTH),
    localparam int V_INT_W    = $clog2(TEX_HEIGHT)
)(
    input  logic              clk,
    input  logic              rst_n,

    // From pixel_shader
    input  logic              tex_valid,
    input  logic [UV_W-1:0]   tex_u, tex_v,

    // To color_modulate
    output logic              samp_valid,
    output logic [TEX_DATA_W-1:0] samp_rgba,

    // To texture_bram (Port B read)
    output logic [TEX_ADDR_W-1:0] bram_addr,
    input  logic [TEX_DATA_W-1:0] bram_rdata
);

    // -------------------------------------------------------------------
    // UV -> texel address conversion
    //
    // tex_u/tex_v are assumed UQ0.UV_W (unsigned normalized, value in
    // [0,1)). Multiplying by TEX_WIDTH/TEX_HEIGHT produces a
    // UQ(U_INT_W).(UV_W) fixed-point value, i.e. UV_W + U_INT_W bits
    // TOTAL. The product must be held in a register that wide, or the
    // integer (texel-index) bits get silently truncated away.
    // -------------------------------------------------------------------
    logic [UV_W+U_INT_W-1:0] u_scaled;
    logic [UV_W+V_INT_W-1:0] v_scaled;
    logic [U_INT_W-1:0]      u_int;
    logic [V_INT_W-1:0]      v_int;

    assign u_scaled = tex_u * TEX_WIDTH;
    assign v_scaled = tex_v * TEX_HEIGHT;

    // Top U_INT_W/V_INT_W bits of the fixed-point product are the
    // integer part == texel index.
    assign u_int = u_scaled[UV_W+U_INT_W-1 -: U_INT_W];
    assign v_int = v_scaled[UV_W+V_INT_W-1 -: V_INT_W];

    // Calculate BRAM read address (combinational, presented same cycle
    // as tex_valid)
    assign bram_addr = (v_int * TEX_WIDTH) + u_int;

    // -------------------------------------------------------------------
    // Output pipeline
    //
    // texture_bram Port B is itself registered (1-cycle read latency):
    // address presented at cycle t -> bram_rdata valid at cycle t+1.
    // That register IS the data-path pipeline stage; we must not add a
    // second one here or samp_rgba will lag samp_valid by an extra
    // cycle. samp_rgba is therefore a combinational passthrough of
    // bram_rdata; only the valid flag needs its own 1-cycle register to
    // align with the BRAM's latency.
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            samp_valid <= 1'b0;
        end else begin
            samp_valid <= tex_valid;
        end
    end

    assign samp_rgba = bram_rdata;

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Safety: samp_valid must appear exactly 1 cycle after tex_valid
    property p_valid_latency;
        @(posedge clk) disable iff (!rst_n)
        tex_valid |=> samp_valid;
    endproperty
    a_valid_latency: assert property (p_valid_latency);

    // Safety: bram_addr must stay within the texture's address range
    property p_addr_in_range;
        @(posedge clk) disable iff (!rst_n)
        tex_valid |-> (bram_addr < (TEX_WIDTH * TEX_HEIGHT));
    endproperty
    a_addr_in_range: assert property (p_addr_in_range);

`ifdef FPV
    // Coverage: sample near the far corner of the texture (large u_int/v_int)
    cover property (
        @(posedge clk) disable iff (!rst_n)
        tex_valid && (u_int == TEX_WIDTH-1) && (v_int == TEX_HEIGHT-1)
    );

    // Coverage: sample the origin texel
    cover property (
        @(posedge clk) disable iff (!rst_n)
        tex_valid && (u_int == 0) && (v_int == 0)
    );
`endif

endmodule
