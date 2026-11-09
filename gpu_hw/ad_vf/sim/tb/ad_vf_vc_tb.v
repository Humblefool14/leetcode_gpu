// ad_vf_vc_tb -- self-checking testbench of ad_vf_vc against an in-TB reference model written
// another way: the cache as a list of entries in allocation order (an unused entry is the next
// slot number after a flush; when full the oldest allocation is replaced and moves to the back).
// Every cycle the combinational lookup (hit, hit_slot, hit_vdata) is compared with the model as
// it is before the clock edge; then the model applies the commit / flush of the cycle.
// Phases: lookup (directed: lookup_valid 0, same-cycle lookup + commit of one index, update),
// commit (random traffic, index pool <= NENTRIES: hits, updates, allocation), replace (pool >>
// NENTRIES: FIFO replacement), flush (random flushes, also with a commit in the same cycle).
// Parameters can be overridden (-Pad_vf_vc_tb.NENTRIES=4 ...).
`timescale 1ns/1ps
module ad_vf_vc_tb;
    parameter NENTRIES = 32, VDATA_W = 512, SLOT_W = 5;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg flush = 0, lookup_valid = 0, commit_valid = 0;
    reg [31:0] lookup_index = 0, commit_index = 0; reg [VDATA_W-1:0] commit_vdata = 0;
    wire hit; wire [VDATA_W-1:0] hit_vdata; wire [SLOT_W-1:0] hit_slot;
    ad_vf_vc #(.NENTRIES(NENTRIES), .VDATA_W(VDATA_W), .SLOT_W(SLOT_W)) dut (.clk(clk), .rst_n(rst_n), .flush(flush),
        .lookup_valid(lookup_valid), .lookup_index(lookup_index), .hit(hit), .hit_vdata(hit_vdata), .hit_slot(hit_slot),
        .commit_valid(commit_valid), .commit_index(commit_index), .commit_vdata(commit_vdata));

    // ---------------- reference model ----------------
    reg [31:0] m_idx [0:NENTRIES-1]; reg [VDATA_W-1:0] m_dat [0:NENTRIES-1];
    integer ord [0:NENTRIES-1];          // slots in allocation order (oldest first)
    integer cnt = 0;                     // allocated entries = slots 0 .. cnt-1
    integer i, s, f, t;
    function integer m_find(input [31:0] x);
        integer q;
        begin
            m_find = -1;
            for (q = 0; q < cnt; q = q + 1) if (m_idx[ord[q]] == x) m_find = ord[q];
        end
    endfunction

    integer phase = 0; integer err [0:3]; integer n_hit [0:3], n_look [0:3], n_upd [0:3], n_alloc [0:3], n_repl [0:3], n_fl [0:3], n_same [0:3];
    integer seed = 7;

    always @(posedge clk) if (rst_n) begin
        // lookup check (pre-edge state)
        if (lookup_valid) n_look[phase] = n_look[phase] + 1;
        f = lookup_valid ? m_find(lookup_index) : -1;
        if (hit !== (f >= 0) || (f >= 0 && (hit_slot !== f || hit_vdata !== m_dat[f])) ||
            (f < 0 && (hit_slot !== 0 || hit_vdata !== 0))) begin
            err[phase] = err[phase] + 1;
            if (err[phase] < 10) $display("FAIL ad_vf_vc lookup phase %0d index %h: hit %b slot %0d, expected hit %b slot %0d", phase, lookup_index, hit, hit_slot, f >= 0, f);
        end
        if (f >= 0) n_hit[phase] = n_hit[phase] + 1;
        if (lookup_valid && commit_valid && lookup_index == commit_index) n_same[phase] = n_same[phase] + 1;
        // model update at the edge
        if (flush) begin
            cnt = 0; n_fl[phase] = n_fl[phase] + 1;
        end else if (commit_valid) begin
            s = m_find(commit_index);
            if (s >= 0) begin m_dat[s] = commit_vdata; n_upd[phase] = n_upd[phase] + 1; end
            else if (cnt < NENTRIES) begin
                s = cnt; ord[cnt] = s; cnt = cnt + 1; m_idx[s] = commit_index; m_dat[s] = commit_vdata;
                n_alloc[phase] = n_alloc[phase] + 1;
            end else begin
                s = ord[0];
                for (t = 0; t < NENTRIES - 1; t = t + 1) ord[t] = ord[t + 1];
                ord[NENTRIES - 1] = s; m_idx[s] = commit_index; m_dat[s] = commit_vdata;
                n_repl[phase] = n_repl[phase] + 1;
            end
        end
    end

    function [VDATA_W-1:0] rdata(input integer dummy);
        integer q;
        begin
            for (q = 0; q < VDATA_W; q = q + 32) rdata[q +: 32] = $random(seed);
        end
    endfunction
    function [31:0] rindex(input integer pool);
        begin
            rindex = ($random(seed) & 15) == 0 ? $random(seed) : ($random(seed) & 32'h7FFFFFFF) % pool;
            if (($random(seed) & 31) == 0) rindex = rindex | 32'h8000_0000;   // high bit set
        end
    endfunction

    task cyc_rand(input integer pool, input integer pc_commit, input integer pc_flush);
        begin
            @(negedge clk);
            lookup_valid = ($random(seed) & 3) != 0;
            lookup_index = rindex(pool);
            commit_valid = ($random(seed) & 255) < pc_commit * 256 / 100;
            commit_index = (($random(seed) & 7) == 0) ? lookup_index : rindex(pool);
            commit_vdata = rdata(0);
            flush = ($random(seed) & 1023) < pc_flush * 1024 / 1000;    // per mille
        end
    endtask

    integer k;
    initial begin
        for (k = 0; k < 4; k = k + 1) begin err[k] = 0; n_hit[k] = 0; n_look[k] = 0; n_upd[k] = 0; n_alloc[k] = 0; n_repl[k] = 0; n_fl[k] = 0; n_same[k] = 0; end
        repeat (3) @(negedge clk); rst_n = 1;
        // phase 0: directed lookup
        phase = 0;
        @(negedge clk); lookup_valid = 1; lookup_index = 32'h1234; commit_valid = 1; commit_index = 32'h1234; commit_vdata = rdata(0);  // same cycle: miss
        @(negedge clk); commit_valid = 0;                                       // now a hit
        @(negedge clk); lookup_valid = 0;                                       // lookup_valid 0: no hit
        @(negedge clk); lookup_valid = 1; commit_valid = 1; commit_vdata = rdata(0);   // update, lookup sees old data
        @(negedge clk); commit_valid = 1; commit_index = 32'hFFFF_FFFF; commit_vdata = rdata(0);
        @(negedge clk); commit_valid = 0; lookup_index = 32'hFFFF_FFFF;
        @(negedge clk); lookup_index = 32'h0;                                   // never committed
        @(negedge clk); flush = 1; lookup_index = 32'h1234;                     // lookup sees pre-flush
        @(negedge clk); flush = 0;
        @(negedge clk); flush = 1; commit_valid = 1; commit_index = 32'h55;      // flush drops the commit
        @(negedge clk); flush = 0; commit_valid = 0; lookup_index = 32'h55;
        @(negedge clk);
        // phase 1: commit / hit traffic within capacity
        @(negedge clk); flush = 1; @(negedge clk); flush = 0; phase = 1;
        for (k = 0; k < 20000; k = k + 1) cyc_rand(NENTRIES, 30, 0);
        // phase 2: replacement (pool 3x capacity, then heavy reuse of a small pool)
        @(negedge clk); flush = 0; commit_valid = 0; phase = 2;
        for (k = 0; k < 30000; k = k + 1) cyc_rand(k < 20000 ? 3 * NENTRIES : NENTRIES + 2, 50, 0);
        // phase 3: random flushes
        @(negedge clk); phase = 3;
        for (k = 0; k < 30000; k = k + 1) cyc_rand(2 * NENTRIES, 50, 8);
        @(negedge clk); lookup_valid = 0; commit_valid = 0; flush = 0;
        @(negedge clk);
        for (k = 0; k < 4; k = k + 1)
            $display("ad_vf_vc phase %0d: lookups %0d hits %0d updates %0d allocs %0d replaces %0d flushes %0d same-index lookup+commit %0d errors %0d",
                k, n_look[k], n_hit[k], n_upd[k], n_alloc[k], n_repl[k], n_fl[k], n_same[k], err[k]);
        if (err[0] == 0 && n_hit[0] >= 3 && n_same[0] >= 2) $display("PASS ad_vf_vc.lookup"); else $display("FAIL ad_vf_vc.lookup");
        if (err[1] == 0 && n_upd[1] > 100 && n_alloc[1] == NENTRIES && n_hit[1] > 1000) $display("PASS ad_vf_vc.commit"); else $display("FAIL ad_vf_vc.commit");
        if (err[2] == 0 && n_repl[2] > 1000) $display("PASS ad_vf_vc.replace"); else $display("FAIL ad_vf_vc.replace");
        if (err[3] == 0 && n_fl[3] > 50 && n_repl[3] > 100) $display("PASS ad_vf_vc.flush"); else $display("FAIL ad_vf_vc.flush");
        if (err[0] + err[1] + err[2] + err[3] == 0) $display("PASS ad_vf_vc"); else $display("FAIL ad_vf_vc");
        $finish;
    end
endmodule
