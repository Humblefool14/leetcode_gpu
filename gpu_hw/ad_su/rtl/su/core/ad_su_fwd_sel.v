// ad_su_fwd_sel -- the forwarding mux of one RF read port (combinational leaf of
// ad_su_opd).  Six writers in priority order: 0 ALU EX4, 1 FPU EX4, 2 ALU EX5, 3 FPU
// EX5, 4 WB (this cycle's RF write), 5 the registered RF-write bypass (last cycle's
// write, which a read issued then missed).  A writer matches when valid, same warp and
// group, rd == {0, reg} and rd < 63; per lane the highest-priority matching writer whose
// lane bit is set gives the word, else the RF word (base).  en 0 (the port does not
// read a GPR) passes base.
module ad_su_fwd_sel #(
    parameter NPHYS  = 8,
    parameter WARP_W = 2,
    parameter GRP_W  = 2,
    parameter LW     = 32
) (
    input  wire                   en,
    input  wire [WARP_W-1:0]      warp,
    input  wire [GRP_W-1:0]       grp,
    input  wire [5:0]             reg_n,
    input  wire [NPHYS*LW-1:0]    base,
    input  wire [5:0]             f_valid,
    input  wire [6*WARP_W-1:0]    f_warp,
    input  wire [6*GRP_W-1:0]     f_grp,
    input  wire [6*7-1:0]         f_rd,
    input  wire [6*NPHYS*LW-1:0]  f_data,
    input  wire [6*NPHYS-1:0]     f_lanes,
    output reg  [NPHYS*LW-1:0]    out,
    output wire [5:0]             match
);
    genvar k;
    generate
        for (k = 0; k < 6; k = k + 1) begin : m
            wire [6:0] rd = f_rd[7*k +: 7];
            assign match[k] = en && f_valid[k] && f_warp[WARP_W*k +: WARP_W] == warp &&
                              f_grp[GRP_W*k +: GRP_W] == grp && rd == {1'b0, reg_n} && rd < 7'd63;
        end
    endgenerate
    integer i, j;
    always @(*) begin
        out = base;
        for (j = 5; j >= 0; j = j - 1)               // lowest priority first, the last wins
            for (i = 0; i < NPHYS; i = i + 1)
`ifdef MUT_FWD_PRIO
                if (match[5-j] && f_lanes[NPHYS*(5-j) + i])      // mutation: order reversed
                    out[LW*i +: LW] = f_data[NPHYS*LW*(5-j) + LW*i +: LW];
`else
                if (match[j] && f_lanes[NPHYS*j + i])
                    out[LW*i +: LW] = f_data[NPHYS*LW*j + LW*i +: LW];
`endif
    end
endmodule
