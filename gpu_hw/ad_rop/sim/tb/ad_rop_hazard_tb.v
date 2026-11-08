// ad_rop_hazard_tb -- burst / RAW directed tests plus a random test against a scoreboard.
`timescale 1ns/1ps
module ad_rop_hazard_tb;
    localparam N = 16, TW = 32;
    reg clk = 0, rst_n = 0;
    reg alloc_valid = 0; reg [TW-1:0] alloc_tag = 0; reg release_valid = 0; reg [3:0] release_id = 0;
    wire alloc_ready; wire [3:0] alloc_id;
    ad_rop_hazard #(.NUM_ENTRIES(N), .TAG_W(TW)) dut (.clk(clk), .rst_n(rst_n), .alloc_valid(alloc_valid),
        .alloc_ready(alloc_ready), .alloc_tag(alloc_tag), .alloc_id(alloc_id),
        .release_valid(release_valid), .release_id(release_id));
    always #5 clk = ~clk;

    function [TW-1:0] mk(input [1:0] rt, input [14:0] y, input [14:0] x); mk = {rt, y, x}; endfunction

    // scoreboard
    reg          m_v [0:N-1];
    reg [TW-1:0] m_t [0:N-1];
    integer err = 0, sec_err, k, j, seed = 11, n_alloc = 0, n_rel = 0, stall_cyc;
    reg exp_rdy, any_free, hit; reg [3:0] exp_id;

    // model of the combinational outputs for the current inputs
    task model_comb;
        integer q;
        begin
            any_free = 0; hit = 0; exp_id = 0;
            for (q = N-1; q >= 0; q = q - 1) begin
                if (!m_v[q] || (release_valid && release_id == q)) begin any_free = 1; exp_id = q; end
                if (m_v[q] && !(release_valid && release_id == q) && m_t[q] == alloc_tag) hit = 1;
            end
            exp_rdy = any_free && !hit;
        end
    endtask
    // check outputs, then clock, then update scoreboard
    task step(input [255:0] sec);
        integer q;
        begin
            #1; model_comb;
            if (alloc_ready !== exp_rdy || (exp_rdy && alloc_id !== exp_id)) begin
                sec_err = sec_err + 1;
                if (sec_err < 6) $display("FAIL %0s rdy %b/%b id %0d/%0d t=%0t", sec, alloc_ready, exp_rdy, alloc_id, exp_id, $time);
            end
            @(posedge clk);
            if (release_valid && release_id < N && m_v[release_id]) begin m_v[release_id] = 0; n_rel = n_rel + 1; end
            if (alloc_valid && exp_rdy) begin m_v[exp_id] = 1; m_t[exp_id] = alloc_tag; n_alloc = n_alloc + 1; end
            // invariant: never two in-flight entries with the same tag
            for (q = 0; q < N; q = q + 1) for (j = q + 1; j < N; j = j + 1)
                if (m_v[q] && m_v[j] && m_t[q] == m_t[j]) begin
                    sec_err = sec_err + 1; $display("FAIL %0s duplicate tag in %0d/%0d", sec, q, j);
                end
            #1;
        end
    endtask
    task idle; begin alloc_valid = 0; release_valid = 0; end endtask

    initial begin
        for (k = 0; k < N; k = k + 1) m_v[k] = 0;
        repeat (2) @(posedge clk); #1 rst_n = 1;

        // ---------------- burst ----------------
        sec_err = 0;
        for (k = 0; k < N; k = k + 1) begin
            alloc_valid = 1; alloc_tag = mk(0, k, k + 1); #1;
            if (!alloc_ready || alloc_id != k) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.burst stall at %0d", k); end
            step("ad_rop_hazard.burst");
        end
        alloc_tag = mk(0, 100, 100);
        repeat (3) begin #1; if (alloc_ready) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.burst full not stalled"); end step("ad_rop_hazard.burst"); end
        // release 5 with an allocation the same cycle: forwarded
        release_valid = 1; release_id = 5; #1;
        if (!alloc_ready || alloc_id != 5) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.burst restore"); end
        step("ad_rop_hazard.burst");
        release_valid = 0; #1;
        if (alloc_ready) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.burst refull"); end
        step("ad_rop_hazard.burst"); idle;
        for (k = 0; k < N; k = k + 1) begin release_valid = 1; release_id = k; step("ad_rop_hazard.burst"); end
        idle; step("ad_rop_hazard.burst");
        if (sec_err == 0) $display("PASS ad_rop_hazard.burst"); err = err + sec_err;

        // ---------------- raw ----------------
        sec_err = 0;
        alloc_valid = 1; alloc_tag = mk(0, 7, 9); step("ad_rop_hazard.raw");   // entry 0
        alloc_tag = mk(0, 3, 3); step("ad_rop_hazard.raw");                    // entry 1
        alloc_tag = mk(0, 7, 9);                                              // same coordinate
        for (k = 0; k < 4; k = k + 1) begin
            #1; if (alloc_ready) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.raw no stall"); end
            step("ad_rop_hazard.raw");
        end
        // distinct attachment same {x,y}: no collision
        alloc_tag = mk(1, 7, 9); #1;
        if (!alloc_ready || alloc_id != 2) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.raw RT collision"); end
        step("ad_rop_hazard.raw");
        // release entry 0 while the stalled quad asks: accepted at once, reuses entry 0
        alloc_tag = mk(0, 7, 9); release_valid = 1; release_id = 0; #1;
        if (!alloc_ready || alloc_id != 0) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.raw no immediate unstall"); end
        step("ad_rop_hazard.raw");
        release_valid = 0; #1;
        if (alloc_ready) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.raw re-lock"); end
        step("ad_rop_hazard.raw"); idle;
        // releasing an invalid entry is ignored
        release_valid = 1; release_id = 9; step("ad_rop_hazard.raw");
        for (k = 0; k < 3; k = k + 1) begin release_id = k; step("ad_rop_hazard.raw"); end
        idle; step("ad_rop_hazard.raw");
        for (k = 0; k < N; k = k + 1) if (m_v[k]) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.raw leftover %0d", k); end
        if (sec_err == 0) $display("PASS ad_rop_hazard.raw"); err = err + sec_err;

        // ---------------- random ----------------
        sec_err = 0; n_alloc = 0; n_rel = 0; stall_cyc = 0;
        for (k = 0; k < 40000; k = k + 1) begin
            alloc_valid = ($random(seed) % 4) != 0;
            alloc_tag = mk($random(seed) & 1, $random(seed) & 3, $random(seed) & 3);   // 32 tags
            release_valid = ($random(seed) % 3) != 0;
            release_id = $random(seed);
            // mostly release in-flight entries
            if (($random(seed) % 8) != 0) begin
                j = $unsigned($random(seed)) % N;
                if (m_v[j]) release_id = j;
            end
            #1; if (alloc_valid && !alloc_ready) stall_cyc = stall_cyc + 1;
            step("ad_rop_hazard.random");
        end
        idle;
        for (k = 0; k < N; k = k + 1) begin release_valid = 1; release_id = k; step("ad_rop_hazard.random"); end
        idle; step("ad_rop_hazard.random");
        if (n_alloc != n_rel) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.random alloc %0d rel %0d", n_alloc, n_rel); end
        if (n_alloc < 10000 || stall_cyc < 1000) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.random coverage %0d %0d", n_alloc, stall_cyc); end
        // after draining every entry is free again
        alloc_valid = 1; alloc_tag = 0; #1;
        if (!alloc_ready || alloc_id != 0) begin sec_err = sec_err + 1; $display("FAIL ad_rop_hazard.random not empty"); end
        if (sec_err == 0) $display("PASS ad_rop_hazard.random (%0d allocations, %0d stall cycles)", n_alloc, stall_cyc); err = err + sec_err;

        if (err == 0) $display("PASS ad_rop_hazard");
        $finish;
    end
endmodule
