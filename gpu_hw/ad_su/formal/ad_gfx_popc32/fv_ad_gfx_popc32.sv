// fv_ad_gfx_popc32 -- ad_gfx_popc32 (combinational) against a serial count.
module fv_ad_gfx_popc32;
    (* anyconst *) reg [31:0] m;
    wire [5:0] n;
    ad_gfx_popc32 dut (.m(m), .n(n));
    reg [5:0] r;
    integer i;
    always @(*) begin
        r = 6'd0;
        for (i = 0; i < 32; i = i + 1) r = r + {5'd0, m[i]};
        assert (n == r);
    end
endmodule
