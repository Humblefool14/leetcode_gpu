// fv_ad_su_exp -- ad_su_exp (NPHYS 4, NWARPS 2, LDS_AW 4: the buffer reduced) with its drain and
// meshlet sequencer.  The harness keeps each slot's life: free (the RX may write its registers
// and d_s words) -> running (fl_go: a fragment warp, or the free input vstart: a vertex/compute
// warp; exp groups only of running warps, of their kind) -> ended (wc_end) -> free (xr_valid).
// ex_next steps only when a beat with ex_last is taken; scrub is not used; every other input is
// free.  Properties: beats only of an ended fragment warp whose number is ex_next; every ex_*
// output (and ex_aux) held while ex_valid && !ex_ready; the beats of one quad share ex_mask,
// ex_xy, ex_depth and ex_aux[147:0], only the first has qfirst; xr_valid only for an ended warp;
// x_ready is !mesh_busy and the LDS is read only while mesh_busy.  Task bmc (abc bmc3, depth 14,
// the buffer memory_map'ed) checks them all; task prove (define CTRL) proves those without the
// buffer's data (beats only for the right warp, ex_seq/ex_last held, releases, x_ready, LDS
// reads): with the data (some 40k state bits after memory_map) abc pdr did not close in 10 min.
module fv_ad_su_exp (
    input wire clk,
    input wire rst_n,
    input wire x_valid,
    input wire x_warp,
    input wire [2:0] x_grp,
    input wire x_last,
    input wire [107:0] x_uop,
    input wire [127:0] x_b,
    input wire [7:0] x_mask,
    input wire [31:0] x_info,
    input wire ex_ready,
    input wire [15:0] ex_next,
    input wire fl_we,
    input wire fl_slot,
    input wire [5:0] fl_reg,
    input wire [4:0] fl_lane,
    input wire [31:0] fl_data,
    input wire fl_go,
    input wire [63:0] fl_info,
    input wire fl_pw_we,
    input wire [11:0] fl_pw_addr,
    input wire [31:0] fl_pw_data,
    input wire vstart,
    input wire vslot,
    input wire wc_end,
    input wire wc_warp,
    input wire mesh_ready,
    input wire [31:0] mesh_lds_rd_data
);
    `include "ad_su_uop.vh"
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n); else assume (rst_n);

    wire x_ready, ex_valid, ex_last, xr_valid, xr_warp, mesh_valid, mesh_last, mesh_busy;
    wire lds_en, scrub_busy;
    wire [15:0] ex_seq, mesh_id;
    wire [31:0] ex_xy;
    wire [3:0] ex_mask, lds_a;
    wire [511:0] ex_color;
    wire [127:0] ex_depth;
    wire [153:0] ex_aux;
    wire [701:0] mesh_tri;
    ad_su_exp #(.NPHYS(4), .NWARPS(2), .WARP_W(1), .GRP_W(3), .LDS_AW(4)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_last(x_last), .x_sbe(3'd7), .x_pc(16'd0), .x_uop(x_uop), .x_a(128'd0), .x_b(x_b),
        .x_c(128'd0), .x_mask(x_mask), .x_info(x_info), .x_ready(x_ready),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
        .ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
        .ex_next(ex_next), .fl_we(fl_we), .fl_slot(fl_slot), .fl_reg(fl_reg), .fl_lane(fl_lane),
        .fl_data(fl_data), .fl_go(fl_go), .fl_info(fl_info), .fl_pw_we(fl_pw_we),
        .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data), .ex_aux(ex_aux),
        .xr_valid(xr_valid), .xr_warp(xr_warp), .wc_end(wc_end), .wc_warp(wc_warp),
        .mesh_valid(mesh_valid), .mesh_ready(mesh_ready), .mesh_tri(mesh_tri),
        .mesh_last(mesh_last), .mesh_id(mesh_id), .mesh_busy(mesh_busy),
        .mesh_lds_rd_en(lds_en), .mesh_lds_rd_addr(lds_a), .mesh_lds_rd_data(mesh_lds_rd_data),
        .scrub(1'b0), .scrub_busy(scrub_busy));

    // slot life: 0 free, 1 running, 2 ended
    reg [1:0] st [0:1];
    reg [1:0] frag;
    reg [15:0] sq [0:1];
    wire is_exp = x_valid && x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_EXP;
    always @(*) if (rst_n) begin
        if (fl_we || fl_pw_we || fl_go) assume (st[fl_slot] == 2'd0);
        if (vstart) assume (st[vslot] == 2'd0 && !(fl_go && fl_slot == vslot) &&
                            !((fl_we || fl_pw_we) && fl_slot == vslot));
        if (is_exp) assume (st[x_warp] == 2'd1 && (x_info[17:16] == 2'd1) == frag[x_warp] &&
                            x_grp < 3'd8);
        if (wc_end) assume (st[wc_warp] == 2'd1);
    end
    reg [15:0] pnext;
    reg ptl, pr;
    always @(posedge clk) begin
        pr <= rst_n;
        pnext <= ex_next;
        ptl <= ex_valid && ex_ready && ex_last;
    end
    always @(*) if (rst_n && pr) assume (ex_next == pnext + {15'd0, ptl});
    always @(posedge clk) begin
        if (!rst_n) begin
            st[0] <= 2'd0; st[1] <= 2'd0; frag <= 2'd0; sq[0] <= 16'd0; sq[1] <= 16'd0;
        end else begin
            if (xr_valid) st[xr_warp] <= 2'd0;
            if (wc_end) st[wc_warp] <= 2'd2;
            if (fl_go) begin
                st[fl_slot] <= 2'd1; frag[fl_slot] <= 1'b1; sq[fl_slot] <= fl_info[47:32];
            end
            if (vstart) begin
                st[vslot] <= 2'd1; frag[vslot] <= 1'b0;
            end
        end
    end

    reg pv, pin;                       // held beat; the next beat is of the same quad
    reg [15:0] pseq;
    reg [31:0] pxy;
    reg [3:0] pmask;
    reg [511:0] pcol;
    reg [127:0] pdep;
    reg [153:0] paux;
    reg plast;
    always @(posedge clk) begin
        if (!rst_n) pin <= 1'b0;
        else if (ex_valid && ex_ready) pin <= !ex_aux[151];
        pv <= rst_n && ex_valid && !ex_ready;
        if (ex_valid) begin
            pseq <= ex_seq; pxy <= ex_xy; pmask <= ex_mask; pcol <= ex_color; pdep <= ex_depth;
            paux <= ex_aux; plast <= ex_last;
        end
    end
    always @(*) if (rst_n && !init) begin
        if (ex_valid) begin
            assert (ex_seq == ex_next);
            assert ((st[0] == 2'd2 && frag[0] && sq[0] == ex_seq) ||
                    (st[1] == 2'd2 && frag[1] && sq[1] == ex_seq));
        end
`ifndef CTRL
        if (pv) assert (ex_valid && ex_seq == pseq && ex_xy == pxy && ex_mask == pmask &&
                        ex_color == pcol && ex_depth == pdep && ex_aux == paux && ex_last == plast);
        if (ex_valid && pin) assert (ex_mask == pmask && ex_xy == pxy && ex_depth == pdep &&
                                     ex_aux[147:0] == paux[147:0] && !ex_aux[150]);
`else
        if (pv) assert (ex_valid && ex_seq == pseq && ex_last == plast);
`endif
        if (xr_valid) assert (st[xr_warp] == 2'd2);
        assert (x_ready == !mesh_busy);
        if (lds_en) assert (mesh_busy);
    end
endmodule
