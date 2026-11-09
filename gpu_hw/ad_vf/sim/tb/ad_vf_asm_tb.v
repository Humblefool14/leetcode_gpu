// ad_vf_asm_tb -- ad_vf_asm against tools/asm_model.py (vectors from tools/gen_asm_vectors.py).
// Per draw: STATE written (TOPOLOGY, INDEX_FORMAT, VERTEX_OFFSET, PROVOKING), the iv items driven
// with random gaps; random vb_ready / prim_ready; conv_done a random time after vb_last; vl_gnt
// from a 64-entry PT model in two 32-entry blocks (a block is granted only when all its entries
// are free; the lanes outside vl_mask return at vl_go, prim_free returns the others).
// Checked: every vb (index after VERTEX_OFFSET, inst, lane, last), vl_mask, vl_go only after the
// warp's conv_done, every primitive (PT entries = ptbase + lane of the right warp, kind, free,
// last) and its vertices against Vulkan's order without warps (reference(), via the vb values),
// every PT entry of a vl_mask lane freed exactly once and never named after it was returned,
// prim_valid only after vl_go, busy low between draws.
`timescale 1ns/1ps
`include "ad_vf_state.vh"
module ad_vf_asm_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0;
    reg iv_valid = 0; wire iv_ready; reg [31:0] iv_index = 0, iv_inst = 0; reg iv_restart = 0, iv_last = 0;
    wire vb_valid; reg vb_ready = 0; wire [31:0] vb_index, vb_inst; wire [4:0] vb_lane; wire vb_last;
    reg conv_done = 0;
    wire vl_req; reg vl_gnt = 0; reg [7:0] vl_ptbase = 0; wire vl_go; wire [31:0] vl_mask;
    wire prim_valid; reg prim_ready = 0; wire [25:0] prim_vtx; wire [2:0] prim_free; wire prim_last; wire busy;

    ad_vf_asm dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .iv_valid(iv_valid), .iv_ready(iv_ready), .iv_index(iv_index), .iv_inst(iv_inst), .iv_restart(iv_restart),
        .iv_last(iv_last), .vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
        .vb_lane(vb_lane), .vb_last(vb_last), .conv_done(conv_done), .vl_req(vl_req), .vl_gnt(vl_gnt),
        .vl_ptbase(vl_ptbase), .vl_go(vl_go), .vl_mask(vl_mask), .prim_valid(prim_valid), .prim_ready(prim_ready),
        .prim_vtx(prim_vtx), .prim_free(prim_free), .prim_last(prim_last), .busy(busy));

    reg [31:0] V [0:1999999];
    integer seed = 7, err = 0, t, ntests, base, sec, topo, prov, indexed, voff, nit, nw, nvb, npr;
    integer o_it, o_w, o_vb, o_pr;
    integer sec_err [0:4];
    integer cyc, i, s, e;

    // progress counters (per draw)
    integer it_ptr, vb_ptr, w_vb, cur_w, gnt_w, go_w, pr_ptr, conv_cnt, w_vb0 [0:255];
    reg     conv_pend, warp_open, go_seen;
    // PT model
    reg        live [0:63];
    reg [1:0]  blk_busy;
    integer    blk_of_w [0:255];
    integer    ent_w [0:63];
    // per draw: vb values per warp lane
    reg [31:0] wl_idx [0:255*32+31];
    reg [31:0] wl_inst [0:255*32+31];

    task fail(input [8*64-1:0] what);
        begin
            err = err + 1; sec_err[sec] = sec_err[sec] + 1;
            if (err < 20) $display("FAIL ad_vf_asm.%0s: %0s (test %0d topo %0d prov %0d) t=%0t",
                                   sec == 0 ? "list" : sec == 1 ? "strip" : sec == 2 ? "restart" : sec == 3 ? "free" : "kind",
                                   what, t, topo, prov, $time);
        end
    endtask

    task st_write(input [8:0] idx, input [31:0] d);
        begin
            @(posedge clk); st_we <= 1; st_idx <= idx; st_wdata <= d;
            @(posedge clk); st_we <= 0;
        end
    endtask

    // ---------------- iv driver ----------------
    reg run = 0;
    always @(posedge clk) if (run) begin
        if (iv_valid && iv_ready) it_ptr = it_ptr + 1;
        if (!iv_valid || iv_ready) begin
            if (it_ptr < nit && ($unsigned($random(seed)) % 100) < 75) begin
                iv_valid   <= 1;
                iv_index   <= V[o_it + 3*it_ptr];
                iv_inst    <= V[o_it + 3*it_ptr + 1];
                iv_restart <= V[o_it + 3*it_ptr + 2][0];
                iv_last    <= V[o_it + 3*it_ptr + 2][1];
            end else begin
                iv_valid <= 0; iv_index <= 32'hx; iv_inst <= 32'hx; iv_restart <= 1'bx; iv_last <= 1'bx;
            end
        end
    end

    // ---------------- vb / conv_done / grant / prim side ----------------
    integer conv_delay, gnt_delay, b, lane;
    reg [7:0] en;
    reg [4:0] el [0:2];
    reg [31:0] ev;
    always @(posedge clk) if (run) begin
        cyc = cyc + 1;
        // vb
        if (vb_valid && vb_ready) begin
            if (!warp_open) fail("vb outside a granted warp");
            else if (cur_w >= nw || vb_ptr >= nvb) fail("too many vb");
            else begin
                if (vb_lane !== w_vb) fail("vb_lane");
                if (vb_index !== V[o_vb + 2*vb_ptr] || vb_inst !== V[o_vb + 2*vb_ptr + 1]) fail("vb_index / vb_inst");
                if (vb_last !== (w_vb + 1 == V[o_w + 2*cur_w + 1])) fail("vb_last");
                wl_idx[cur_w*32 + vb_lane] = vb_index; wl_inst[cur_w*32 + vb_lane] = vb_inst;
                vb_ptr = vb_ptr + 1; w_vb = w_vb + 1;
                if (vb_last) begin warp_open = 0; conv_delay = 1 + ($unsigned($random(seed)) % 12); conv_pend = 1; end
            end
        end
        vb_ready <= ($unsigned($random(seed)) % 100) < 70;
        // conv_done a random time after vb_last
        conv_done <= 0;
        if (conv_pend) begin
            if (conv_delay == 0) begin conv_done <= 1; conv_pend = 0; conv_cnt = conv_cnt + 1; end
            else conv_delay = conv_delay - 1;
        end
        // vl_go
        if (vl_go) begin
            if (conv_cnt != go_w + 1 || warp_open) fail("vl_go before conv_done");
            else begin
                if (vl_mask !== V[o_w + 2*go_w]) fail("vl_mask");
                b = blk_of_w[go_w];
                for (i = 0; i < 32; i = i + 1) if (!vl_mask[i]) live[b*32 + i] = 0;
            end
            go_w = go_w + 1;
        end
        // primitives
        if (prim_valid && (go_w == 0)) fail("prim before vl_go");
        if (prim_valid && prim_ready) begin
            if (pr_ptr >= npr) fail("too many primitives");
            else begin
                ev = V[o_pr + 8*pr_ptr];
                el[0] = ev[4:0]; el[1] = ev[9:5]; el[2] = ev[14:10];
                if (ev[31:16] >= go_w) fail("primitive of a warp not started");
                if (prim_vtx[25:24] !== V[o_pr + 8*pr_ptr + 1][4:3]) fail("prim_vtx[25:24]");
                if (prim_free !== V[o_pr + 8*pr_ptr + 1][2:0]) fail("prim_free vs model");
                if (prim_last !== V[o_pr + 8*pr_ptr + 1][5]) fail("prim_last");
                for (s = 0; s < 3; s = s + 1) begin
                    en = prim_vtx[8*s +: 8];
                    if (en !== blk_of_w[ev[31:16]]*32 + el[s]) fail("PT entry (ptbase + lane)");
                    if (en >= 64 || !live[en]) fail("entry named after its last use / not in vl_mask");
                end
                // free after the whole primitive is read (one slot per entry)
                for (s = 0; s < 3; s = s + 1) if (prim_free[s]) begin
                    en = prim_vtx[8*s +: 8];
                    if (en < 64) begin
                        if (!live[en]) fail("entry freed twice");
                        live[en] = 0;
                    end
                end
                pr_ptr = pr_ptr + 1;
            end
        end
        prim_ready <= ($unsigned($random(seed)) % 100) < 65;
        // blocks: free when all 32 entries are back
        for (b = 0; b < 2; b = b + 1) if (blk_busy[b]) begin
            e = 0; for (i = 0; i < 32; i = i + 1) if (live[b*32 + i]) e = 1;
            if (e == 0) blk_busy[b] = 0;
        end
        // grant
        vl_gnt <= 0;
        if (vl_gnt) begin
            gnt_delay = 0;
        end else if (vl_req && !warp_open) begin
            if (gnt_delay > 0) gnt_delay = gnt_delay - 1;
            else if (!blk_busy[0] || !blk_busy[1]) begin
                b = !blk_busy[0] ? 0 : 1;
                if (blk_busy[0] == 0 && blk_busy[1] == 0) b = $unsigned($random(seed)) % 2;
                blk_busy[b] = 1; for (i = 0; i < 32; i = i + 1) live[b*32 + i] = 1;
                cur_w = gnt_w; blk_of_w[gnt_w] = b; gnt_w = gnt_w + 1; w_vb = 0; warp_open = 1;
                vl_gnt <= 1; vl_ptbase <= b * 32;
                gnt_delay = $unsigned($random(seed)) % 4;
            end
        end
    end

    integer tmo, k, tot_w = 0, tot_vb = 0, tot_pr = 0;
    initial begin
        $readmemh("sim/vec/asm_vec.hex", V);
        for (i = 0; i < 5; i = i + 1) sec_err[i] = 0;
        ntests = V[0];
        repeat (3) @(posedge clk); rst_n <= 1; @(posedge clk);
        sec = 0;
        for (t = 0; t < ntests; t = t + 1) begin
            base = V[1 + t];
            sec = V[base]; topo = V[base+1]; prov = V[base+2]; indexed = V[base+3]; voff = V[base+4];
            nit = V[base+5]; nw = V[base+6]; nvb = V[base+7]; npr = V[base+8];
            o_it = base + 9; o_w = o_it + 3*nit; o_vb = o_w + 2*nw; o_pr = o_vb + 2*nvb;
            if (busy) fail("busy between draws");
            st_write(`AD_S_TOPOLOGY, topo);
            st_write(`AD_S_INDEX_FORMAT, indexed ? 1 + (t % 2) : 0);
            st_write(`AD_S_VERTEX_OFFSET, voff);
            st_write(`AD_S_PROVOKING, prov);
            @(posedge clk);
            it_ptr = 0; vb_ptr = 0; w_vb = 0; cur_w = 0; gnt_w = 0; go_w = 0; pr_ptr = 0; conv_cnt = 0;
            conv_pend = 0; warp_open = 0; gnt_delay = 0; blk_busy = 0; cyc = 0;
            for (i = 0; i < 64; i = i + 1) live[i] = 0;
            run = 1;
            tmo = 0;
            while (!(it_ptr == nit && pr_ptr == npr && go_w == nw && !busy && !iv_valid) && tmo < 20000) begin
                @(posedge clk); tmo = tmo + 1;
            end
            run = 0; @(posedge clk);
            if (tmo >= 20000) fail("timeout");
            tot_w = tot_w + gnt_w; tot_vb = tot_vb + vb_ptr; tot_pr = tot_pr + pr_ptr;
            if (vb_ptr != nvb || gnt_w != nw) fail("vb / warp count");
            for (i = 0; i < 64; i = i + 1) if (live[i]) fail("entry never freed");
            // vertices of each primitive (the vb values sent to its warp lanes) = Vulkan's order
            // without warps (asm_model.reference())
            for (k = 0; k < npr && k < pr_ptr; k = k + 1) begin
                ev = V[o_pr + 8*k];
                el[0] = ev[4:0]; el[1] = ev[9:5]; el[2] = ev[14:10];
                for (s = 0; s < 3; s = s + 1)
                    if (wl_idx[ev[31:16]*32 + el[s]] !== V[o_pr + 8*k + 2 + 2*s] ||
                        wl_inst[ev[31:16]*32 + el[s]] !== V[o_pr + 8*k + 3 + 2*s]) fail("primitive vertices vs reference");
            end
            if (t + 1 == ntests || V[V[2 + t]] != sec) begin
                if (sec_err[sec] == 0) case (sec)
                    0: $display("PASS ad_vf_asm.list");
                    1: $display("PASS ad_vf_asm.strip");
                    2: $display("PASS ad_vf_asm.restart");
                    3: $display("PASS ad_vf_asm.free");
                    4: $display("PASS ad_vf_asm.kind");
                endcase
            end
        end
        $display("INFO ad_vf_asm: %0d draws, %0d warps, %0d vb, %0d primitives checked", ntests, tot_w, tot_vb, tot_pr);
        if (err == 0) $display("PASS ad_vf_asm");
        else $display("FAIL ad_vf_asm (%0d errors)", err);
        $finish;
    end
endmodule
