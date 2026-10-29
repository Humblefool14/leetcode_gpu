// Formal harness: atg_mmu_arb (N = 4).  Properties live in the RTL (`ifdef FORMAL);
// AMU_FVA turns the request-hold rule into an environment assumption.
module fv_arb (input clk, input rst_n, input [3:0] req, input rdy);
    localparam N = 4;
    wire [N-1:0] gnt;
    atg_mmu_arb #(.N(N)) dut (.clk(clk), .rst_n(rst_n), .req(req), .rdy(rdy), .gnt(gnt));

    reg f_pv = 0;
    always @(posedge clk) f_pv <= 1;
    always @(*) if (!f_pv) assume (!rst_n);

    always @(*) if (rst_n) begin
        cover (gnt[0] && rdy);
        cover (gnt[3] && rdy);
        cover (req == 4'hf && gnt[2] && rdy);
    end
endmodule
