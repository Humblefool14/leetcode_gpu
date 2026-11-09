// ad_vf_vc_victim -- FIFO victim pointer of the vertex cache.  flush (or reset) sets it to 0;
// adv (a commit that replaced the entry the pointer names) moves it to the next entry, wrapping
// from NENTRIES-1 to 0.  flush wins over adv.
module ad_vf_vc_victim #(
    parameter NENTRIES = 32,
    parameter SLOT_W   = 5
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              flush,
    input  wire              adv,
    output reg  [SLOT_W-1:0] ptr
);
    always @(posedge clk) begin
        if (!rst_n || flush)
            ptr <= {SLOT_W{1'b0}};
        else if (adv)
            ptr <= (ptr == NENTRIES - 1) ? {SLOT_W{1'b0}} : ptr + 1'b1;
    end
endmodule
