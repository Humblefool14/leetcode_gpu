// ad_amb_mux_tb -- two random AMB clients behind ad_amb_mux and an ad_amb_mem.  Both clients
// use the same tag values; each must get exactly its own responses, with its own tags, in any
// order, with correct data / error.  A flat reference memory is updated in acceptance order.
`timescale 1ns/1ps
module ad_amb_mux_tb;
    localparam N = 2, AW = 32, LBY = 32, LS = 5, LW = AW - LS, LB = LBY*8, ML = 256;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [N-1:0] c_req_valid = 0, c_req_write = 0;
    reg  [N*LW-1:0] c_req_line = 0; reg [N*LBY-1:0] c_req_be = 0; reg [N*LB-1:0] c_req_wdata = 0;
    reg  [N*8-1:0] c_req_tag = 0;
    wire [N-1:0] c_req_ready, c_rsp_valid; wire c_rsp_write, c_rsp_error; wire [7:0] c_rsp_tag; wire [LB-1:0] c_rsp_rdata;
    wire m_req_valid, m_req_ready, m_req_write, m_rsp_valid, m_rsp_write, m_rsp_error;
    wire [LW-1:0] m_req_line; wire [LBY-1:0] m_req_be; wire [LB-1:0] m_req_wdata, m_rsp_rdata; wire [7:0] m_req_tag, m_rsp_tag;

    ad_amb_mux #(.ADDR_W(AW), .LINE_BYTES(LBY), .LINE_SHIFT(LS), .N(N)) dut (.clk(clk), .rst_n(rst_n),
        .c_req_valid(c_req_valid), .c_req_ready(c_req_ready), .c_req_write(c_req_write), .c_req_line(c_req_line),
        .c_req_be(c_req_be), .c_req_wdata(c_req_wdata), .c_req_tag(c_req_tag), .c_rsp_valid(c_rsp_valid),
        .c_rsp_write(c_rsp_write), .c_rsp_tag(c_rsp_tag), .c_rsp_rdata(c_rsp_rdata), .c_rsp_error(c_rsp_error),
        .m_req_valid(m_req_valid), .m_req_ready(m_req_ready), .m_req_write(m_req_write), .m_req_line(m_req_line),
        .m_req_be(m_req_be), .m_req_wdata(m_req_wdata), .m_req_tag(m_req_tag), .m_rsp_valid(m_rsp_valid),
        .m_rsp_write(m_rsp_write), .m_rsp_tag(m_rsp_tag), .m_rsp_rdata(m_rsp_rdata), .m_rsp_error(m_rsp_error));
    ad_amb_mem #(.LINE_BYTES(LBY), .LINE_SHIFT(LS), .ADDR_W(AW), .MEM_LINES(ML), .LAT_MIN(1), .LAT_MAX(40),
                 .READY_PCT(70), .SEED(9)) u_mem (.clk(clk), .rst_n(rst_n),
        .req_valid(m_req_valid), .req_ready(m_req_ready), .req_write(m_req_write), .req_line(m_req_line),
        .req_be(m_req_be), .req_wdata(m_req_wdata), .req_tag(m_req_tag), .rsp_valid(m_rsp_valid),
        .rsp_write(m_rsp_write), .rsp_tag(m_rsp_tag), .rsp_rdata(m_rsp_rdata), .rsp_error(m_rsp_error));

    reg [7:0] ref_mem [0:ML*LBY-1];
    // per client, per tag: outstanding flag and expectation
    reg          o_v   [0:N-1][0:255];
    reg          o_w   [0:N-1][0:255];
    reg          o_err [0:N-1][0:255];
    reg [LB-1:0] o_d   [0:N-1][0:255];
    integer      n_out [0:N-1], n_req [0:N-1], n_rsp [0:N-1], nxt_tag [0:N-1];
    integer err = 0, seed = 21, i, j, b, cyc = 0, full_cyc = 0, alt = 0, both = 0;
    integer last_g = -1;
    reg [LW-1:0] ln;

    // monitor at each edge: accepted requests, responses (pre-edge values)
    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        if (&dut.ent_v && |c_req_valid) full_cyc = full_cyc + 1;
        if ($countones(c_req_ready) > 1) begin err = err + 1; $display("FAIL ad_amb_mux.route two readys"); end
        if (c_req_valid == 2'b11 && |c_req_ready) both = both + 1;
        for (i = 0; i < N; i = i + 1) if (c_req_valid[i] && c_req_ready[i]) begin
            if (c_req_valid == 2'b11 && last_g >= 0 && last_g != i) alt = alt + 1;
            last_g = i;
            j = c_req_tag[8*i +: 8]; ln = c_req_line[LW*i +: LW];
            o_v[i][j] = 1; o_w[i][j] = c_req_write[i]; o_err[i][j] = (ln >= ML);
            if (ln < ML) for (b = 0; b < LBY; b = b + 1) begin
                if (c_req_write[i] && c_req_be[LBY*i + b]) ref_mem[ln*LBY + b] = c_req_wdata[LB*i + 8*b +: 8];
                o_d[i][j][8*b +: 8] = ref_mem[ln*LBY + b];
            end
            n_out[i] = n_out[i] + 1; n_req[i] = n_req[i] + 1;
        end
        if ($countones(c_rsp_valid) > 1) begin err = err + 1; $display("FAIL ad_amb_mux.route response to two clients"); end
        if (m_rsp_valid && c_rsp_valid == 0) begin err = err + 1; $display("FAIL ad_amb_mux.route response lost"); end
        for (i = 0; i < N; i = i + 1) if (c_rsp_valid[i]) begin
            j = c_rsp_tag;
            if (!o_v[i][j]) begin err = err + 1; $display("FAIL ad_amb_mux.route client %0d tag %0d not outstanding", i, j); end
            else begin
                if (c_rsp_write !== o_w[i][j] || c_rsp_error !== o_err[i][j] ||
                    (!o_w[i][j] && !o_err[i][j] && c_rsp_rdata !== o_d[i][j])) begin
                    err = err + 1; if (err < 8) $display("FAIL ad_amb_mux.route client %0d tag %0d payload", i, j);
                end
                o_v[i][j] = 0; n_out[i] = n_out[i] - 1; n_rsp[i] = n_rsp[i] + 1;
            end
        end
    end

    // downstream protocol: payload held until m_req_ready
    reg p_v = 0, p_r = 0, p_w; reg [LW-1:0] p_l; reg [LBY-1:0] p_be; reg [LB-1:0] p_d; reg [7:0] p_t;
    always @(posedge clk) begin
        if (rst_n && p_v && !p_r && (!m_req_valid || m_req_write !== p_w || m_req_line !== p_l ||
            m_req_be !== p_be || m_req_wdata !== p_d || m_req_tag !== p_t)) begin
            err = err + 1; if (err < 8) $display("FAIL ad_amb_mux.route downstream request changed before ready t=%0t", $time);
        end
        p_v <= m_req_valid && rst_n; p_r <= m_req_ready; p_w <= m_req_write; p_l <= m_req_line;
        p_be <= m_req_be; p_d <= m_req_wdata; p_t <= m_req_tag;
    end

    // client drivers: new random request when idle or just accepted; payload held until ready
    task new_req(input integer ci); begin
        c_req_valid[ci] = 1;
        c_req_write[ci] = $random(seed);
        c_req_line[LW*ci +: LW] = (($random(seed) % 50) == 0) ? ML + ($unsigned($random(seed)) % 4) : $unsigned($random(seed)) % 32;
        c_req_be[LBY*ci +: LBY] = $random(seed);
        for (b = 0; b < LB/32; b = b + 1) c_req_wdata[LB*ci + 32*b +: 32] = $random(seed);
        // next free tag of this client (tags wrap; skip outstanding ones)
        while (o_v[ci][nxt_tag[ci]]) nxt_tag[ci] = (nxt_tag[ci] + 1) % 256;
        c_req_tag[8*ci +: 8] = nxt_tag[ci]; nxt_tag[ci] = (nxt_tag[ci] + 1) % 256;
    end endtask

    integer k, busy_ph;
    reg [N-1:0] acc = 0;
    always @(posedge clk) acc <= c_req_valid & c_req_ready;   // read by the driver after the edge
    initial begin
        for (i = 0; i < N; i = i + 1) begin n_out[i] = 0; n_req[i] = 0; n_rsp[i] = 0; nxt_tag[i] = 0;
            for (j = 0; j < 256; j = j + 1) o_v[i][j] = 0; end
        #1;
        for (i = 0; i < ML*LBY; i = i + 1) begin u_mem.mem[i] = $random(seed); ref_mem[i] = u_mem.mem[i]; end
        repeat (3) @(posedge clk); #1 rst_n = 1;
        for (k = 0; k < 40000; k = k + 1) begin
            @(posedge clk); #1;
            busy_ph = ((k / 2000) % 2) == 0;     // phases: both always requesting / sparse
            for (j = 0; j < N; j = j + 1)
                if (!c_req_valid[j] || acc[j]) begin
                    c_req_valid[j] = 0;
                    if (n_out[j] < 60 && (busy_ph || ($unsigned($random(seed)) % 100) < 30)) new_req(j);
                end
        end
        // drain
        @(posedge clk); #1;
        while (c_req_valid != 0) begin for (j = 0; j < N; j = j + 1) if (acc[j]) c_req_valid[j] = 0; @(posedge clk); #1; end
        k = 0;
        while ((n_out[0] != 0 || n_out[1] != 0) && k < 2000) begin @(posedge clk); #1; k = k + 1; end
        for (i = 0; i < N; i = i + 1)
            if (n_out[i] != 0 || n_req[i] != n_rsp[i] || n_req[i] < 5000) begin
                err = err + 1; $display("FAIL ad_amb_mux.route client %0d req %0d rsp %0d out %0d", i, n_req[i], n_rsp[i], n_out[i]);
            end
        if (full_cyc < 100 || alt < 1000) begin err = err + 1; $display("FAIL ad_amb_mux.route coverage full %0d alt %0d", full_cyc, alt); end
        // round robin: with both requesting, grants alternate
        if (alt * 10 < both * 9) begin err = err + 1; $display("FAIL ad_amb_mux.route not round-robin (%0d of %0d)", alt, both); end
        if (err == 0) $display("PASS ad_amb_mux.route (%0d + %0d requests, %0d table-full cycles)", n_req[0], n_req[1], full_cyc);
        if (err == 0) $display("PASS ad_amb_mux");
        $finish;
    end
endmodule
