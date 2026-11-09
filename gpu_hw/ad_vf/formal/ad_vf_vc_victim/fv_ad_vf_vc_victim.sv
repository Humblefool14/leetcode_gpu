// fv_ad_vf_vc_victim -- the FIFO victim pointer: always < NENTRIES; 0 after reset or flush; after
// adv (no flush) the previous value + 1, wrapping from NENTRIES-1 to 0; unchanged otherwise.
// NE 32 / SW 5 (prove) and NE 5 / SW 3 (prove_n5, not a power of two).
module fv_ad_vf_vc_victim #(parameter NE = 32, parameter SW = 5) (
    input wire clk, input wire rst_n, input wire flush, input wire adv
);
    wire [SW-1:0] ptr;
    ad_vf_vc_victim #(.NENTRIES(NE), .SLOT_W(SW)) dut (.clk(clk), .rst_n(rst_n), .flush(flush), .adv(adv), .ptr(ptr));
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);
    reg p_rst = 1'b1, p_fl = 1'b0, p_adv = 1'b0; reg [SW-1:0] p_ptr = 0;
    always @(posedge clk) begin p_rst <= !rst_n; p_fl <= flush; p_adv <= adv; p_ptr <= ptr; end
    always @(*) if (!init) begin
        a_range: assert (ptr < NE);
        if (p_rst || p_fl)  a_clr:  assert (ptr == 0);
        else if (p_adv)     a_adv:  assert (ptr == ((p_ptr == NE - 1) ? 0 : p_ptr + 1'b1));
        else                a_hold: assert (ptr == p_ptr);
    end
    always @(*) if (!init) c_wrap: cover (!p_rst && !p_fl && p_adv && p_ptr == NE - 1);
endmodule
