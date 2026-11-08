// ad_rop_order_tb -- ad_rop_order with random interleavings: primitives issued
// in order (ord_*), SU quads and direct quads offered from any pending
// primitive (the head only part of the time, numbers not yet issued too),
// mask-0 quads, random o_ready.  Scoreboard: the output stream equals the
// issue order of the primitives, each primitive's quads contiguous and in
// arrival order, mask-0 quads absent, nothing lost or duplicated.
`timescale 1ns/1ps
module ad_rop_order_tb;
    localparam NPRIM = 400, MAXQ = 5, NQ = NPRIM * MAXQ;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg          ex_valid = 0; wire ex_ready; reg [15:0] ex_seq = 0; reg [31:0] ex_xy = 0;
    reg  [3:0]   ex_mask = 0; reg [511:0] ex_color = 0; reg [127:0] ex_depth = 0; reg ex_last = 0;
    reg  [153:0] ex_aux = 0; wire [15:0] ex_next;
    reg          dx_valid = 0; wire dx_ready; reg [15:0] dx_seq = 0; reg [31:0] dx_xy = 0;
    reg  [3:0]   dx_mask = 0; reg [127:0] dx_depth = 0; reg dx_last = 0;
    reg          ord_valid = 0; reg [15:0] ord_seq = 0;
    wire         o_valid; reg o_ready = 0;
    wire [31:0]  o_xy; wire [3:0] o_mask; wire [511:0] o_color; wire [127:0] o_depth;
    wire         o_dbg, busy, ovf; wire [153:0] o_aux;

    ad_rop_order dut (.clk(clk), .rst_n(rst_n),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy), .ex_mask(ex_mask),
        .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last), .ex_aux(ex_aux), .ex_next(ex_next),
        .dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy), .dx_mask(dx_mask),
        .dx_depth(dx_depth), .dx_last(dx_last), .ord_valid(ord_valid), .ord_seq(ord_seq),
        .o_valid(o_valid), .o_ready(o_ready), .o_xy(o_xy), .o_mask(o_mask), .o_color(o_color),
        .o_depth(o_depth), .o_dbg(o_dbg), .o_aux(o_aux), .busy(busy), .ovf(ovf));

    localparam [153:0] DX_AUX = {2'd0, 1'b1, 1'b1, 1'b0, 1'b1, 128'd0, 4'd0, 16'h1111};

    // ---------------- stimulus tables ----------------
    reg [15:0]  seq   [0:NPRIM-1];
    reg         isdx  [0:NPRIM-1];
    integer     nq    [0:NPRIM-1];
    integer     qbase [0:NPRIM-1];
    integer     qp    [0:NPRIM-1];        // next quad to offer
    reg [31:0]  q_xy    [0:NQ-1];
    reg [3:0]   q_mask  [0:NQ-1];
    reg [511:0] q_color [0:NQ-1];
    reg [127:0] q_depth [0:NQ-1];
    reg [153:0] q_aux   [0:NQ-1];
    integer     xq [0:NQ-1];              // expected output order: quad ids
    integer     xprim [0:NQ-1];
    integer i, j, k, nx, seed, npushed, npopped, eo, err, derr, nd, held, cand, ex_p, dx_p, tries, cyc, wrongacc;
    reg [15:0] s;

    initial begin
        seed = 20261108;
        s = 16'hFFE0;                      // wraps through 0
        k = 0; nx = 0;
        for (i = 0; i < NPRIM; i = i + 1) begin
            s = s + 1 + ($random(seed) & 3);
            seq[i] = s;
            isdx[i] = (($random(seed) & 7) < 3);
            nq[i] = 1 + ({$random(seed)} % MAXQ);
            qbase[i] = k; qp[i] = 0;
            for (j = 0; j < nq[i]; j = j + 1) begin
                q_xy[k] = $random(seed);
                q_mask[k] = (($random(seed) & 7) == 0) ? 4'd0 : $random(seed);
                q_color[k] = {16{$random(seed)}} ^ {$random(seed), $random(seed), 448'd0};
                q_color[k][31:0] = k;
                q_depth[k] = {$random(seed), $random(seed), $random(seed), $random(seed)};
                q_aux[k] = {$random(seed), $random(seed), $random(seed), $random(seed), $random(seed)};
                if (q_mask[k] != 0) begin xq[nx] = k; xprim[nx] = i; nx = nx + 1; end
                k = k + 1;
            end
        end
    end

    // ---------------- monitor (pre-edge values) ----------------
    reg [511:0] e_color; reg [153:0] e_aux; reg e_dbg; integer qid;
    initial begin npushed = 0; npopped = 0; eo = 0; err = 0; derr = 0; nd = 0; held = 0; cyc = 0; wrongacc = 0; end
    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        if (ord_valid) npushed = npushed + 1;
        if (ex_valid && ex_ready) begin
            if (ex_p != npopped) wrongacc = wrongacc + 1;
            qp[ex_p] = qp[ex_p] + 1;
            if (ex_last) npopped = npopped + 1;
        end
        if (dx_valid && dx_ready) begin
            if (dx_p != npopped) wrongacc = wrongacc + 1;
            qp[dx_p] = qp[dx_p] + 1;
            if (dx_last) npopped = npopped + 1;
        end
        if (ex_valid && !ex_ready && ex_p != npopped) held = held + 1;
        if (dx_valid && !dx_ready && dx_p != npopped) held = held + 1;
        if (o_valid && o_ready) begin
            if (eo >= nx) begin
                $display("FAIL ad_rop_order: extra output"); err = err + 1;
            end else begin
                qid = xq[eo];
                e_dbg = isdx[xprim[eo]];
                e_color = e_dbg ? 512'd0 : q_color[qid];
                e_aux = e_dbg ? DX_AUX : q_aux[qid];
                if (e_dbg) nd = nd + 1;
                if (o_xy !== q_xy[qid] || o_mask !== q_mask[qid] || o_color !== e_color ||
                    o_depth !== q_depth[qid] || o_dbg !== e_dbg || o_aux !== e_aux) begin
                    if (err < 8) $display("FAIL ad_rop_order: output %0d (prim %0d quad %0d dbg %b): got xy %h mask %h dbg %b tag %0d",
                                          eo, xprim[eo], qid, e_dbg, o_xy, o_mask, o_dbg, o_color[31:0]);
                    err = err + 1;
                    if (e_dbg) derr = derr + 1;
                end
            end
            eo = eo + 1;
        end
    end

    // ---------------- driver (negedge) ----------------
    task pick(input dxside, output integer p);
        integer t, lim;
        begin
            p = -1;
            lim = npushed + 2; if (lim > NPRIM) lim = NPRIM;
            // the head primitive, part of the time
            if (npopped < NPRIM && isdx[npopped] == dxside && qp[npopped] < nq[npopped] && ($random(seed) & 1))
                p = npopped;
            for (t = 0; t < 6 && p < 0; t = t + 1) begin
                cand = npopped + ({$random(seed)} % 6);
                if (cand < lim && isdx[cand] == dxside && qp[cand] < nq[cand]) p = cand;
            end
        end
    endtask

    always @(negedge clk) if (rst_n) begin
        o_ready = (($random(seed) & 3) != 0);
        ord_valid = (npushed < NPRIM) && (npushed - npopped < 16) && (($random(seed) & 3) != 0);
        ord_seq = ord_valid ? seq[npushed] : 16'hxxxx;
        pick(1'b0, ex_p);
        ex_valid = (ex_p >= 0) && (($random(seed) & 7) != 0);
        if (ex_valid) begin
            qid = qbase[ex_p] + qp[ex_p];
            ex_seq = seq[ex_p]; ex_xy = q_xy[qid]; ex_mask = q_mask[qid]; ex_color = q_color[qid];
            ex_depth = q_depth[qid]; ex_aux = q_aux[qid]; ex_last = (qp[ex_p] == nq[ex_p] - 1);
        end else begin
            ex_seq = $random(seed); ex_last = $random(seed); ex_mask = $random(seed);
        end
        pick(1'b1, dx_p);
        dx_valid = (dx_p >= 0) && (($random(seed) & 7) != 0);
        if (dx_valid) begin
            qid = qbase[dx_p] + qp[dx_p];
            dx_seq = seq[dx_p]; dx_xy = q_xy[qid]; dx_mask = q_mask[qid];
            dx_depth = q_depth[qid]; dx_last = (qp[dx_p] == nq[dx_p] - 1);
        end else begin
            dx_seq = $random(seed); dx_last = $random(seed);
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1;
        tries = 0;
        while (!(npopped == NPRIM && !busy) && tries < 200000) begin @(posedge clk); tries = tries + 1; end
        repeat (5) @(posedge clk);
        if (tries >= 200000) begin $display("FAIL ad_rop_order: timeout (%0d of %0d retired)", npopped, NPRIM); err = err + 1; end
        if (eo != nx) begin $display("FAIL ad_rop_order: %0d outputs, %0d expected", eo, nx); err = err + 1; end
        if (ovf) begin $display("FAIL ad_rop_order: overflow flag"); err = err + 1; end
        if (wrongacc) begin $display("FAIL ad_rop_order: %0d quads taken out of order", wrongacc); err = err + 1; end
        if (err == 0 && held > 0)
            $display("PASS ad_rop_order.inorder (%0d primitives, %0d quads out, %0d out-of-turn offers held back, %0d cycles)",
                     NPRIM, eo, held, cyc);
        else $display("FAIL ad_rop_order.inorder (%0d errors)", err);
        if (err == 0 && derr == 0 && nd > 0) $display("PASS ad_rop_order.direct (%0d direct quads)", nd);
        else $display("FAIL ad_rop_order.direct (%0d errors)", derr);
        if (err == 0 && held > 0 && nd > 0) $display("PASS ad_rop_order");
        else $display("FAIL ad_rop_order");
        $finish;
    end
endmodule
