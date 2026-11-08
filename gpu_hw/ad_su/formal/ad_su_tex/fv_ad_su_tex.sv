// fv_ad_su_tex -- ad_su_tex with ad_su_tex_ret (NPHYS 8).  Every input is free each cycle
// (other units' groups, both passes of the .c/.3 forms in any order, any EXEC).  Properties: a
// request is held (op, slot, tx_vs, mask, coordinates, offsets, tag, tx_last) while tx_valid &&
// !tx_ready; a request has at least one lane; no group is taken while a request is out (a lane
// group's quads go out one per cycle in SEND); the opcode's bit 7 is 0.
module fv_ad_su_tex (
    input wire clk,
    input wire rst_n,
    input wire x_valid,
    input wire [1:0] x_warp,
    input wire [1:0] x_grp,
    input wire x_last,
    input wire [2:0] x_sbe,
    input wire [107:0] x_uop,
    input wire [255:0] x_a,
    input wire [255:0] x_b,
    input wire [255:0] x_c,
    input wire [15:0] x_mask,
    input wire [31:0] x_info,
    input wire l_ready,
    input wire tx_ready,
    input wire tr_valid,
    input wire [15:0] tr_tag,
    input wire [511:0] tr_data,
    input wire tr_last
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    wire x_ready, l_valid, l_wr, l_last, tx_valid, tx_vs, tx_last, tr_ready;
    wire [1:0] l_warp, l_grp;
    wire [6:0] l_rd;
    wire [255:0] l_data;
    wire [7:0] l_lanes;
    wire [2:0] l_sbe, l_cls;
    wire [7:0] tx_op;
    wire [3:0] tx_slot, tx_mask;
    wire [639:0] tx_coord;
    wire [11:0] tx_off;
    wire [15:0] tx_tag;
    ad_su_tex #(.NPHYS(8), .WARP_W(2), .GRP_W(2), .SBE_W(2)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_last(x_last), .x_sbe(x_sbe), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(x_b),
        .x_c(x_c), .x_mask(x_mask), .x_info(x_info), .x_ready(x_ready), .l_valid(l_valid),
        .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data),
        .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe), .l_cls(l_cls),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot),
        .tx_vs(tx_vs), .tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off),
        .tx_tag(tx_tag), .tx_last(tx_last), .tr_valid(tr_valid), .tr_ready(tr_ready),
        .tr_tag(tr_tag), .tr_data(tr_data), .tr_last(tr_last));

    reg pv;
    reg [7:0] pop;
    reg [3:0] pslot, pmask;
    reg pvs, plast;
    reg [639:0] pcoord;
    reg [11:0] poff;
    reg [15:0] ptag;
    always @(posedge clk) begin
        pv <= rst_n && tx_valid && !tx_ready;
        pop <= tx_op; pslot <= tx_slot; pmask <= tx_mask; pvs <= tx_vs; plast <= tx_last;
        pcoord <= tx_coord; poff <= tx_off; ptag <= tx_tag;
    end
    always @(*) if (rst_n && !init) begin
        if (pv) assert (tx_valid && tx_op == pop && tx_slot == pslot && tx_mask == pmask &&
                        tx_vs == pvs && tx_last == plast && tx_coord == pcoord &&
                        tx_off == poff && tx_tag == ptag);
        if (tx_valid) assert (tx_mask != 4'd0 && !tx_op[7] && !x_ready);
    end
endmodule
