`timescale 1ns / 1ps

module texture_bram #(
    parameter int TEX_WIDTH  = 256,
    parameter int TEX_HEIGHT = 256,
    parameter int DATA_W     = 24,
    parameter int ADDR_W     = $clog2(TEX_WIDTH * TEX_HEIGHT)
)(
    input  logic              clk,
    // Port A: Write (from texture_loader)
    input  logic              we_a,
    input  logic [ADDR_W-1:0] addr_a,
    input  logic [DATA_W-1:0] wdata_a,
    // Port B: Read (from texture_sampler)
    input  logic [ADDR_W-1:0] addr_b,
    output logic [DATA_W-1:0] rdata_b
);
    localparam int MEM_SIZE = TEX_WIDTH * TEX_HEIGHT;
    (* ram_style = "block" *)
    logic [DATA_W-1:0] mem [0:MEM_SIZE-1];

    // Port A: Synchronous Write
    always_ff @(posedge clk) begin
        if (we_a) begin
            mem[addr_a] <= wdata_a;
        end
    end

    // Port B: Synchronous Read
    // NOTE: no reset on rdata_b is intentional -- resetting this register
    // forces most toolchains to infer LUT-RAM instead of true block RAM.
    always_ff @(posedge clk) begin
        rdata_b <= mem[addr_b];
    end

    // =====================================================================
    // ASSERTIONS
    // =====================================================================
    // No clk/rst_n-based `disable iff` here since this module has no
    // rst_n port; these are combinational-on-inputs checks, immediate
    // where practical, concurrent where a property is clearer.

    // Safety: write address must stay within the physical texture memory
    property p_waddr_in_range;
        @(posedge clk)
        we_a |-> (addr_a < MEM_SIZE);
    endproperty
    a_waddr_in_range: assert property (p_waddr_in_range);

    // Safety: read address must stay within the physical texture memory
    property p_raddr_in_range;
        @(posedge clk)
        1'b1 |-> (addr_b < MEM_SIZE);
    endproperty
    a_raddr_in_range: assert property (p_raddr_in_range);

`ifdef FPV
    // Coverage: characterize read-during-write-same-address behavior.
    // This module has separate always_ff blocks for Port A/B with no
    // forwarding, so a same-address collision returns the OLD value on
    // Port B that cycle (read-old-data / read-first semantics). This
    // cover exists to make that behavior visible in coverage reports
    // rather than leaving it as an untested implicit assumption -- if
    // texture_loader and texture_sampler are ever allowed to run
    // concurrently (i.e. not gated by tex_load_busy), this is the exact
    // scenario that determines whether a stale pixel can be sampled.
    cover property (
        @(posedge clk)
        we_a && (addr_a == addr_b)
    );

    // Coverage: a full sweep read reaching the last valid address
    cover property (
        @(posedge clk)
        (addr_b == MEM_SIZE-1)
    );
`endif

endmodule
