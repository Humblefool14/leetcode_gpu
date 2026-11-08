// ad_su_pt_tb -- ad_su_pt.  .pt: one vertex warp's exp instructions (sim/vec/gfx_pt_cmd.hex,
// tools/gen_gfx_vectors.py: POS 0x000-0x003, point size 0x004, varyings 0x010+v also past
// VARY_WORDS, fragment targets; then a fragment and a compute warp's exp of PT targets) into the
// warp's block (block 1: entries 32-63) after a scrub, every entry and word read back through
// pt_rd against tools/gsi1model.py --pt-out (gfx_pt_exp.hex; unwritten words read 0), NPHYS 8, 4,
// 16 and 32.  .alloc: random takes (pt_ok, pt_base the lowest free block), vl_go with random
// vl_mask (also 0 and all ones), frees of the entries in use, warp ends of owners and of other
// slots, the stale owner (a block returned by vl_mask 0 and retaken: the first owner's end leaves
// pt_done 0), against an in-TB scoreboard of counts, owners and pt_done; counts never below 0.
`timescale 1ns/1ps
module pt_h #(parameter NPHYS = 8, parameter SEED = 1) (
    input  wire clk,
    input  wire rst_n,
    input  wire run,
    output reg  done,
    output reg [31:0] e_pt,
    output reg [31:0] e_al,
    output reg [31:0] nchk
);
`include "ad_su_uop.vh"
    localparam WARP_W = 2, GRP_W = (NPHYS == 32) ? 1 : $clog2(32 / NPHYS), GPW = 32 / NPHYS;
    localparam PTE = 64, VW = 16, NB = PTE / 32;
    reg [31:0] cmd [0:2047];
    reg [35:0] pexp [0:32*(4+VW)-1];
    initial begin
        $readmemh("sim/vec/gfx_pt_cmd.hex", cmd);
        $readmemh("sim/vec/gfx_pt_exp.hex", pexp);
    end
    reg x_valid; reg [WARP_W-1:0] x_warp; reg [GRP_W-1:0] x_grp; reg [107:0] x_uop;
    reg [NPHYS*32-1:0] x_b; reg [2*NPHYS-1:0] x_mask; reg [31:0] x_info;
    reg pt_rd; reg [7:0] pt_idx; reg [6:0] pt_word; wire [31:0] pt_rdata;
    reg pt_free; reg [7:0] pt_free_idx; wire pt_ok; reg pt_take; reg [WARP_W-1:0] pt_warp;
    wire [7:0] pt_base; reg vl_go; reg [31:0] vl_mask; wire [7:0] pt_done;
    reg wc_end; reg [WARP_W-1:0] wc_warp; reg scrub; wire scrub_busy;
    ad_su_pt #(.NPHYS(NPHYS), .NWARPS(4), .WARP_W(WARP_W), .GRP_W(GRP_W), .PT_ENTRIES(PTE),
               .VARY_WORDS(VW)) dut (
        .clk(clk), .rst_n(rst_n), .x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp),
        .x_uop(x_uop), .x_b(x_b), .x_mask(x_mask), .x_info(x_info), .pt_rd(pt_rd),
        .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata), .pt_free(pt_free),
        .pt_free_idx(pt_free_idx), .pt_ok(pt_ok), .pt_take(pt_take), .pt_warp(pt_warp),
        .pt_base(pt_base), .vl_go(vl_go), .vl_mask(vl_mask), .pt_done(pt_done),
        .wc_end(wc_end), .wc_warp(wc_warp), .scrub(scrub), .scrub_busy(scrub_busy));

    integer seed;
    initial seed = SEED;
    integer pc, g, k, e, w, t, n, b, it, i;
    reg [31:0] v;

    // scoreboard of the allocator
    integer cnt [0:NB-1];
    integer owner [0:NB-1];
    reg [NB-1:0] sdone;
    reg [31:0] live [0:NB-1];
    reg [3:0] running;               // slots with a vertex warp that took a block
    integer gob;                     // block awaiting vl_go (-1: none)
    integer lowfree;

    task check_alloc;
        begin
            lowfree = -1;
            for (b = NB - 1; b >= 0; b = b - 1) if (cnt[b] == 0) lowfree = b;
            if (pt_ok !== (lowfree >= 0) || (lowfree >= 0 && pt_base !== lowfree * 32) ||
                pt_done !== {{(8-NB){1'b0}}, sdone}) begin
                e_al = e_al + 1;
                $display("FAIL pt%0d: pt_ok %b pt_base %0d pt_done %b, expected %0d %b", NPHYS,
                         pt_ok, pt_base, pt_done, lowfree, sdone);
            end
            for (b = 0; b < NB; b = b + 1)
                if (dut.alloc.cnt[b] !== cnt[b]) begin
                    e_al = e_al + 1;
                    $display("FAIL pt%0d: block %0d count %0d expected %0d", NPHYS, b,
                             dut.alloc.cnt[b], cnt[b]);
                end
            nchk = nchk + 1;
        end
    endtask

    initial begin
        done = 0; e_pt = 0; e_al = 0; nchk = 0;
        x_valid = 0; x_warp = 0; x_grp = 0; x_uop = 0; x_b = 0; x_mask = 0; x_info = 0;
        pt_rd = 0; pt_idx = 0; pt_word = 0; pt_free = 0; pt_free_idx = 0; pt_take = 0;
        pt_warp = 0; vl_go = 0; vl_mask = 0; wc_end = 0; wc_warp = 0; scrub = 0;
        @(posedge run);
        @(posedge clk);
        // ---------------- .pt ----------------
        scrub <= 1;
        @(posedge clk);
        scrub <= 0;
        @(posedge clk);
        t = 0;
        while (scrub_busy) begin
            @(posedge clk);
            t = t + 1;
        end
        if (t != PTE / NPHYS * (4 + VW)) begin
            e_pt = e_pt + 1;
            $display("FAIL pt%0d: scrub %0d cycles", NPHYS, t);
        end
        // slot 3 takes block 0 (all lanes used), slot 1 block 1
        pt_take <= 1; pt_warp <= 3;
        @(posedge clk);
        pt_take <= 0;
        vl_go <= 1; vl_mask <= 32'hFFFF_FFFF;
        @(posedge clk);
        vl_go <= 0;
        if (pt_base !== 8'd32) begin
            e_pt = e_pt + 1;
            $display("FAIL pt%0d: second block base %0d", NPHYS, pt_base);
        end
        pt_take <= 1; pt_warp <= 1;
        @(posedge clk);
        pt_take <= 0;
        pc = 0;
        while (cmd[pc] == 4) begin
            for (g = 0; g < GPW; g = g + 1) begin
                while ($random(seed) & 1) @(posedge clk);
                x_valid <= 1;
                x_warp <= 1;
                x_grp <= g;
                x_info <= {14'd0, cmd[pc+2][1:0], 16'd0};
                x_uop <= 108'd0;
                x_uop[AD_UOP_UNIT +: 4] <= AD_UNIT_EXP;
                x_uop[AD_UOP_IMM +: 32] <= cmd[pc+3];
                for (k = 0; k < NPHYS; k = k + 1) begin
                    x_b[32*k +: 32] <= cmd[pc + 5 + g*NPHYS + k];
                    x_mask[k] <= 1'b1;
                    x_mask[NPHYS + k] <= cmd[pc+4][g*NPHYS + k];
                end
                @(posedge clk);
                x_valid <= 0;
                // another unit's group with a PT target: ignored
                if (($random(seed) & 3) == 0) begin
                    x_valid <= 1;
                    x_uop[AD_UOP_UNIT +: 4] <= AD_UNIT_LSU;
                    x_info <= 32'd0;
                    x_mask <= {2*NPHYS{1'b1}};
                    @(posedge clk);
                    x_valid <= 0;
                end
            end
            pc = pc + 37;
        end
        for (e = 0; e < 32; e = e + 1)
            for (w = 0; w < 4 + VW; w = w + 1) begin
                pt_rd <= 1; pt_idx <= 32 + e; pt_word <= w;
                @(posedge clk);
                pt_rd <= 0;
                n = $random(seed) & 3;
                repeat (n) @(posedge clk);
                #1;
                v = pexp[e * (4 + VW) + w][32] ? pexp[e * (4 + VW) + w][31:0] : 32'd0;
                if (pt_rdata !== v) begin
                    e_pt = e_pt + 1;
                    $display("FAIL pt%0d: entry %0d word %0d: %h expected %h", NPHYS, 32 + e, w,
                             pt_rdata, v);
                end
            end
        // block 0 untouched
        pt_rd <= 1; pt_idx <= 5; pt_word <= 1;
        @(posedge clk);
        pt_rd <= 0;
        #1;
        if (pt_rdata !== 32'd0) begin
            e_pt = e_pt + 1;
            $display("FAIL pt%0d: block 0 written", NPHYS);
        end
        // ---------------- .alloc ----------------
        @(posedge clk);
        scrub <= 0;
        // the TB's state after the .pt part: block 0 slot 3 (32), block 1 slot 1 (32, no go)
        for (b = 0; b < NB; b = b + 1) begin
            cnt[b] = 32; sdone[b] = 0; live[b] = (b == 0) ? 32'hFFFF_FFFF : 32'd0;
        end
        owner[0] = 3; owner[1] = 1;
        running = 4'b1010;
        gob = 1;
        // go of block 1 with vl_mask 0: returned at once
        vl_go <= 1; vl_mask <= 32'd0;
        @(posedge clk);
        vl_go <= 0;
        cnt[1] = 0; gob = -1;
        #1 check_alloc;
        // stale owner: slot 2 retakes block 1, slot 1 (its old owner) ends
        pt_take <= 1; pt_warp <= 2;
        @(posedge clk);
        pt_take <= 0;
        cnt[1] = 32; owner[1] = 2; sdone[1] = 0; running[2] = 1; gob = 1;
        #1 check_alloc;
        wc_end <= 1; wc_warp <= 1;
        @(posedge clk);
        wc_end <= 0;
        running[1] = 0;
        #1 check_alloc;
        // random traffic
        for (it = 0; it < 6000; it = it + 1) begin
            @(negedge clk);
            pt_take = 0; vl_go = 0; pt_free = 0; wc_end = 0;
            // take: when no go is awaited, a free block, a slot without a running warp
            if (gob < 0 && pt_ok && running != 4'hF && ($random(seed) & 3) == 0) begin
                k = $random(seed) & 3;
                while (running[k]) k = (k + 1) & 3;
                pt_take = 1; pt_warp = k;
            end else if (gob >= 0 && ($random(seed) & 3) == 0) begin
                vl_go = 1;
                n = $random(seed) & 7;
                vl_mask = (n == 0) ? 32'd0 : (n == 1) ? 32'hFFFF_FFFF : $random(seed);
            end
            // free an entry in use
            if (($random(seed) & 1)) begin
                b = $random(seed) & (NB - 1);
                if (live[b] != 0) begin
                    i = $random(seed) & 31;
                    while (!live[b][i]) i = (i + 1) & 31;
                    pt_free = 1; pt_free_idx = b * 32 + i;
                end
            end
            // a warp end: a running slot (owner or not)
            if (!pt_take && ($random(seed) & 7) == 0) begin
                k = $random(seed) & 3;
                if (running[k] && !(gob >= 0 && owner[gob] == k)) begin
                    wc_end = 1; wc_warp = k;
                end
            end
            @(posedge clk);
            // scoreboard
            if (pt_take) begin
                lowfree = -1;
                for (b = NB - 1; b >= 0; b = b - 1) if (cnt[b] == 0) lowfree = b;
                cnt[lowfree] = 32; owner[lowfree] = pt_warp; sdone[lowfree] = 0;
                running[pt_warp] = 1; gob = lowfree;
            end
            if (vl_go) begin
                for (i = 0; i < 32; i = i + 1) if (!vl_mask[i]) cnt[gob] = cnt[gob] - 1;
                live[gob] = vl_mask;
                gob = -1;
            end
            if (pt_free) begin
                cnt[pt_free_idx / 32] = cnt[pt_free_idx / 32] - 1;
                live[pt_free_idx / 32][pt_free_idx % 32] = 1'b0;
            end
            if (wc_end) begin
                for (b = 0; b < NB; b = b + 1) if (owner[b] == wc_warp) sdone[b] = 1;
                running[wc_warp] = 0;
            end
            for (b = 0; b < NB; b = b + 1)
                if (cnt[b] < 0 || cnt[b] > 32) begin
                    e_al = e_al + 1;
                    $display("FAIL pt%0d: count %0d of block %0d", NPHYS, cnt[b], b);
                end
            #1 check_alloc;
        end
        done = 1;
    end
endmodule

module ad_su_pt_tb;
    reg clk = 0, rst_n = 0, run = 0;
    always #5 clk = ~clk;
    wire d8, d4, d16, d32;
    wire [31:0] p8, a8, n8, p4, a4, n4, p16, a16, n16, p32, a32, n32;
    pt_h #(.NPHYS(8), .SEED(3)) h8 (.clk(clk), .rst_n(rst_n), .run(run), .done(d8), .e_pt(p8),
        .e_al(a8), .nchk(n8));
    pt_h #(.NPHYS(4), .SEED(5)) h4 (.clk(clk), .rst_n(rst_n), .run(run), .done(d4), .e_pt(p4),
        .e_al(a4), .nchk(n4));
    pt_h #(.NPHYS(16), .SEED(7)) h16 (.clk(clk), .rst_n(rst_n), .run(run), .done(d16), .e_pt(p16),
        .e_al(a16), .nchk(n16));
    pt_h #(.NPHYS(32), .SEED(9)) h32 (.clk(clk), .rst_n(rst_n), .run(run), .done(d32), .e_pt(p32),
        .e_al(a32), .nchk(n32));
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        run = 1;
        wait (d8 && d4 && d16 && d32);
        if (p8 == 0 && p4 == 0 && p16 == 0 && p32 == 0) $display("PASS ad_su_pt.pt");
        else $display("FAIL ad_su_pt.pt (%0d %0d %0d %0d)", p8, p4, p16, p32);
        if (a8 == 0 && a4 == 0 && a16 == 0 && a32 == 0 && n8 > 5000) $display("PASS ad_su_pt.alloc");
        else $display("FAIL ad_su_pt.alloc (%0d %0d %0d %0d)", a8, a4, a16, a32);
        if (p8 == 0 && p4 == 0 && p16 == 0 && p32 == 0 && a8 == 0 && a4 == 0 && a16 == 0 && a32 == 0)
            $display("PASS ad_su_pt");
        $finish;
    end
endmodule
