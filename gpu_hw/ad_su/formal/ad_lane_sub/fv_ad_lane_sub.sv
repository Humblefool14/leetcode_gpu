// fv_ad_lane_sub: the result of a staged shfl/vote/ballot for group e on a
// reduced warp (WARP 8, NPHYS 4): shfl: EXEC lane l gets rs1 of its source
// s when s exists and is in EXEC, else its own rs1; lanes outside EXEC are
// not written; vote any = (B != 0), all = (B == EXEC), ballot = B, with B =
// the EXEC lanes whose rs1 != 0, written to every lane; lanes outside EXEC
// never influence a written result (their rs1 is free: compared with a copy
// where it is changed).
module fv_ad_lane_sub #(parameter WARP = 8, parameter NPHYS = 4, parameter LW = 3,
    parameter GRP_W = 1);
    (* anyconst *) reg [1:0] op;
    (* anyconst *) reg [4:0] sub;
    (* anyconst *) reg [GRP_W-1:0] e;
    (* anyconst *) reg [WARP*32-1:0] rs1, rs1b;
    (* anyconst *) reg [WARP-1:0] ex, ok;
    (* anyconst *) reg [WARP*LW-1:0] src;
    always @(*) assume (op != 2'd0);
    wire [NPHYS*32-1:0] y, y2;
    wire [NPHYS-1:0] lanes, lanes2;
    // rs1 of the lanes outside EXEC replaced: rs1b
    reg [WARP*32-1:0] rs1x;
    integer l;
    always @(*)
        for (l = 0; l < WARP; l = l + 1)
            rs1x[l*32 +: 32] = ex[l] ? rs1[l*32 +: 32] : rs1b[l*32 +: 32];
    ad_lane_sub #(.NPHYS(NPHYS), .WARP(WARP), .LW(LW), .GRP_W(GRP_W)) dut (.op(op), .sub(sub),
        .e(e), .q_rs1(rs1), .q_exec(ex), .q_src(src), .q_ok(ok), .y(y), .lanes(lanes));
    ad_lane_sub #(.NPHYS(NPHYS), .WARP(WARP), .LW(LW), .GRP_W(GRP_W)) dut2 (.op(op), .sub(sub),
        .e(e), .q_rs1(rs1x), .q_exec(ex), .q_src(src), .q_ok(ok), .y(y2), .lanes(lanes2));
    reg [WARP-1:0] bal;
    reg [31:0] vb, want;
    integer j, ln, sl;
    always @(*) begin
        for (l = 0; l < WARP; l = l + 1)
            bal[l] = ex[l] && rs1[l*32 +: 32] != 32'd0;
        if (op == 2'd3)
            vb = {{(32-WARP){1'b0}}, bal};
        else if (sub == 5'd0)
            vb = (bal != 0) ? 32'hFFFFFFFF : 32'd0;
        else
            vb = (bal == ex) ? 32'hFFFFFFFF : 32'd0;
        for (j = 0; j < NPHYS; j = j + 1) begin
            ln = e * NPHYS + j;
            sl = src[ln*LW +: LW];
            if (op == 2'd1) begin
                assert (lanes[j] == ex[ln]);
                want = (ok[ln] && ex[sl]) ? rs1[sl*32 +: 32] : rs1[ln*32 +: 32];
            end else begin
                assert (lanes[j]);
                want = vb;
            end
            if (lanes[j]) begin
                assert (y[j*32 +: 32] == want);
                assert (y2[j*32 +: 32] == want);
            end
        end
        assert (lanes2 == lanes);
    end
endmodule
