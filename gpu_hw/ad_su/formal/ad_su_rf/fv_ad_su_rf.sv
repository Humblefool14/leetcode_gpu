// fv_ad_su_rf -- ad_su_rf reduced (NPHYS 8, NWARPS 2, NREGS 4, LW 2 bits a lane):
// for a symbolic address (warp, reg, grp) a shadow word per lane follows the
// writes (lane enables) and the scrub (a harness copy of the scrub counter);
// a read on either port of that address returns, the next cycle, the shadow as
// it was before that cycle's write (old value on a same-cycle write); r_data
// holds while r_en is 0; scrub_busy lasts exactly DEPTH cycles from a start.
module fv_ad_su_rf (
    input wire clk,
    input wire w_en, input wire w_warp, input wire [1:0] w_grp, input wire [5:0] w_reg,
    input wire [15:0] w_data, input wire [7:0] w_lanes,
    input wire r_en, input wire r_warp, input wire [1:0] r_grp, input wire [5:0] r_reg1, input wire [5:0] r_reg2,
    input wire scrub
);
    localparam NPHYS = 8, LW = 2, NREGS = 4, DEPTH = 2 * 4 * 4;
    reg init = 1;
    always @(posedge clk) init <= 0;
    wire rst_n = !init;
    always @(*) begin
        assume (w_reg < NREGS); assume (r_reg1 < NREGS); assume (r_reg2 < NREGS);
    end
    wire [15:0] r_data1, r_data2; wire busy;
    ad_su_rf #(.NPHYS(8), .NWARPS(2), .WARP_W(1), .GRP_W(2), .NREGS(NREGS), .LW(LW)) dut (
        .clk(clk), .rst_n(rst_n), .w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg),
        .w_data(w_data), .w_lanes(w_lanes), .r_en(r_en), .r_warp(r_warp), .r_grp(r_grp),
        .r_reg1(r_reg1), .r_reg2(r_reg2), .r_data1(r_data1), .r_data2(r_data2), .scrub(scrub),
        .scrub_busy(busy));
    (* anyconst *) reg aw; (* anyconst *) reg [1:0] ag; (* anyconst *) reg [1:0] ar;
    wire [4:0] A = {aw, ar, ag};
    // harness copy of the scrub counter
    reg hon = 0; reg [4:0] ha = 0;
    always @(posedge clk)
        if (init) begin hon <= 0; ha <= 0; end
        else if (scrub) begin hon <= 1; ha <= 0; end
        else if (hon) begin ha <= ha + 1; if (ha == DEPTH - 1) hon <= 0; end
    // shadow of the symbolic address
    reg [15:0] sh; reg [7:0] kn = 0;
    integer l;
    always @(posedge clk)
        if (init) kn <= 0;
        else if (hon) begin if (ha == A) begin sh <= 0; kn <= 8'hFF; end end
        else if (w_en && {w_warp, w_reg[1:0], w_grp} == A)
            for (l = 0; l < 8; l = l + 1) if (w_lanes[l]) begin sh[LW*l +: LW] <= w_data[LW*l +: LW]; kn[l] <= 1; end
    // past values
    reg p_ok = 0, p_ren = 0, p_h1 = 0, p_h2 = 0; reg [15:0] p_sh, p_d1, p_d2; reg [7:0] p_kn;
    always @(posedge clk) begin
        p_ok <= !init; p_ren <= r_en;
        p_h1 <= r_en && {r_warp, r_reg1[1:0], r_grp} == A;
        p_h2 <= r_en && {r_warp, r_reg2[1:0], r_grp} == A;
        p_sh <= sh; p_kn <= kn; p_d1 <= r_data1; p_d2 <= r_data2;
    end
    always @(*) if (!init) begin
        assert (busy == hon);
        if (p_ok) begin
            for (l = 0; l < 8; l = l + 1) if (p_kn[l]) begin
                if (p_h1) assert (r_data1[LW*l +: LW] == p_sh[LW*l +: LW]);
                if (p_h2) assert (r_data2[LW*l +: LW] == p_sh[LW*l +: LW]);
            end
            if (!p_ren) assert (r_data1 == p_d1 && r_data2 == p_d2);
        end
    end
endmodule
