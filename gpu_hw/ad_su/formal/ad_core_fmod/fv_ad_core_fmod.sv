// fv_ad_core_fmod -- ad_su_fmod (NPHYS 2) against tools/gsi1model.py fmod(): FPU/XU abs
// then negate on bit 31, PK on bits 15 and 31, other units unchanged.
module fv_ad_core_fmod (input wire clk);
    (* anyconst *) reg [3:0] unit; (* anyconst *) reg ng, ab; (* anyconst *) reg [63:0] din;
    wire [63:0] dout;
    ad_su_fmod #(.NPHYS(2)) dut (.unit(unit), .neg(ng), .abs_(ab), .din(din), .dout(dout));
    integer i; reg [31:0] v;
    always @(*) for (i = 0; i < 2; i = i + 1) begin
        v = din[32*i +: 32];
        if (unit == 2 || unit == 4) begin if (ab) v[31] = 0; if (ng) v[31] = !v[31]; end
        else if (unit == 3) begin if (ab) begin v[31] = 0; v[15] = 0; end if (ng) begin v[31] = !v[31]; v[15] = !v[15]; end end
        assert (dout[32*i +: 32] == v);
    end
endmodule
