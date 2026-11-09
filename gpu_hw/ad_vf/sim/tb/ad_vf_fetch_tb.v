// ad_vf_fetch_tb -- self-checking testbench of ad_vf_fetch (spec/gpu/vf/ad_vf_fetch.md §8).
//
// Vectors: python3 -I tools/gen_fetch_vectors.py (reference: tools/fetch_model.py, sizes from
// tools/fmtmodel.py).  The same command stream (STATE writes, warps of vertices) runs on four
// independent units, each a DUT with its own memory:
//   u0: LINE_BYTES 32, ad_amb_mem (in order, random ready and latency)
//   u1: LINE_BYTES 64, ad_amb_mem (in order, other seed)
//   u2: LINE_BYTES 32, ad_amb_mem_ooo (the out-of-order memory model)
//   u3: LINE_BYTES 64, random-order responder of this file (any order, random latency, errors)
// Every af is compared with the reference (attr, lane, oob, last, and the format's bytes of
// af_raw unless oob; bytes past the size are not compared), af payload is checked stable until
// af_ready, AMB requests are checked (read only, tag {3'b0, s, entry}, tag not in flight, payload
// held until ready) and the number of line reads per section must equal the reference's (the
// reference models the line-buffer policy: no read after a hit, nothing read when out of limit).
// Lines at or above 64 KiB answer rsp_error (their bytes read as 0); ad_amb_mem_ooo has no error
// path, so u2 skips the raw compare of those few afs.
`timescale 1ns/1ps
module ad_vf_fetch_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    localparam NS = 5;
    wire [3:0] done;
    wire [NS*32-1:0] e0, e1, e2, e3, n0, n1, n2, n3;

    ad_vf_fetch_tb_unit #(.LBY(32), .LS(5), .MEMSEL(0), .SEED(11)) u0 (.clk(clk), .rst_n(rst_n), .done(done[0]), .errs(e0), .nafs(n0));
    ad_vf_fetch_tb_unit #(.LBY(64), .LS(6), .MEMSEL(0), .SEED(23)) u1 (.clk(clk), .rst_n(rst_n), .done(done[1]), .errs(e1), .nafs(n1));
    ad_vf_fetch_tb_unit #(.LBY(32), .LS(5), .MEMSEL(1), .SEED(37)) u2 (.clk(clk), .rst_n(rst_n), .done(done[2]), .errs(e2), .nafs(n2));
    ad_vf_fetch_tb_unit #(.LBY(64), .LS(6), .MEMSEL(2), .SEED(41)) u3 (.clk(clk), .rst_n(rst_n), .done(done[3]), .errs(e3), .nafs(n3));

    integer i, tot, e, n;
    reg [8*8-1:0] nm [0:NS-1];
    initial begin
        nm[0] = "addr"; nm[1] = "cross"; nm[2] = "limit"; nm[3] = "limit0"; nm[4] = "size12";
        repeat (5) @(posedge clk);
        rst_n = 1;
        fork
            begin wait (&done); end
            begin #(20_000_000); $display("FAIL ad_vf_fetch timeout (done %b)", done); end
        join_any
        tot = 0;
        for (i = 0; i < NS; i = i + 1) begin
            e = e0[32*i +: 32] + e1[32*i +: 32] + e2[32*i +: 32] + e3[32*i +: 32];
            n = n0[32*i +: 32] + n1[32*i +: 32] + n2[32*i +: 32] + n3[32*i +: 32];
            if (!(&done)) e = e + 1;
            if (e == 0 && n > 0) $display("PASS ad_vf_fetch.%0s  (%0d afs over 4 units)", nm[i], n);
            else $display("FAIL ad_vf_fetch.%0s  (%0d errors, %0d afs)", nm[i], e, n);
            tot = tot + e + (n == 0);
        end
        if (tot == 0) $display("PASS ad_vf_fetch");
        else $display("FAIL ad_vf_fetch");
        $finish;
    end
endmodule

// one DUT + memory + driver + checker
module ad_vf_fetch_tb_unit #(
    parameter LBY    = 32,
    parameter LS     = 5,
    parameter MEMSEL = 0,          // 0 ad_amb_mem, 1 ad_amb_mem_ooo, 2 random-order responder
    parameter SEED   = 1
) (
    input  wire           clk,
    input  wire           rst_n,
    output reg            done,
    output wire [5*32-1:0] errs,
    output wire [5*32-1:0] nafs
);
    localparam AW = 32, LW = AW - LS, LB = LBY * 8, MEMSIZE = 65536, ML = MEMSIZE / LBY;
    localparam NCMD = 16384, NEXP = 65536;

    reg         st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0;
    reg         vb_valid = 0, vb_last = 0; reg [31:0] vb_index = 0, vb_inst = 0; reg [4:0] vb_lane = 0;
    wire        vb_ready;
    wire        af_valid, af_oob, af_last, busy; reg af_ready = 0;
    wire [3:0]  af_attr; wire [4:0] af_lane; wire [127:0] af_raw;
    wire        req_valid, req_write; wire req_ready; wire [LW-1:0] req_line; wire [LBY-1:0] req_be;
    wire [LB-1:0] req_wdata; wire [7:0] req_tag;
    wire        rsp_valid, rsp_write, rsp_error; wire [7:0] rsp_tag; wire [LB-1:0] rsp_rdata;

    ad_vf_fetch #(.ADDR_W(AW), .LINE_BYTES(LBY), .LINE_SHIFT(LS)) dut (.clk(clk), .rst_n(rst_n),
        .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst), .vb_lane(vb_lane), .vb_last(vb_last),
        .af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane), .af_raw(af_raw),
        .af_oob(af_oob), .af_last(af_last), .busy(busy),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line), .req_be(req_be),
        .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
        .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));

    // ---------------------------------------------------------------- memories
    generate if (MEMSEL == 0) begin : g_m
        ad_amb_mem #(.LINE_BYTES(LBY), .LINE_SHIFT(LS), .ADDR_W(AW), .MEM_LINES(ML), .LAT_MIN(1), .LAT_MAX(25),
                     .READY_PCT(60), .SEED(SEED)) u_mem (.clk(clk), .rst_n(rst_n),
            .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line), .req_be(req_be),
            .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
            .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
        initial $readmemh("sim/vec/fetch_mem.hex", u_mem.mem);
    end else if (MEMSEL == 1) begin : g_m
        ad_amb_mem_ooo #(.LINE_BYTES(LBY), .LINE_SHIFT(LS), .ADDR_W(AW), .MEM_LINES(ML)) u_mem (.clk(clk), .rst_n(rst_n),
            .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line), .req_be(req_be),
            .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
            .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
        initial $readmemh("sim/vec/fetch_mem.hex", u_mem.mem);
    end else begin : g_m
        // random-order responder: up to 8 requests held, each answered after 1..30 cycles, the
        // ready ones in random order; lines at or above ML answer rsp_error
        reg [7:0] bmem [0:MEMSIZE-1];
        initial $readmemh("sim/vec/fetch_mem.hex", bmem);
        reg r_ready = 0, r_valid = 0, r_err = 0; reg [7:0] r_tag = 0; reg [LB-1:0] r_data = 0;
        reg sv [0:7]; reg [LW-1:0] sl [0:7]; reg [7:0] st [0:7]; integer sd [0:7];
        integer cyc = 0, x, y, b, nfree, seed = SEED;
        initial for (x = 0; x < 8; x = x + 1) sv[x] = 0;
        always @(posedge clk) begin
            cyc = cyc + 1;
            r_valid <= 1'b0;
            if (rst_n) begin
                if (req_valid && r_ready) begin
                    y = -1;
                    for (x = 7; x >= 0; x = x - 1) if (!sv[x]) y = x;
                    sv[y] = 1; sl[y] = req_line; st[y] = req_tag; sd[y] = cyc + 1 + ($unsigned($random(seed)) % 30);
                end
                y = -1; b = $unsigned($random(seed)) % 8;
                for (x = 0; x < 8; x = x + 1) if (y < 0 && sv[(b + x) % 8] && sd[(b + x) % 8] <= cyc) y = (b + x) % 8;
                if (y >= 0) begin
                    sv[y] = 0;
                    r_valid <= 1'b1; r_tag <= st[y]; r_err <= (sl[y] >= ML);
                    for (x = 0; x < LBY; x = x + 1)
                        r_data[8*x +: 8] <= (sl[y] >= ML) ? 8'hxx : bmem[(sl[y] << LS) + x];
                end
                nfree = 0;
                for (x = 0; x < 8; x = x + 1) if (!sv[x]) nfree = nfree + 1;
                r_ready <= (nfree > 0) && (($unsigned($random(seed)) % 100) < 60);
            end else r_ready <= 1'b0;
        end
        assign req_ready = r_ready; assign rsp_valid = r_valid; assign rsp_write = 1'b0; assign rsp_tag = r_tag;
        assign rsp_rdata = r_data; assign rsp_error = r_err;
    end endgenerate

    // ---------------------------------------------------------------- vectors
    reg [79:0]  cmd [0:NCMD-1];
    reg [159:0] exp [0:NEXP-1];
    reg [31:0]  nreq_exp [0:7];
    reg [31:0]  cnt [0:1];
    initial begin
        $readmemh("sim/vec/fetch_cnt.hex", cnt);
        $readmemh("sim/vec/fetch_cmd.hex", cmd, 0, cnt[0] - 1);
        $readmemh("sim/vec/fetch_exp.hex", exp, 0, cnt[1] - 1);
        if (LBY == 32) $readmemh("sim/vec/fetch_nreq32.hex", nreq_exp);
        else           $readmemh("sim/vec/fetch_nreq64.hex", nreq_exp);
    end

    integer err [0:4], naf [0:4], nreq [0:4];
    genvar g;
    generate for (g = 0; g < 5; g = g + 1) begin : g_o
        assign errs[32*g +: 32] = err[g];
        assign nafs[32*g +: 32] = naf[g];
    end endgenerate

    // ---------------------------------------------------------------- driver
    integer pc, sect = 0, n_got = 0, seed = SEED + 1000, i;
    reg [79:0] c;
    initial begin
        done = 0;
        for (i = 0; i < 5; i = i + 1) begin err[i] = 0; naf[i] = 0; nreq[i] = 0; end
        @(posedge rst_n);
        pc = 0;
        while (!done) begin
            c = cmd[pc]; pc = pc + 1;
            case (c[79:76])
                4'd1: begin
                    @(negedge clk); st_we = 1; st_idx = c[40:32]; st_wdata = c[31:0];
                    @(negedge clk); st_we = 0;
                end
                4'd2: begin
                    repeat ($unsigned($random(seed)) % 3) @(negedge clk);
                    @(negedge clk);
                    vb_valid = 1; vb_index = c[31:0]; vb_inst = c[63:32]; vb_lane = c[68:64]; vb_last = c[69];
                    @(posedge clk); while (!vb_ready) @(posedge clk);
                    @(negedge clk); vb_valid = 0; vb_index = 32'hx; vb_inst = 32'hx;
                end
                4'd3: sect = c[2:0];
                4'd4: begin
                    @(negedge clk);
                    while (n_got < c[31:0] || busy) @(negedge clk);
                end
                4'd15: begin
                    for (i = 0; i < 5; i = i + 1) if (nreq[i] != nreq_exp[i]) begin
                        err[i] = err[i] + 1;
                        $display("FAIL ad_vf_fetch.unit LBY %0d MEM %0d section %0d: %0d line reads, reference %0d",
                                 LBY, MEMSEL, i, nreq[i], nreq_exp[i]);
                    end
                    done = 1;
                end
                default: begin $display("FAIL ad_vf_fetch bad command %h at %0d", c, pc - 1); err[0] = err[0] + 1; done = 1; end
            endcase
        end
    end

    always @(negedge clk) af_ready <= (($unsigned($random(seed)) % 100) < 70);

    // ---------------------------------------------------------------- checker
    reg [159:0] x; reg [127:0] mask; integer es, b;
    reg         p_afv = 0, p_afr = 0, p_afo, p_afl; reg [3:0] p_afa; reg [4:0] p_afn; reg [127:0] p_raw;
    reg         p_rv = 0, p_rr = 0; reg [LW-1:0] p_rl; reg [7:0] p_rt;
    reg [31:0]  inflight = 0;
    always @(posedge clk) if (rst_n) begin
        // af payload held until taken
        if (p_afv && !p_afr && (!af_valid || af_attr !== p_afa || af_lane !== p_afn || af_oob !== p_afo ||
                                af_last !== p_afl || (!p_afo && af_raw !== p_raw))) begin
            err[sect] = err[sect] + 1;
            if (err[sect] < 5) $display("FAIL ad_vf_fetch.unit LBY %0d: af changed before af_ready t=%0t", LBY, $time);
        end
        p_afv <= af_valid; p_afr <= af_ready; p_afa <= af_attr; p_afn <= af_lane; p_afo <= af_oob;
        p_afl <= af_last; p_raw <= af_raw;
        if (af_valid && af_ready) begin
            x = exp[n_got]; es = x[147:145];
            mask = 128'd0;
            for (b = 0; b < 16; b = b + 1) if (b < x[143:139]) mask[8*b +: 8] = 8'hFF;
            if (x[137] || (x[144] && MEMSEL == 1)) mask = 128'd0;
            if (af_attr !== x[131:128] || af_lane !== x[136:132] || af_oob !== x[137] || af_last !== x[138] ||
                ((af_raw & mask) !== (x[127:0] & mask))) begin
                err[es] = err[es] + 1;
                if (err[es] < 6)
                    $display("FAIL ad_vf_fetch.unit LBY %0d MEM %0d af %0d: got attr %0d lane %0d oob %b last %b raw %h; exp attr %0d lane %0d oob %b last %b size %0d raw %h",
                             LBY, MEMSEL, n_got, af_attr, af_lane, af_oob, af_last, af_raw & mask,
                             x[131:128], x[136:132], x[137], x[138], x[143:139], x[127:0] & mask);
            end
            naf[es] = naf[es] + 1;
            n_got = n_got + 1;
        end
        // AMB requests
        if (p_rv && !p_rr && (!req_valid || req_line !== p_rl || req_tag !== p_rt)) begin
            err[sect] = err[sect] + 1; $display("FAIL ad_vf_fetch.unit LBY %0d: request changed before ready", LBY);
        end
        p_rv <= req_valid; p_rr <= req_ready; p_rl <= req_line; p_rt <= req_tag;
        if (rsp_valid) inflight[rsp_tag[4:0]] = 1'b0;
        if (req_valid && req_ready) begin
            if (req_write || req_tag[7:5] != 3'b000 || inflight[req_tag[4:0]]) begin
                err[sect] = err[sect] + 1;
                $display("FAIL ad_vf_fetch.unit LBY %0d: bad request write %b tag %h", LBY, req_write, req_tag);
            end
            inflight[req_tag[4:0]] = 1'b1;
            nreq[sect] = nreq[sect] + 1;
        end
        if (!busy && (inflight != 0 || af_valid || req_valid)) begin
            err[sect] = err[sect] + 1; $display("FAIL ad_vf_fetch.unit LBY %0d: idle with work outstanding", LBY);
        end
    end
endmodule
