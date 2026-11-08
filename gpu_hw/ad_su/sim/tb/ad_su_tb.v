// ad_su_tb -- the whole shader unit runs a GSI1 compute dispatch (one workgroup of 64 lanes,
// two warps) of sim/tb/su/<PROG>.s and is compared with tools/gsi1model.py (vectors from
// tools/gen_su_sys.py): every register lane the program wrote, the data memory image after
// the dispatch, no ISA fault, and the SU idle at the end.  Memory: two ad_amb_mem instances
// with the same 64 KiB image (I$+constants client and D$ client) and a model of the MC's
// atomic unit on the D$ memory.  Run with +prog=<name> and -P for NPHYS/PACKED/SUBGROUP.
`timescale 1ns/1ps
module ad_su_tb;
    parameter NPHYS = 8, PACKED = 0, SUBGROUP = 0;
    localparam G = 32 / NPHYS, GRP_W = (G > 1) ? $clog2(G) : 1, GB = (G > 1) ? $clog2(G) : 0;
    localparam NWARPS = 4, WARP_W = 2, NREGS = 32, DEPTH = NWARPS * NREGS * G;
    localparam MEMB = 65536, CS_BASE = 32'h1000, DATA_BASE = 32'h8000;

    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0; reg cs_kick = 0, lc_kick = 0;
    wire busy, fault, scrub_busy; wire [31:0] fault_addr;
    // D$ and I$ clients
    wire dq_v, dq_r, dq_w, dr_v, dr_w, dr_e, iq_v, iq_r, iq_w, ir_v, ir_w, ir_e;
    wire [26:0] dq_l, iq_l; wire [31:0] dq_be, iq_be; wire [255:0] dq_d, iq_d, dr_d, ir_d;
    wire [7:0] dq_t, iq_t, dr_t, ir_t;
    // atomics
    wire at_valid; reg at_rsp_valid = 0; reg [31:0] at_old = 0; wire [3:0] at_op; wire [29:0] at_addr;
    wire [31:0] at_a, at_b;

    ad_su #(.NPHYS(NPHYS), .PACKED(PACKED), .SUBGROUP(SUBGROUP)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .cs_kick(cs_kick), .lc_kick(lc_kick), .inv(4'd0), .scrub(1'b0), .scrub_busy(scrub_busy),
        .vl_req(1'b0), .vl_gnt(), .vl_slot(), .vl_ptbase(), .vl_we(1'b0), .vl_reg(6'd0), .vl_lane(5'd0),
        .vl_data(32'd0), .vl_go(1'b0), .vl_mask(32'd0),
        .fl_req(1'b0), .fl_gnt(), .fl_slot(), .fl_we(1'b0), .fl_reg(6'd0), .fl_lane(5'd0), .fl_data(32'd0),
        .fl_pw_we(1'b0), .fl_pw_addr(12'd0), .fl_pw_data(32'd0), .fl_go(1'b0), .fl_mask(32'd0), .fl_info(64'd0),
        .pt_rd(1'b0), .pt_idx(8'd0), .pt_word(7'd0), .pt_rdata(), .pt_free(1'b0), .pt_free_idx(8'd0), .pt_done(),
        .tx_valid(), .tx_ready(1'b1), .tx_op(), .tx_slot(), .tx_vs(), .tx_mask(), .tx_coord(), .tx_off(),
        .tx_tag(), .tx_last(), .tr_valid(1'b0), .tr_ready(), .tr_tag(16'd0), .tr_data(512'd0), .tr_last(1'b0),
        .ex_valid(), .ex_ready(1'b1), .ex_seq(), .ex_xy(), .ex_mask(), .ex_color(), .ex_depth(), .ex_last(),
        .ex_aux(), .ex_next(16'd0), .mesh_valid(), .mesh_ready(1'b1), .mesh_tri(), .mesh_last(), .mesh_id(),
        .d_req_valid(dq_v), .d_req_ready(dq_r), .d_req_write(dq_w), .d_req_line(dq_l), .d_req_be(dq_be),
        .d_req_wdata(dq_d), .d_req_tag(dq_t), .d_rsp_valid(dr_v), .d_rsp_write(dr_w), .d_rsp_tag(dr_t),
        .d_rsp_rdata(dr_d), .d_rsp_error(dr_e),
        .i_req_valid(iq_v), .i_req_ready(iq_r), .i_req_write(iq_w), .i_req_line(iq_l), .i_req_be(iq_be),
        .i_req_wdata(iq_d), .i_req_tag(iq_t), .i_rsp_valid(ir_v), .i_rsp_write(ir_w), .i_rsp_tag(ir_t),
        .i_rsp_rdata(ir_d), .i_rsp_error(ir_e),
        .at_valid(at_valid), .at_ready(1'b1), .at_op(at_op), .at_addr(at_addr), .at_a(at_a), .at_b(at_b),
        .at_rsp_valid(at_rsp_valid), .at_old(at_old), .at_error(1'b0),
        .sa_push_valid(), .sa_push_ready(1'b0), .sa_push_data(), .sa_pop_valid(1'b0), .sa_pop_ready(),
        .sa_pop_data({NPHYS*32{1'b0}}), .sa_ctl_valid(), .sa_ctl_data(), .sa_qstat(32'd0), .sa_stat(32'd0),
        .sa_qtag(32'd0), .busy(busy), .fault(fault), .fault_addr(fault_addr));

    ad_amb_mem #(.LINE_BYTES(32), .LINE_SHIFT(5), .MEM_LINES(MEMB / 32), .LAT_MIN(2), .LAT_MAX(14),
                 .READY_PCT(70), .SEED(3)) dmem (
        .clk(clk), .rst_n(rst_n), .req_valid(dq_v), .req_ready(dq_r), .req_write(dq_w), .req_line(dq_l),
        .req_be(dq_be), .req_wdata(dq_d), .req_tag(dq_t), .rsp_valid(dr_v), .rsp_write(dr_w), .rsp_tag(dr_t),
        .rsp_rdata(dr_d), .rsp_error(dr_e));
    ad_amb_mem #(.LINE_BYTES(32), .LINE_SHIFT(5), .MEM_LINES(MEMB / 32), .LAT_MIN(2), .LAT_MAX(14),
                 .READY_PCT(70), .SEED(5)) imem (
        .clk(clk), .rst_n(rst_n), .req_valid(iq_v), .req_ready(iq_r), .req_write(iq_w), .req_line(iq_l),
        .req_be(iq_be), .req_wdata(iq_d), .req_tag(iq_t), .rsp_valid(ir_v), .rsp_write(ir_w), .rsp_tag(ir_t),
        .rsp_rdata(ir_d), .rsp_error(ir_e));

    // the MC's atomic unit: in order, 2 cycles, on the D$ memory (the LSU invalidates its D$)
    function [31:0] rdw(input [31:0] a); rdw = {dmem.mem[a+3], dmem.mem[a+2], dmem.mem[a+1], dmem.mem[a]}; endfunction
    reg [31:0] aold, anew; reg at_p = 0;
    always @(posedge clk) begin
        at_rsp_valid <= at_p; at_p <= 0;
        if (at_valid) begin
            aold = rdw({at_addr, 2'b00});
            case (at_op)
                0: anew = aold & at_a;  1: anew = aold | at_a;  2: anew = aold ^ at_a;  3: anew = at_a;
                4: anew = aold + at_a;  5: anew = aold - at_a;
                6: anew = ($signed(aold) > $signed(at_a)) ? aold : at_a;
                7: anew = ($signed(aold) < $signed(at_a)) ? aold : at_a;
                8: anew = (aold > at_a) ? aold : at_a;  9: anew = (aold < at_a) ? aold : at_a;
                default: anew = (aold == at_b) ? at_a : aold;
            endcase
            {dmem.mem[{at_addr,2'b00}+3], dmem.mem[{at_addr,2'b00}+2], dmem.mem[{at_addr,2'b00}+1],
             dmem.mem[{at_addr,2'b00}]} = anew;
            at_old <= aold; at_p <= 1;
        end
    end

    // register file backdoor copy (lane i of every address)
    reg [31:0] rfc [0:NPHYS*DEPTH-1];
    reg dump = 0;
    genvar gi;
    generate for (gi = 0; gi < NPHYS; gi = gi + 1) begin : cp
        integer a;
        always @(posedge dump) for (a = 0; a < DEPTH; a = a + 1) rfc[gi * DEPTH + a] = dut.u_rf.lane[gi].m1.mem[a];
    end endgenerate

    reg [35:0] regx [0:4*NREGS*32-1];
    reg [31:0] mexp [0:4095];
    reg [8*32-1:0] prog;
    string fn;
    integer i, k, n, l, err, cyc, idle, faults, addr, nchk;
    reg [31:0] got;

    task st(input [8:0] idx, input [31:0] v);
        begin @(posedge clk); st_we <= 1; st_idx <= idx; st_wdata <= v; @(posedge clk); st_we <= 0; end
    endtask

    always @(posedge clk) begin cyc <= cyc + 1; if (fault) faults = faults + 1; end

    initial begin
        cyc = 0; err = 0; faults = 0; nchk = 0;
        if (!$value$plusargs("prog=%s", prog)) prog = "alu";
        fn = $sformatf("sim/vec/su_%0s_img.hex", prog);  $readmemh(fn, dmem.mem); $readmemh(fn, imem.mem);
        fn = $sformatf("sim/vec/su_%0s_regs.hex", prog); $readmemh(fn, regx);
        fn = $sformatf("sim/vec/su_%0s_mexp.hex", prog); $readmemh(fn, mexp);
        repeat (4) @(posedge clk); rst_n <= 1;
        st(9'h192, CS_BASE); st(9'h199, 64); st(9'h1E9, 1); st(9'h1EA, 1); st(9'h1EB, 1);
        st(9'h1EC, 0); st(9'h1ED, DATA_BASE); st(9'h1EE, 256);
        @(posedge clk); lc_kick <= 1; @(posedge clk); lc_kick <= 0;
        repeat (4) @(posedge clk); while (busy) @(posedge clk);
        @(posedge clk); cs_kick <= 1; @(posedge clk); cs_kick <= 0;
        idle = 0;
        while (idle < 64 && cyc < 400000) begin @(posedge clk); idle = busy ? 0 : idle + 1; end
        if (cyc >= 400000) begin $display("FAIL ad_su (timeout, %0s)", prog); $finish; end
        dump = 1; #1;
        // registers: slot k, register n, lane l
        for (k = 0; k < 2; k = k + 1) for (n = 0; n < NREGS; n = n + 1) for (l = 0; l < 32; l = l + 1)
            if (regx[(k * NREGS + n) * 32 + l][32]) begin
                addr = (((k << 5) | n) << GB) | (l / NPHYS);
                got = rfc[(l % NPHYS) * DEPTH + addr];
                nchk = nchk + 1;
                if (got !== regx[(k * NREGS + n) * 32 + l][31:0]) begin
                    if (err < 10) $display("  %0s: warp %0d r%0d lane %0d = %h, expected %h", prog, k, n, l, got,
                                            regx[(k * NREGS + n) * 32 + l][31:0]);
                    err = err + 1;
                end
            end
        for (i = 0; i < 4096; i = i + 1)
            if (rdw(DATA_BASE + 4 * i) !== mexp[i]) begin
                if (err < 20) $display("  %0s: mem[%h] = %h, expected %h", prog, DATA_BASE + 4 * i,
                                        rdw(DATA_BASE + 4 * i), mexp[i]);
                err = err + 1;
            end
        if (faults) begin $display("  %0s: %0d ISA faults (pc %h)", prog, faults, fault_addr); err = err + 1; end
        if (err == 0) begin
            $display("PASS ad_su.%0s (NPHYS %0d: %0d register lanes, 4096 memory words, %0d cycles)",
                     prog, NPHYS, nchk, cyc);
            $display("PASS ad_su");
        end else $display("FAIL ad_su.%0s (%0d mismatches)", prog, err);
        $finish;
    end
endmodule
