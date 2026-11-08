// ad_rop_blend_tb.vh -- shared DUT + vector driver of ad_rop_blend_tb, ad_rop_logicop_tb and
// ad_rop_dualsrc_tb.  Vectors from tools/gen_blend_vectors.py (record layout documented there).
// One record per clock; checks every cycle that b_rvalid == b_valid of 3 cycles before and, on
// b_rvalid, b_pix word for word against the record's expected value.
    localparam LAT = 3;
    localparam MAXREC = 2500;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg          rst_n = 1'b0;
    reg          st_we = 1'b0;
    reg  [8:0]   st_idx = 9'd0;
    reg  [31:0]  st_wdata = 32'd0;
    reg          b_valid = 1'b0;
    reg  [511:0] b_src = 512'd0, b_src1 = 512'd0;
    reg          b_has_src1 = 1'b0;
    reg  [127:0] b_dst = 128'd0;
    reg  [3:0]   b_mask = 4'd0;
    reg  [1:0]   b_rt = 2'd0;
    wire         b_rvalid;
    wire [127:0] b_pix;

    ad_rop_blend #(.LAT(LAT)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .b_valid(b_valid), .b_src(b_src), .b_src1(b_src1), .b_has_src1(b_has_src1),
        .b_dst(b_dst), .b_mask(b_mask), .b_rt(b_rt), .b_rvalid(b_rvalid), .b_pix(b_pix));

    reg [1343:0] vec [0:MAXREC-1];
    reg [LAT-1:0] hv;                 // b_valid history (hv[LAT-1] = LAT cycles ago)
    reg [127:0]   he [0:LAT-1];       // expected b_pix history
    integer err, total_err, nbeat, total_beats, maxb2b, b2b;
    integer n, k;

    task drive_idle;
        begin
            st_we = 1'b0; b_valid = 1'b0; b_has_src1 = 1'b0; b_mask = 4'd0; b_rt = 2'd0;
        end
    endtask

    // check the outputs of the current cycle, then shift the history with what is driven now
    task check_and_shift(input v, input [127:0] e);
        begin
            if (b_rvalid !== hv[LAT-1]) begin
                if (err < 10) $display("  rvalid mismatch t=%0t got %b exp %b", $time, b_rvalid, hv[LAT-1]);
                err = err + 1;
            end else if (hv[LAT-1] && b_pix !== he[LAT-1]) begin
                if (err < 10) $display("  pix mismatch t=%0t\n    got %h\n    exp %h", $time, b_pix, he[LAT-1]);
                err = err + 1;
            end
            for (k = LAT - 1; k > 0; k = k - 1) he[k] = he[k-1];
            hv = {hv[LAT-2:0], v};
            he[0] = e;
        end
    endtask

    task run_file(input [8*64-1:0] fname, input [8*48-1:0] sname);
        reg [1343:0] r;
        begin
            for (n = 0; n < MAXREC; n = n + 1) vec[n] = {1344{1'b0}};
            vec[0][1343] = 1'b1;
            $readmemh(fname, vec);
            err = 0; nbeat = 0; b2b = 0; maxb2b = 0;
            // reset (also clears the STATE registers: each vector file starts from reset)
            @(negedge clk); rst_n = 1'b0; drive_idle;
            hv = {LAT{1'b0}};
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            n = 0;
            while (!vec[n][1343] && n < MAXREC) begin
                @(negedge clk);
                r = vec[n];
                check_and_shift(r[1328], r[127:0]);
                b_valid    = r[1328];
                b_has_src1 = r[1329];
                b_rt       = r[1331:1330];
                b_mask     = r[1335:1332];
                st_we      = r[1336];
                st_idx     = r[1320:1312];
                st_wdata   = r[1311:1280];
                b_dst      = r[1279:1152];
                b_src      = r[1151:640];
                b_src1     = r[639:128];
                if (r[1328]) begin nbeat = nbeat + 1; b2b = b2b + 1; if (b2b > maxb2b) maxb2b = b2b; end
                else b2b = 0;
                n = n + 1;
            end
            repeat (LAT + 2) begin
                @(negedge clk);
                check_and_shift(1'b0, 128'd0);
                drive_idle;
            end
            if (n == 0 || nbeat == 0) begin
                $display("FAIL %0s (no vectors in %0s)", sname, fname); err = err + 1;
            end else if (err == 0)
                $display("PASS %0s (%0d beats, %0d cycles, longest back-to-back run %0d)", sname, nbeat, n, maxb2b);
            else
                $display("FAIL %0s (%0d mismatches of %0d beats)", sname, err, nbeat);
            total_err = total_err + err;
            total_beats = total_beats + nbeat;
        end
    endtask
