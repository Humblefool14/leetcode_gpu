`timescale 1ns / 1ps

// =============================================================================
// clock_gate
// -----------------------------------------------------------------------------
// Latch-based integrated clock gate (ICG) with scan/test override.
//
//   clk_out = clk_in & latch(en | test_en)   -- latch transparent while clk_in low
//
// Enable is captured only while clk_in is LOW, so it is frozen for the whole
// HIGH phase and clk_out can never glitch or produce a truncated pulse.
// `en` should come from logic clocked on posedge clk_in (the normal case).
//
// Target selection (compile-time defines):
//   CLKGATE_XILINX              -> BUFGCE global clock buffer (FPGA)
//   CLKGATE_ASIC_ICG=<cellname> -> library ICG cell, ports CK / E / SE / GCK
//   (neither)                   -> behavioral latch + AND (simulation / lint /
//                                  formal); NOT for silicon or FPGA fabric
// =============================================================================

module clock_gate (
    input  logic clk_in,    // free-running source clock
    input  logic en,        // functional enable, active-high
    input  logic test_en,   // scan/test override (force clock on); tie 0 if unused
    output logic clk_out    // gated clock
);

`ifdef CLKGATE_XILINX
    // -------------------------------------------------------------------------
    // FPGA: gating in fabric adds skew onto the clock network. Use the
    // dedicated global buffer; its CE is internally synchronized (glitch-free).
    // -------------------------------------------------------------------------
    BUFGCE u_bufgce (
        .I  (clk_in),
        .CE (en | test_en),
        .O  (clk_out)
    );

`elsif CLKGATE_ASIC_ICG
    // -------------------------------------------------------------------------
    // ASIC: hard-instance the library ICG so STA sees a proper clock-gating
    // check and DFT/ATPG sees the SE pin. Adjust port names to your library.
    // -------------------------------------------------------------------------
    `CLKGATE_ASIC_ICG u_icg (
        .CK  (clk_in),
        .E   (en),
        .SE  (test_en),
        .GCK (clk_out)
    );

`else
    // -------------------------------------------------------------------------
    // Behavioral model
    // -------------------------------------------------------------------------
    logic en_eff;
    logic en_latched;

    assign en_eff = en | test_en;

    // Negative-level latch: transparent while clk_in is low.
    always_latch begin
        if (!clk_in)
            en_latched = en_eff;
    end

    assign clk_out = clk_in & en_latched;

  `ifndef SYNTHESIS
    // Avoid X on clk_out before the first low phase of clk_in.
    initial en_latched = 1'b0;

    // Glitch-freedom: the latched enable must never move during the HIGH
    // phase of clk_in (that is what would chop a clock pulse).
    always @(en_latched) begin
        a_en_stable_while_high: assert final (!clk_in)
            else $error("[clock_gate] en_latched changed while clk_in high");
    end

    // clk_out may only be high when the source clock is high.
    always @(clk_out) begin
        a_out_subset_of_in: assert final (!clk_out || clk_in)
            else $error("[clock_gate] clk_out high while clk_in low");
    end
  `endif

`endif

endmodule
