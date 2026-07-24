`timescale 1ns / 1ps

module texture_sampler #(
    parameter int TEX_WIDTH  = 256,   // Texture dimensions (must be power of 2)
    parameter int TEX_HEIGHT = 256,
    parameter int TEX_ADDR_W = 16,    // clog2(TEX_WIDTH * TEX_HEIGHT)
    parameter int TEX_DATA_W = 24,    // RGB888
    parameter int UV_W       = 16     // UV coordinate width
)(
    input  logic              clk,
    input  logic              rst_n,

    // Texture memory (loaded by host at boot)
    // Or use dual-port BRAM: Port A = host load, Port B = sampler read

    // From pixel_shader
    input  logic              tex_valid,
    input  logic [UV_W-1:0]   tex_u,      // 0.16 fixed-point, range [0, 1)
    input  logic [UV_W-1:0]   tex_v,

    // To output_merger (or blending stage)
    output logic              samp_valid,
    output logic [TEX_DATA_W-1:0] samp_rgba
);

    // Texture memory (inferred BRAM)
    // In practice, load this via host interface at startup
    (* ram_style = "block" *)
    logic [TEX_DATA_W-1:0] texture_mem [0:TEX_WIDTH*TEX_HEIGHT-1];

    localparam int U_INT_W = $clog2(TEX_WIDTH);   // 8 for TEX_WIDTH=256
    localparam int V_INT_W = $clog2(TEX_HEIGHT);  // 8 for TEX_HEIGHT=256

    logic [U_INT_W-1:0] u_int;
    logic [V_INT_W-1:0] v_int;
    logic [TEX_ADDR_W-1:0] tex_addr;

    // TEX_WIDTH/TEX_HEIGHT are power-of-2 by contract, so scaling a 0.16
    // fixed-point UV coordinate by the texture dimension is just taking its
    // top $clog2(TEX_WIDTH) bits directly -- no multiplier needed, and it
    // avoids the width-truncation bug a naive tex_u * TEX_WIDTH multiply has
    // when the product register isn't sized for the full result.
    assign u_int = tex_u[UV_W-1 -: U_INT_W];
    assign v_int = tex_v[UV_W-1 -: V_INT_W];

    // Address = v_int * TEX_WIDTH + u_int. Since TEX_WIDTH == 2**U_INT_W,
    // this is exactly a concatenation, not real multiply hardware.
    assign tex_addr = {v_int, u_int};

    // Registered read (1-cycle latency)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            samp_valid <= 1'b0;
            samp_rgba  <= '0;
        end else begin
            if (tex_valid) begin
                samp_rgba <= texture_mem[tex_addr];
            end
            samp_valid <= tex_valid;
        end
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================

    // Elaboration-time check: TEX_ADDR_W must actually cover the full
    // texture address range implied by TEX_WIDTH/TEX_HEIGHT.
    initial begin
        assert (TEX_ADDR_W >= U_INT_W + V_INT_W)
        else $fatal(1, "TEX_ADDR_W=%0d too small for TEX_WIDTH=%0d x TEX_HEIGHT=%0d",
                    TEX_ADDR_W, TEX_WIDTH, TEX_HEIGHT);
    end

    // Safety: pipeline latency is exactly 1 cycle
    property p_one_cycle_latency;
        @(posedge clk) disable iff (!rst_n)
        tex_valid |=> samp_valid;
    endproperty
    a_one_cycle_latency: assert property (p_one_cycle_latency);

    // Safety: computed address never exceeds the texture memory bound
    property p_addr_in_range;
        @(posedge clk) disable iff (!rst_n)
        tex_valid |-> (tex_addr < TEX_WIDTH * TEX_HEIGHT);
    endproperty
    a_addr_in_range: assert property (p_addr_in_range);

`ifdef FPV
    cover property (@(posedge clk) disable iff (!rst_n)
        tex_valid && (u_int == '0) && (v_int == '0));
    cover property (@(posedge clk) disable iff (!rst_n)
        tex_valid && (u_int == {U_INT_W{1'b1}}) && (v_int == {V_INT_W{1'b1}}));
`endif

endmodule
