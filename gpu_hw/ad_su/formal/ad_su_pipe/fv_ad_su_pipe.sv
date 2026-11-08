// fv_ad_su_pipe -- ad_su_pipe (NPHYS 1, SHORT_LAT 3; the FPU is sim/common/
// ad_su_fpu_stub.v, a ^ b ^ c ^ op, so the proof is about the wrapper, not the fp
// arithmetic) against an ideal frozen pipeline: a harness delay line of SHORT_LAT
// stages that advances only while en, loaded with each taken ALU/FPU group that writes
// rd and its reference result.  Asserts s_* == the ideal last stage every cycle
// (exact latency in en time, held while en is 0; nothing lost, so no FIFO overflow)
// and x_ready == en.
module fv_ad_su_pipe (
    input wire clk, input wire en, input wire x_valid, input wire [1:0] x_warp, input wire x_grp,
    input wire [107:0] x_uop, input wire [31:0] x_a, input wire [31:0] x_b, input wire [31:0] x_c,
    input wire [1:0] x_mask
);
`include "ad_su_uop.vh"
    localparam L = 3, PW = 2 + 1 + 7 + 32 + 1;
    reg init = 1;
    always @(posedge clk) init <= 0;
    wire x_ready, s_valid; wire [1:0] s_warp; wire s_grp; wire [6:0] s_rd; wire [31:0] s_data; wire s_lanes;
    ad_su_pipe #(.NPHYS(1), .WARP_W(2), .GRP_W(1), .SHORT_LAT(L)) dut (
        .clk(clk), .rst_n(!init), .en(en), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(1'b1),
        .x_sbe(3'd0), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .s_valid(s_valid), .s_warp(s_warp), .s_grp(s_grp), .s_rd(s_rd),
        .s_data(s_data), .s_lanes(s_lanes));
    function [31:0] aref(input [7:0] op, input [31:0] a, input [31:0] b0, input [31:0] c, input [31:0] imm);
        reg [31:0] b; reg signed [32:0] sa, sb;
        begin
            b = op[7] ? imm : b0; sa = {a[31], a}; sb = {b[31], b};
            case (op[4:0])
            0: aref = a + b;  1: aref = a + ~b + 1;  2: aref = a << b[4:0];
            3: aref = (sa < sb) ? 32'hFFFFFFFF : 0;  4: aref = (a < b) ? 32'hFFFFFFFF : 0;
            5: aref = a ^ b;  6: aref = a >> b[4:0];  7: aref = ({{32{a[31]}}, a} >> b[4:0]);
            8: aref = a | b;  9: aref = a & b;
            10: aref = (sa < sb) ? a : b;  11: aref = (sa < sb) ? b : a;
            12: aref = (a < b) ? a : b;  13: aref = (a < b) ? b : a;
            14: aref = a & ~b; 15: aref = a | ~b; 16: aref = ~a ^ b; 17: aref = (a & b) | (~a & c);
            18: aref = imm; default: aref = 0;
            endcase
        end
    endfunction
    wire [3:0] unit = x_uop[AD_UOP_UNIT +: 4];
    wire [7:0] op = x_uop[AD_UOP_OP +: 8];
    wire [31:0] rd_ref = (unit == AD_UNIT_FPU) ? (x_a ^ x_b ^ x_c ^ {24'd0, op}) : aref(op, x_a, x_b, x_c, x_uop[AD_UOP_IMM +: 32]);
    wire tin = x_valid && en && (unit == AD_UNIT_ALU || unit == AD_UNIT_FPU) && x_uop[AD_UOP_WRD];
    // Data reduction for the unbounded proof (the arithmetic is proven in ad_su_alu and
    // ad_core_alu_lane; task prove only, task bmc has full data): 2-bit operand values, bitwise ALU ops, FPU stub ops 0-3.
`ifdef REDUCE
    always @(*) begin
        assume (x_a[31:2] == 0 && x_b[31:2] == 0 && x_c[31:2] == 0 && x_uop[AD_UOP_IMM+2 +: 30] == 0);
        if (unit == AD_UNIT_ALU) assume (op[4:0] == AD_ALU_XOR || op[4:0] == AD_ALU_OR || op[4:0] == AD_ALU_AND || op[4:0] == AD_ALU_MOVI);
        if (unit == AD_UNIT_FPU) assume (op < 4);
    end
`endif
    reg [L-1:0] hv; reg [PW-1:0] hp [0:L-1];
    integer k;
    always @(posedge clk)
        if (init) hv <= 0;
        else if (en) begin
            hv <= {hv[L-2:0], tin};
            hp[0] <= {x_warp, x_grp, x_uop[AD_UOP_RD +: 7], rd_ref, x_mask[0]};
            for (k = 1; k < L; k = k + 1) hp[k] <= hp[k-1];
        end
    always @(*) if (!init) begin
        assert (x_ready == en);
        assert (s_valid == hv[L-1]);
        if (s_valid) assert ({s_warp, s_grp, s_rd, s_data, s_lanes} == hp[L-1]);
    end
endmodule
