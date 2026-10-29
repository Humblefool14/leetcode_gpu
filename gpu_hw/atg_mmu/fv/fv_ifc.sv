// Formal harness: atg_mmu_ifc (2 clients, depth 4).  Reference-model checks are in the RTL.
module fv_ifc (input clk, input rst_n, input epo, input [1:0] inc, input [1:0] cmp, input [1:0] cmp_epo);
    wire [1:0] ful, nzr; wire obz;
    atg_mmu_ifc #(.NCL(2), .OSD(4)) dut (.clk(clk), .rst_n(rst_n), .epo(epo), .inc(inc),
        .cmp(cmp), .cmp_epo(cmp_epo), .ful(ful), .nzr(nzr), .obz(obz));
    reg f_pv = 0;
    always @(posedge clk) f_pv <= 1;
    always @(*) if (!f_pv) assume (!rst_n);
    always @(*) if (rst_n) begin
        cover (ful[0]);
        cover (ful[1] && obz);
        cover (nzr == 2'b11 && !obz);
    end
endmodule
