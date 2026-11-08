/*
 * Amaterrace GPU
 * SPDX-License-Identifier: Zlib
 *
 * ad_su_rq: the reserved rq port (operand 63) and sactl (design §3.9).
 * v1 (HAS_SA = 0): empty = 1, full = 1, every other output 0 (the decoder
 * faults every rq use, so nothing reaches this module).  HAS_SA = 1 is not
 * defined yet (the FIFO format is decided with the SA design); it builds
 * the same stub.
 */
module ad_su_rq #(
    parameter NPHYS  = 8,
    parameter UOP_W  = 108,
    parameter HAS_SA = 0
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                pop,
    output wire [NPHYS*32-1:0] pop_data,
    input  wire                push,
    input  wire [NPHYS*32-1:0] push_data,
    output wire                empty,
    output wire                full,
    input  wire                ctl_valid,
    input  wire [31:0]         ctl_data,
    output wire                sa_push_valid,
    input  wire                sa_push_ready,
    output wire [NPHYS*32-1:0] sa_push_data,
    input  wire                sa_pop_valid,
    output wire                sa_pop_ready,
    input  wire [NPHYS*32-1:0] sa_pop_data,
    output wire                sa_ctl_valid,
    output wire [31:0]         sa_ctl_data,
    input  wire [31:0]         sa_qstat,
    input  wire [31:0]         sa_stat,
    input  wire [31:0]         sa_qtag
);
    assign pop_data      = {NPHYS*32{1'b0}};
    assign empty         = 1'b1;
`ifdef MUT_RQ_FULL
    assign full          = 1'b0;                     // mutation
`else
    assign full          = 1'b1;
`endif
    assign sa_push_valid = 1'b0;
    assign sa_push_data  = {NPHYS*32{1'b0}};
    assign sa_pop_ready  = 1'b0;
    assign sa_ctl_valid  = 1'b0;
    assign sa_ctl_data   = 32'd0;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, clk, rst_n, pop, push, push_data, ctl_valid, ctl_data,
                    sa_push_ready, sa_pop_valid, sa_pop_data, sa_qstat, sa_stat, sa_qtag};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
