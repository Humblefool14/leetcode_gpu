// ad_su_fetch -- instruction fetch (spec ad_su_fetch.md).
// A request from ad_su_sched goes to the I$ unchanged (ic_req = f_valid while
// the in-flight queue has room); the queue (ad_ctl_fq, 2 entries) keeps
// {warp, pc} of each accepted request in order, receives the I$ responses
// (in request order, no back-pressure) into the oldest entry without data and
// hands the head to ad_su_dec when its instruction has arrived.  f_ready =
// ic_ready && room; room counts a head leaving in the same cycle.
module ad_su_fetch #(
    parameter WARP_W = 2
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              f_valid,
    output wire              f_ready,
    input  wire [WARP_W-1:0] f_warp,
    input  wire [15:0]       f_pc,
    input  wire [31:0]       f_addr,
    output wire              ic_req,
    input  wire              ic_ready,
    output wire [31:0]       ic_addr,
    input  wire              ic_rvalid,
    input  wire [63:0]       ic_rdata,
    output wire              d_valid,
    input  wire              d_ready,
    output wire [WARP_W-1:0] d_warp,
    output wire [15:0]       d_pc,
    output wire [63:0]       d_instr
);
    wire room;
    assign ic_req  = f_valid && room;
    assign ic_addr = f_addr;
    assign f_ready = ic_ready && room;

    ad_ctl_fq #(.TW(WARP_W + 16), .DW(64)) u_q (
        .clk(clk), .rst_n(rst_n),
        .push(f_valid && f_ready), .push_tag({f_warp, f_pc}), .room(room),
        .fill(ic_rvalid), .fill_data(ic_rdata),
        .out_valid(d_valid), .out_ready(d_ready), .out_tag({d_warp, d_pc}), .out_data(d_instr)
    );
endmodule
