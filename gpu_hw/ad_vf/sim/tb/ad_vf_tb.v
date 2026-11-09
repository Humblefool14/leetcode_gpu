// ad_vf_tb: whole-VF test.  Plays sim/vec/vf_<scene>_cmd.hex (STATE writes and DRAWs) into ad_vf
// with a behavioural AMB memory (sim/common/ad_amb_mem.v, random ready and latency), an SU slot
// model (grants after a random delay; warp w gets PT base 32 * (w % 8)) and an RX with random
// prim_ready, and checks against tools/gen_vf_sys.py (index -> asm_model -> fetch_model -> fmtmodel):
//   every vl_* register write in order (warp, reg, lane, data), vl_mask at each vl_go (after all of
//   the warp's writes), every primitive (PT entries, kind, free, last), no memory write, busy low at
//   the end of each draw.  Runtime argument +scene=<name>.
`timescale 1ns/1ps
module ad_vf_tb;
    parameter LINE_BYTES = 32;
    parameter LINE_SHIFT = 5;
    parameter SEED       = 7;
    localparam ADDR_W = 32, LW = ADDR_W - LINE_SHIFT;
    localparam NV = 16384, NP = 4096, NW = 1024, NC = 4096;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         st_we = 0, draw_kick = 0;
    reg  [8:0]  st_idx = 0;
    reg  [31:0] st_wdata = 0;
    wire        busy;
    wire        vl_req, vl_go, vl_we;
    reg         vl_gnt = 0;
    reg  [7:0]  vl_ptbase = 0;
    wire [31:0] vl_mask, vl_data;
    wire [5:0]  vl_reg;
    wire [4:0]  vl_lane;
    wire        prim_valid, prim_last;
    reg         prim_ready = 0;
    wire [25:0] prim_vtx;
    wire [2:0]  prim_free;
    wire        req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
    wire [LW-1:0] req_line;
    wire [LINE_BYTES-1:0] req_be;
    wire [LINE_BYTES*8-1:0] req_wdata, rsp_rdata;
    wire [7:0]  req_tag, rsp_tag;

    ad_vf #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .draw_kick(draw_kick), .busy(busy),
        .vl_req(vl_req), .vl_gnt(vl_gnt), .vl_ptbase(vl_ptbase), .vl_go(vl_go), .vl_mask(vl_mask),
        .vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane), .vl_data(vl_data),
        .prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
        .prim_free(prim_free), .prim_last(prim_last),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error));

    ad_amb_mem #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .ADDR_W(ADDR_W),
                 .MEM_LINES(65536 / LINE_BYTES), .LAT_MIN(1), .LAT_MAX(14), .READY_PCT(60), .SEED(SEED)) u_mem (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error));

    // expected streams
    reg [43:0] cmd  [0:NC-1];
    reg [58:0] evl  [0:NV-1];
    reg [31:0] ewarp[0:NW-1];
    reg [37:0] eprim[0:NP-1];
    integer nvl, nwarp, nprim, vp, pp, wp, gw, errors, cyc, seed;
    reg checks_on = 1, force_gw0 = 0;
    string scene, fn;

    task fail(input [8*120-1:0] msg); begin
        errors = errors + 1;
        if (errors <= 12) $display("FAIL ad_vf.%0s: %0s (cycle %0d)", scene, msg, cyc);
    end endtask

    // count lines of a hex file loaded with $readmemh: entries default to x
    function integer count_x59(input integer n); integer i; begin
        count_x59 = 0; for (i = 0; i < n; i = i + 1) if (^evl[i] !== 1'bx) count_x59 = i + 1; end endfunction

    // ---------------- SU slot model ----------------
    reg       granted;          // a warp is granted and has not yet had vl_go
    integer   gdelay;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        vl_gnt <= 1'b0;
        if (!rst_n || force_gw0) begin granted <= 0; gdelay <= 0; gw <= 0; end
        else begin
            if (vl_req && !granted && !vl_gnt) begin
                if (gdelay == 0) begin
                    vl_gnt <= 1'b1; vl_ptbase <= 8'd32 * (gw % 8); granted <= 1'b1;
                    gdelay <= $urandom(seed) % 6;
                end else gdelay <= gdelay - 1;
            end
            if (vl_go) begin
                if (checks_on) begin
                if (!granted) fail("vl_go without a granted warp");
                if (gw >= nwarp) fail("more warps than expected");
                else if (vl_mask !== ewarp[gw]) begin
                    fail("vl_mask");
                    $display("  warp %0d: vl_mask %h expected %h", gw, vl_mask, ewarp[gw]);
                end
                if (vp < nvl && evl[vp][58:43] == gw) fail("vl_go before all of the warp's register writes");
                end
                granted <= 1'b0; gw <= gw + 1;
            end
        end
    end

    // ---------------- register writes ----------------
    always @(posedge clk) if (rst_n && vl_we && checks_on) begin
        if (vp >= nvl) fail("extra vl write");
        else begin
            if (!granted || evl[vp][58:43] !== gw || evl[vp][42:37] !== vl_reg || evl[vp][36:32] !== vl_lane
                || evl[vp][31:0] !== vl_data) begin
                fail("vl write");
                $display("  #%0d: got warp %0d reg %0d lane %0d data %h, expected warp %0d reg %0d lane %0d data %h",
                         vp, gw, vl_reg, vl_lane, vl_data, evl[vp][58:43], evl[vp][42:37], evl[vp][36:32], evl[vp][31:0]);
            end
            vp = vp + 1;
        end
    end

    // ---------------- RX ----------------
    reg [7:0] pb0, pb1, pb2;
    always @(posedge clk) begin
        prim_ready <= ($urandom(seed) % 100) < 75;
        if (rst_n && prim_valid && prim_ready && checks_on) begin
            if (pp >= nprim) fail("extra primitive");
            else begin
                pb0 = 8'd32 * (eprim[pp][15:0] % 8) + eprim[pp][20:16];
                pb1 = 8'd32 * (eprim[pp][15:0] % 8) + eprim[pp][25:21];
                pb2 = 8'd32 * (eprim[pp][15:0] % 8) + eprim[pp][30:26];
                if (prim_vtx !== {eprim[pp][33:32], pb2, pb1, pb0} || prim_free !== eprim[pp][36:34]
                    || prim_last !== eprim[pp][37]) begin
                    fail("primitive");
                    $display("  #%0d: got vtx %h free %b last %b, expected vtx %h free %b last %b", pp,
                             prim_vtx, prim_free, prim_last, {eprim[pp][33:32], pb2, pb1, pb0},
                             eprim[pp][36:34], eprim[pp][37]);
                end
                if (eprim[pp][15:0] >= gw)
                    fail("primitive of a warp before its vl_go");
            end
            pp = pp + 1;
        end
    end

    always @(posedge clk) if (rst_n && req_valid && req_write) fail("the VF wrote memory");

    integer ci, i, t0;
    initial begin
        errors = 0; vp = 0; pp = 0; cyc = 0; seed = SEED;
        if (!$value$plusargs("scene=%s", scene)) scene = "tri_list";
        for (i = 0; i < NV; i = i + 1) evl[i] = 59'bx;
        for (i = 0; i < NP; i = i + 1) eprim[i] = 38'bx;
        for (i = 0; i < NW; i = i + 1) ewarp[i] = 32'bx;
        fn = $sformatf("sim/vec/vf_%0s_img.hex", scene);   $readmemh(fn, u_mem.mem);
        fn = $sformatf("sim/vec/vf_%0s_cmd.hex", scene);   $readmemh(fn, cmd);
        fn = $sformatf("sim/vec/vf_%0s_vl.hex", scene);    $readmemh(fn, evl);
        fn = $sformatf("sim/vec/vf_%0s_warp.hex", scene);  $readmemh(fn, ewarp);
        fn = $sformatf("sim/vec/vf_%0s_prim.hex", scene);  $readmemh(fn, eprim);
        nvl = count_x59(NV);
        nwarp = 0; for (i = 0; i < NW; i = i + 1) if (^ewarp[i] !== 1'bx) nwarp = i + 1;
        nprim = 0; for (i = 0; i < NP; i = i + 1) if (^eprim[i] !== 1'bx) nprim = i + 1;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        for (ci = 0; ci < NC && cmd[ci][43:41] != 0; ci = ci + 1) begin
            @(negedge clk);
            if (cmd[ci][43:41] == 1) begin
                st_we = 1; st_idx = cmd[ci][40:32]; st_wdata = cmd[ci][31:0];
                @(negedge clk); st_we = 0;
            end else if (cmd[ci][43:41] == 2) begin
                draw_kick = 1; @(negedge clk); draw_kick = 0;
                // op 3: STATE writes the CP sends while this draw runs
                while (cmd[ci + 1][43:41] == 3) begin
                    ci = ci + 1;
                    repeat ($urandom(seed) % 6) @(negedge clk);
                    st_we = 1; st_idx = cmd[ci][40:32]; st_wdata = cmd[ci][31:0];
                    @(negedge clk); st_we = 0;
                    if (!busy) fail("op 3 write was not sent during the draw");
                end
                repeat (3) @(negedge clk);
                t0 = cyc;
                while (busy && cyc - t0 < 400000) @(negedge clk);
                if (busy) fail("draw did not finish (busy stuck)");
                repeat (8) @(negedge clk);
                if (busy) fail("busy rose again after the draw");
            end else if (cmd[ci][43:41] == 5) begin
                // a faulting draw: only busy and the memory port are checked, then the VF is reset
                checks_on = 0;
                draw_kick = 1; @(negedge clk); draw_kick = 0;
                repeat (3) @(negedge clk);
                t0 = cyc;
                while (busy && cyc - t0 < 400000) @(negedge clk);
                if (busy) fail("fault: busy stuck after an index rsp_error");
                if (u_mem.head != u_mem.tail) fail("fault: busy fell with reads still in flight");
                repeat (5) @(negedge clk);
                rst_n = 0; repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
                vp = 0; pp = 0; force_gw0 = 1; @(negedge clk); force_gw0 = 0;
                checks_on = 1;
                if (errors == 0) $display("PASS ad_vf.%0s.fault (busy fell %0d cycles after the kick, no read in flight)", scene, cyc - t0);
            end
        end
        repeat (20) @(negedge clk);
        if (vp != nvl)  begin fail("missing vl writes");  $display("  got %0d of %0d", vp, nvl); end
        if (gw != nwarp) begin fail("warp count");       $display("  got %0d of %0d", gw, nwarp); end
        if (pp != nprim) begin fail("missing primitives"); $display("  got %0d of %0d", pp, nprim); end
        if (errors == 0) begin
            $display("PASS ad_vf.%0s (line %0d: %0d register words, %0d warps, %0d primitives, %0d cycles)",
                     scene, LINE_BYTES, nvl, nwarp, nprim, cyc);
            $display("PASS ad_vf");
        end else $display("FAIL ad_vf: %0d errors", errors);
        $finish;
    end
    initial begin #200000000; $display("FAIL ad_vf: timeout"); $finish; end
endmodule
