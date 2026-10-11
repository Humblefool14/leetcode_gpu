// Behavioral isolation cell — CLAMP is "0", "1", or "LATCH"
module isolation_cell #(
  parameter string CLAMP = "0"
) (
  input  logic iso,
  input  logic in,
  output logic out
);

  generate
    if (CLAMP == "LATCH") begin : g_latch
      logic held = 1'b0;            // known value even if iso=1 from time 0

      always_latch
        if (!iso) held = in;        // transparent while domain is on, holds when iso rises

      assign out = iso ? held : in;
    end
    else if (CLAMP == "1") begin : g_clamp1
      assign out = iso ? 1'b1 : in;
    end
    else begin : g_clamp0           // "0" (default)
      assign out = iso ? 1'b0 : in;
    end
  endgenerate

endmodule
