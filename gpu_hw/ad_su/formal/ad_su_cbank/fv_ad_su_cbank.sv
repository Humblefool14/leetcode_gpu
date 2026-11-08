// fv_ad_su_cbank -- formal harness of ad_su_cbank, reduced: CONST_WORDS 32,
// ADDR_W 8, 8-byte lines, NPHYS 2.  Reset in the first cycle only; scrub 0;
// STATE writes, inv and lc_kick only while not busy (the CP's order); lwc
// groups (x_*), cr_* and the AMB responses free (formal/common/
// ad_amb_client_props.sv: the request held until ready, responses only for
// outstanding requests, any data and error).
// Reference for a symbolic word I (anyconst): when a response without error
// answers the line holding byte address A + 4 I of a LOAD_CONST of region 0
// with I < min(words, CONST_WORDS), word I becomes that word of the line;
// inv makes it read 0.  Property: a c-operand read made while not busy
// returns, the next cycle, in each of the three slots whose index is I, the
// last loaded word I (0 when none since reset or the last inv).
module fv_ad_su_cbank (
    input wire clk,
    input wire rst_n,
    input wire x_valid, input wire x_last, input wire [107:0] x_uop,
    input wire [63:0] x_a, input wire [3:0] x_mask, input wire l_ready,
    input wire cr_en, input wire [14:0] cr_idx,
    input wire st_we, input wire [8:0] st_idx, input wire [31:0] st_wdata,
    input wire lc_kick, input wire inv,
    input wire req_ready, input wire rsp_valid, input wire rsp_write, input wire [7:0] rsp_tag,
    input wire [63:0] rsp_rdata, input wire rsp_error
);
    `include "ad_su_state.vh"
    localparam NP = 2, AW = 8, LB = 8, LS = 3, CWORDS = 32;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire busy;
    always @(*) begin
        if (init) assume (!rst_n);
        else assume (rst_n);
        if (busy) assume (!st_we && !inv && !lc_kick);
    end

    wire x_ready, l_valid, l_wr, l_last, scrub_busy, req_valid, req_write;
    wire [1:0] l_warp; wire [3:0] l_grp; wire [2:0] l_sbe, l_cls; wire [6:0] l_rd;
    wire [NP*32-1:0] l_data; wire [NP-1:0] l_lanes; wire [95:0] cr_data;
    wire [2:0] fv_st; wire fv_lc_pend, fv_vb_i; wire [AW-1:0] fv_ld_cur; wire [5:0] fv_ld_left;
    wire [4:0] fv_ld_idx; wire [63:0] fv_ld_line; wire [95:0] fv_lc; wire [31:0] fv_cpy_i;
    (* anyconst *) reg [4:0] I;
    wire [AW-LS-1:0] req_line; wire [LB-1:0] req_be; wire [LB*8-1:0] req_wdata; wire [7:0] req_tag;
    ad_su_cbank #(.NPHYS(NP), .GRP_W(4), .UOP_W(108), .ADDR_W(AW), .LINE_BYTES(LB), .LINE_SHIFT(LS),
                  .CONST_WORDS(CWORDS)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(2'd0), .x_grp(4'd0), .x_last(x_last),
        .x_sbe(3'd0), .x_pc(16'd0), .x_uop(x_uop), .x_a(x_a), .x_b(64'd0), .x_c(64'd0), .x_mask(x_mask),
        .x_info(32'd0), .x_ready(x_ready), .l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp),
        .l_grp(l_grp), .l_rd(l_rd), .l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last),
        .l_sbe(l_sbe), .l_cls(l_cls), .cr_en(cr_en), .cr_idx(cr_idx), .cr_data(cr_data),
        .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .lc_kick(lc_kick), .inv(inv), .busy(busy),
        .scrub(1'b0), .scrub_busy(scrub_busy),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid),
        .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
        .fv_st(fv_st), .fv_lc_pend(fv_lc_pend), .fv_ld_cur(fv_ld_cur), .fv_ld_left(fv_ld_left),
        .fv_ld_idx(fv_ld_idx), .fv_ld_line(fv_ld_line), .fv_lc(fv_lc), .fv_i(I), .fv_vb_i(fv_vb_i),
        .fv_cpy_i(fv_cpy_i));

    wire [2:0] outst;
    ad_amb_client_props #(.LINE_BYTES(LB), .LINE_W(AW-LS), .CNT_W(3)) amb (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready),
        .req_write(req_write), .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata),
        .req_tag(req_tag), .rsp_valid(rsp_valid), .outstanding(outst));

    reg [31:0] rg, ad, wd;          // STATE copy
    reg [AW-LS-1:0] o_line;
    reg [31:0] sh, pv; reg shv, pp;  // word I as read; pv a loaded value not yet visible (busy)
    wire [31:0] eff  = pp ? pv : sh;
    wire        effv = pp | shv;
    wire [AW-1:0] ba   = {ad[AW-1:2], 2'b00} + {I, 2'b00};
    wire [5:0]    n    = (wd > CWORDS) ? 6'd32 : wd[5:0];
    wire          inld = (rg == 32'd0) && ({1'b0, I} < n);
    reg [95:0] exp_c; reg [2:0] chk;
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin rg <= 0; ad <= 0; wd <= 0; shv <= 1'b0; pp <= 1'b0; chk <= 3'd0; end
        else begin
            if (st_we && st_idx == `AD_S_LC_REGION) rg <= st_wdata;
            if (st_we && st_idx == `AD_S_LC_ADDR)   ad <= st_wdata;
            if (st_we && st_idx == `AD_S_LC_WORDS)  wd <= st_wdata;
            if (req_valid && req_ready) o_line <= req_line;
            if (rsp_valid && !rsp_error && inld && ba[AW-1:LS] == o_line) begin
                pv <= rsp_rdata[ba[LS-1:2]*32 +: 32]; pp <= 1'b1;
            end else if (!busy && pp) begin
                sh <= pv; shv <= 1'b1; pp <= 1'b0;
            end
            if (inv) shv <= 1'b0;
            for (k = 0; k < 3; k = k + 1) begin
                chk[k] <= cr_en && !busy && cr_idx[5*k +: 5] == I;
                exp_c[32*k +: 32] <= effv ? eff : 32'd0;
            end
        end
    end
    always @(*) if (rst_n && !init) begin
        a_c0: assert (!chk[0] || cr_data[31:0]  == exp_c[31:0]);
        a_c1: assert (!chk[1] || cr_data[63:32] == exp_c[63:32]);
        a_c2: assert (!chk[2] || cr_data[95:64] == exp_c[95:64]);
        a_out: assert (outst <= 3'd1);
        // helper invariants (k-induction).  States: 0 idle 1 acc 2 drain 3 beat 4 lreq 5 lwait 6 lfill
        h_st:    assert (fv_st <= 3'd6);
        h_busy:  assert (busy == (fv_lc_pend || fv_st >= 3'd4));
        h_stc:   assert (fv_lc == {wd, ad, rg});
        h_scr:   assert (!scrub_busy);
        h_out:   assert ((outst == 3'd1) == (fv_st == 3'd5));
        if (fv_st == 3'd5) h_oline: assert (o_line == fv_ld_cur[AW-1:LS]);
        if (fv_st == 3'd4 || fv_st == 3'd5) begin
            h_rl: assert (req_line == fv_ld_cur[AW-1:LS]);
            h_al: assert (fv_ld_idx == 5'd0 || fv_ld_cur[LS-1:2] == 1'b0);
        end
        if (!busy) h_vis: assert (fv_vb_i == effv && (!effv || fv_cpy_i == eff));
        if (fv_st >= 3'd4) begin
            h_nolcp: assert (!fv_lc_pend);
            h_load: assert (rg == 32'd0 && {1'b0, fv_ld_idx} < n);
            h_cur:  assert (fv_ld_cur == {ad[AW-1:2], 2'b00} + {fv_ld_idx, 2'b00});
            h_left: assert (fv_ld_left == n - {1'b0, fv_ld_idx});
            // word I not yet written in this load: the old state; pp only once its line came
            if (I >= fv_ld_idx) begin
                h_old: assert (fv_vb_i == shv && (!shv || fv_cpy_i == sh));
                if (fv_st == 3'd6 && inld && ba[AW-1:LS] == fv_ld_cur[AW-1:LS])
                    h_line: assert (pp && fv_ld_line[ba[LS-1:2]*32 +: 32] == pv);
                else h_np: assert (!pp);
            end else begin
                h_done: assert (!inld || (pp ? (fv_vb_i && fv_cpy_i == pv) : (fv_vb_i == shv && (!shv || fv_cpy_i == sh))));
            end
        end
        if (busy && fv_st < 3'd4) h_pend: assert (!pp && fv_vb_i == shv && (!shv || fv_cpy_i == sh));
    end
endmodule
