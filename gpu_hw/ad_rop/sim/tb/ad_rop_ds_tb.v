// ad_rop_ds_tb -- ad_rop_ds with ad_amb_mem (random ready and latency) against
// tools/ds_model.py (sim/vec/ds_{cmd,exp,mem}.hex from tools/gen_ds_vectors.py).
// Checks the stream of quads sent (d_xy, d_smask, d_beat, d_color) and the whole
// 4 KiB memory after every run.  LB = 32 (default) or 64: -Pad_rop_ds_tb.LB=64.
`timescale 1ns/1ps
module ad_rop_ds_tb;
    parameter LB    = 32;
    parameter LS    = (LB == 64) ? 6 : 5;
    parameter SEED  = 7;
    localparam MEMSZ = 4096;
    localparam AW = 32;

    reg clk = 0, rst_n = 0;
    always #5 clk = !clk;

    reg          st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0;
    reg          q_valid = 0; wire q_ready;
    reg  [31:0]  q_xy = 0; reg [15:0] q_smask = 0; reg [511:0] q_color = 0, q_sdepth = 0;
    reg          q_dbg = 0, q_front = 0; reg [3:0] q_beat = 0;
    wire         d_valid; reg d_ready = 0;
    wire [31:0]  d_xy; wire [15:0] d_smask; wire [511:0] d_color; wire [3:0] d_beat;
    wire         busy;
    wire         req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
    wire [AW-LS-1:0] req_line; wire [LB-1:0] req_be; wire [LB*8-1:0] req_wdata, rsp_rdata;
    wire [7:0]   req_tag, rsp_tag;

    ad_rop_ds #(.ADDR_W(AW), .LINE_BYTES(LB), .LINE_SHIFT(LS), .STENCIL(1)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .q_valid(q_valid), .q_ready(q_ready), .q_xy(q_xy), .q_smask(q_smask), .q_color(q_color),
        .q_sdepth(q_sdepth), .q_dbg(q_dbg), .q_front(q_front), .q_beat(q_beat),
        .d_valid(d_valid), .d_ready(d_ready), .d_xy(d_xy), .d_smask(d_smask), .d_color(d_color),
        .d_beat(d_beat), .busy(busy),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid),
        .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
    ad_amb_mem #(.LINE_BYTES(LB), .LINE_SHIFT(LS), .ADDR_W(AW), .MEM_LINES(MEMSZ / LB),
                 .LAT_MIN(2), .LAT_MAX(12), .READY_PCT(70), .SEED(SEED)) mem (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error));

    localparam NC = 8000, NE = 4000, NM = 200 * 1024;
    reg [1087:0] cmd [0:NC-1];
    reg [567:0]  exp_v [0:NE-1];
    reg [31:0]   img [0:NM-1];
    integer ci, ei, i, k, sec_err, tot_err, nsec, seed, cyc, guard, nq, nacc;
    reg [3:0] ty;
    reg [31:0] w;

    // random d_ready
    always @(posedge clk) d_ready <= (($unsigned($random(seed)) % 100) < 70);
    always @(posedge clk) cyc <= cyc + 1;
    // coverage counters
    integer n_err = 0, n_same = 0, n_raw = 0, n_wr = 0, n_rd = 0;
    always @(posedge clk) if (rst_n) begin
        if (rsp_valid && rsp_error) n_err = n_err + 1;
        if (req_valid && req_ready) begin if (req_write) n_wr = n_wr + 1; else n_rd = n_rd + 1; end
        if (dut.state == 3'd2 && dut.same && dut.rd_i == 2'd0 && !dut.req_valid) n_same = n_same + 1;
        if (dut.state == 3'd2 && !dut.req_valid && ((dut.rd_i == 2'd0 && dut.need0 && dut.conf0) ||
            (dut.rd_i == 2'd1 && dut.need1 && !dut.same && dut.conf1))) n_raw = n_raw + 1;
    end

    // ---- checker: every quad sent against the expected stream
    always @(posedge clk) if (rst_n && d_valid && d_ready) begin
        if (ei >= NE || exp_v[ei] === {568{1'bx}}) begin
            $display("  unexpected quad xy=%h smask=%h beat=%h", d_xy, d_smask, d_beat);
            sec_err = sec_err + 1;
        end else if (d_xy !== exp_v[ei][31:0] || d_smask !== exp_v[ei][47:32] || d_beat !== exp_v[ei][51:48] ||
                     d_color !== exp_v[ei][563:52]) begin
            if (sec_err < 6) $display("  quad %0d: xy=%h smask=%h beat=%h exp xy=%h smask=%h beat=%h (color %0s)", ei,
                                      d_xy, d_smask, d_beat, exp_v[ei][31:0], exp_v[ei][47:32], exp_v[ei][51:48],
                                      d_color === exp_v[ei][563:52] ? "ok" : "differs");
            sec_err = sec_err + 1;
        end
        ei = ei + 1;
    end

    // read-after-write scoreboard: no read of a line while a write of it is outstanding
    // (ad_amb_mem is in order, so a missing wait would not show in the data)
    reg [AW-LS-1:0] wo_line [0:255]; reg wo_v [0:255]; integer t;
    initial for (t = 0; t < 256; t = t + 1) wo_v[t] = 0;
    always @(posedge clk) if (rst_n) begin
        if (rsp_valid && rsp_write) wo_v[rsp_tag] = 0;
        if (req_valid && req_ready) begin
            if (req_write) begin wo_v[req_tag] = 1; wo_line[req_tag] = req_line; end
            else for (t = 0; t < 256; t = t + 1)
                if (wo_v[t] && wo_line[t] == req_line) begin
                    if (sec_err < 6) $display("  RAW: read of line %h with its write (tag %0d) outstanding", req_line, t);
                    sec_err = sec_err + 1;
                end
        end
    end

    // protocol checks: q_* / d_* handshake stability
    reg p_dv; reg [31:0] p_dxy; reg [15:0] p_dsm; reg p_dr;
    always @(posedge clk) begin
        if (rst_n && p_dv && !p_dr && (!d_valid || d_xy !== p_dxy || d_smask !== p_dsm)) begin
            $display("  d_* changed while d_valid && !d_ready"); sec_err = sec_err + 1;
        end
        p_dv <= d_valid; p_dxy <= d_xy; p_dsm <= d_smask; p_dr <= d_ready;
    end

    task drain; begin
        guard = 0;
        @(posedge clk); #1;
        while (busy && guard < 20000) begin @(posedge clk); #1; guard = guard + 1; end
        if (guard >= 20000) begin $display("FAIL ad_rop_ds: busy stuck"); $finish; end
    end endtask

    task sec_report(input integer s); begin
        case (s)
            0: $write("%0s ad_rop_ds.funcs", sec_err ? "FAIL" : "PASS");
            1: $write("%0s ad_rop_ds.stencil", sec_err ? "FAIL" : "PASS");
            2: $write("%0s ad_rop_ds.raw", sec_err ? "FAIL" : "PASS");
            3: $write("%0s ad_rop_ds.d16", sec_err ? "FAIL" : "PASS");
            4: $write("%0s ad_rop_ds.bounds", sec_err ? "FAIL" : "PASS");
            default: $write("%0s ad_rop_ds.beats", sec_err ? "FAIL" : "PASS");
        endcase
        $display(" (LINE_BYTES %0d, %0d errors, %0d quads in, %0d out so far)", LB, sec_err, nq, ei);
        tot_err = tot_err + sec_err; sec_err = 0; nsec = nsec + 1;
    end endtask

    initial begin
        seed = SEED; cyc = 0; ei = 0; sec_err = 0; tot_err = 0; nsec = 0; nq = 0;
        for (i = 0; i < NC; i = i + 1) cmd[i] = {1088{1'bx}};
        for (i = 0; i < NE; i = i + 1) exp_v[i] = {568{1'bx}};
        $readmemh("sim/vec/ds_cmd.hex", cmd);
        $readmemh("sim/vec/ds_exp.hex", exp_v);
        $readmemh("sim/vec/ds_mem.hex", img);
        repeat (4) @(posedge clk);
        #1 rst_n = 1;
        ci = 0;
        while (ci < NC && cmd[ci] !== {1088{1'bx}}) begin
            ty = cmd[ci][3:0];
            case (ty)
                4'd1: begin   // STATE write, only while idle
                    drain;
                    st_we = 1; st_idx = cmd[ci][12:4]; st_wdata = cmd[ci][44:13];
                    @(posedge clk); #1 st_we = 0;
                end
                4'd2: begin   // quad
                    q_valid = 1; q_xy = cmd[ci][35:4]; q_smask = cmd[ci][51:36]; q_beat = cmd[ci][55:52];
                    q_front = cmd[ci][56]; q_dbg = cmd[ci][57]; q_sdepth = cmd[ci][569:58];
                    q_color = cmd[ci][1081:570];
                    @(posedge clk);
                    guard = 0;
                    while (!q_ready && guard < 20000) begin @(posedge clk); guard = guard + 1; end
                    #1 q_valid = 0; q_xy = 32'hx; q_smask = 16'hx; q_sdepth = {512{1'bx}}; q_color = {512{1'bx}};
                    nq = nq + 1;
                    // random gaps
                    k = $unsigned($random(seed)) % 4;
                    repeat (k == 3 ? 2 : 0) @(posedge clk);
                    #0;
                end
                4'd3: begin   // load memory image
                    drain;
                    for (i = 0; i < MEMSZ / 4; i = i + 1) begin
                        w = img[cmd[ci][35:4] * (MEMSZ / 4) + i];
                        for (k = 0; k < 4; k = k + 1) mem.mem[4 * i + k] = w[8*k +: 8];
                    end
                end
                4'd4: begin   // check: expected outputs consumed, memory image
                    guard = 0;
                    while ((ei < cmd[ci][67:36] || busy) && guard < 50000) begin @(posedge clk); #1; guard = guard + 1; end
                    if (guard >= 50000) begin $display("  timeout waiting for %0d quads (got %0d)", cmd[ci][67:36], ei); sec_err = sec_err + 1; end
                    if (ei != cmd[ci][67:36]) begin $display("  %0d quads out, expected %0d", ei, cmd[ci][67:36]); sec_err = sec_err + 1; end
                    k = 0;
                    for (i = 0; i < MEMSZ / 4; i = i + 1) begin
                        w = img[cmd[ci][35:4] * (MEMSZ / 4) + i];
                        if ({mem.mem[4*i+3], mem.mem[4*i+2], mem.mem[4*i+1], mem.mem[4*i]} !== w) begin
                            if (k < 4) $display("  image %0d word @%h: %h exp %h", cmd[ci][35:4], 4 * i,
                                                {mem.mem[4*i+3], mem.mem[4*i+2], mem.mem[4*i+1], mem.mem[4*i]}, w);
                            k = k + 1;
                        end
                    end
                    if (k) sec_err = sec_err + 1;
                end
                4'd5: sec_report(cmd[ci][7:4]);
                default: ;
            endcase
            ci = ci + 1;
        end
        $display("  stats: %0d reads, %0d writes, %0d error responses, %0d shared-line quads, %0d RAW wait cycles",
                 n_rd, n_wr, n_err, n_same, n_raw);
        if (tot_err == 0 && nsec == 6) $display("PASS ad_rop_ds");
        else $display("FAIL ad_rop_ds (%0d errors, %0d sections)", tot_err, nsec);
        $finish;
    end
endmodule
