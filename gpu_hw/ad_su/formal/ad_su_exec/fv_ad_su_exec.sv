// fv_ad_su_exec -- formal harness of ad_su_exec (NPHYS 8: 4 groups, 2 warps).
// Free bus inputs; assumed protocol: the groups of an EXEC-unit instruction
// come in order 0..3 (gaps allowed, other units' groups in the gaps) with the
// same warp, pc and uop, x_last on group 3; init_* never names the warp of an
// instruction in progress.  A shadow model (written per lane from the
// gsi1model rules, not with the RTL's leaf) keeps EXEC/KILLED per warp:
// asserted equal to q_exec/q_killed for every q_warp.  wc_* must come
// exactly the cycle after the last group of a branch/end/bar instruction with
// the reference op and pc, and at no other time.
module fv_ad_su_exec (
    input wire         clk,
    input wire         x_valid,
    input wire [0:0]   x_warp,
    input wire [1:0]   x_grp,
    input wire         x_last,
    input wire [15:0]  x_pc,
    input wire [3:0]   unit,
    input wire [3:0]   op4,
    input wire         use1,
    input wire [15:0]  imm,
    input wire [7:0]   bnz,        // per lane: rs1 != 0 (x_a built from it)
    input wire [7:0]   bx,         // lane value low bits (any nonzero value)
    input wire [0:0]   q_warp,
    input wire         init_valid,
    input wire [0:0]   init_warp,
    input wire [31:0]  init_mask
);
    `include "ad_su_uop.vh"
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    reg [AD_UOP_W-1:0] uop;
    always @(*) begin
        uop = {AD_UOP_W{1'b0}};
        uop[AD_UOP_UNIT +: 4] = unit;
        uop[AD_UOP_OP +: 8]   = {4'd0, op4};
        uop[AD_UOP_USE1]      = use1;
        uop[AD_UOP_IMM +: 32] = {{16{imm[15]}}, imm};
    end
    reg [255:0] x_a;
    integer l;
    always @(*) for (l = 0; l < 8; l = l + 1)
        x_a[32*l +: 32] = bnz[l] ? {bx[l] ? 24'h800000 : 24'h0, 7'd0, 1'b1} : 32'd0;

    wire wc_valid, s_valid;
    wire [0:0] wc_warp;
    wire [1:0] wc_op;
    wire [15:0] wc_pc;
    wire [31:0] q_exec, q_killed;
    ad_su_exec #(.NPHYS(8), .NWARPS(2), .WARP_W(1), .GRP_W(2), .SBE_W(2), .UOP_W(AD_UOP_W), .SHORT_LAT(2)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last),
        .x_sbe(3'b111), .x_pc(x_pc), .x_uop(uop), .x_a(x_a), .x_b(256'd0), .x_c(256'd0), .x_mask(16'd0),
        .x_info(32'd0), .x_ready(), .s_valid(s_valid), .s_warp(), .s_grp(), .s_rd(), .s_data(), .s_lanes(),
        .wc_valid(wc_valid), .wc_warp(wc_warp), .wc_op(wc_op), .wc_pc(wc_pc),
        .q_warp(q_warp), .q_exec(q_exec), .q_killed(q_killed),
        .init_valid(init_valid), .init_warp(init_warp), .init_mask(init_mask));

    // ---- protocol
    wire mine = x_valid && unit == AD_UNIT_EXEC;
    reg        ins;                 // an EXEC instruction is in progress
    reg [1:0]  eg;                  // next group
    reg [0:0]  iw;
    reg [15:0] ipc, iimm;
    reg [3:0]  iop;
    reg        iuse;
    always @(*) if (rst_n) begin
        if (mine) begin
            assume (x_grp == eg);
            assume (x_last == (eg == 2'd3));
            if (ins) assume (x_warp == iw && x_pc == ipc && op4 == iop && use1 == iuse && imm == iimm);
        end
        if (init_valid && ins) assume (init_warp != iw);
        if (init_valid && mine) assume (init_warp != x_warp);
    end else assume (!x_valid && !init_valid);

    // ---- shadow
    reg [31:0] sx [0:1];
    reg [31:0] sk [0:1];
    reg [31:0] acc;                 // Booleans gathered
    reg [31:0] b;
    reg        tk;
    reg        pwc;                 // a wc is due now
    reg [1:0]  pop;
    reg [0:0]  pw;
    reg [15:0] ppc;
    integer i;
    always @(*) begin
        b = acc;
        for (i = 0; i < 8; i = i + 1) if (bnz[i] && use1) b[8 * x_grp + i] = 1'b1;
        if (!use1) b = 32'd0;
        case (op4)
        4'd0: tk = |(b & sx[x_warp]);
        4'd1: tk = ~|(b & sx[x_warp]);
        4'd2: tk = ~|(~b & sx[x_warp]);
        4'd3: tk = 1'b1;
        4'd4: tk = |sx[x_warp];
        4'd5: tk = ~|sx[x_warp];
        default: tk = 1'b0;
        endcase
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            ins <= 0; eg <= 0; acc <= 0; pwc <= 0;
            sx[0] <= 0; sx[1] <= 0; sk[0] <= 0; sk[1] <= 0;
        end else begin
            pwc <= 1'b0;
            if (mine) begin
                ins <= !x_last; eg <= x_last ? 2'd0 : eg + 1'b1;
                iw <= x_warp; ipc <= x_pc; iop <= op4; iuse <= use1; iimm <= imm;
                if (x_grp == 2'd0) acc <= 32'd0;
                for (i = 0; i < 8; i = i + 1) if (bnz[i]) acc[8 * x_grp + i] <= 1'b1;
                if (x_last) begin
                    acc <= 32'd0;
                    case (op4)
                    4'd8:  sx[x_warp] <= b;
                    4'd9:  sx[x_warp] <= sx[x_warp] & b;
                    4'd10: sx[x_warp] <= sx[x_warp] | b;
                    4'd12: sk[x_warp] <= sk[x_warp] | (b & sx[x_warp]);
                    default: ;
                    endcase
                    pwc <= op4 <= 4'd5 || op4 == 4'd13 || op4 == 4'd14;
                    pop <= (op4 == 4'd13) ? 2'd1 : (op4 == 4'd14) ? 2'd2 : 2'd0;
                    pw  <= x_warp;
                    ppc <= (op4 <= 4'd5 && tk) ? x_pc + imm : x_pc + 16'd1;
                end
            end
            if (init_valid) begin sx[init_warp] <= init_mask; sk[init_warp] <= 32'd0; end
        end
    end
    always @(*) if (rst_n) begin
        a_exec:   assert (q_exec == sx[q_warp]);
        a_killed: assert (q_killed == sk[q_warp]);
        a_wc:     assert (wc_valid == pwc);
        if (pwc) begin
            a_wcf: assert (wc_warp == pw && wc_op == pop && wc_pc == ppc);
        end
    end
endmodule
