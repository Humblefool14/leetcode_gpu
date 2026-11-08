// ad_rop_sys_tb -- the whole ad_rop (order, ms, ds, occ, wb+wpix+fblend, blend,
// amb_mux) against tools/gen_rop_sys_vectors.py, which composes the per-block
// Python models.  Four scenes: alpha blending with a D32F test; four colour
// attachments as beats (RGBA8 + R32_UINT + absent + R32G32B32A32_UINT, nocol
// beats); direct DEBUG_COLOR quads interleaved with SU quads; four samples with
// alpha to coverage, D24S8 and stencil.  The memory image and the occlusion count
// are compared at the end.  Run with -P ad_rop_sys_tb.LB=64 for 64-byte lines.
`timescale 1ns/1ps
module ad_rop_sys_tb;
    parameter LB = 32;
    localparam LS = (LB == 64) ? 6 : 5;
    localparam MEMB = 32 * 1024;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg          st_we = 0;  reg [8:0] st_idx = 0;  reg [31:0] st_wdata = 0;
    wire         busy;
    reg          ex_valid = 0; wire ex_ready; reg [15:0] ex_seq = 0; reg [31:0] ex_xy = 0;
    reg [3:0]    ex_mask = 0; reg [511:0] ex_color = 0; reg [127:0] ex_depth = 0; reg ex_last = 0;
    reg [153:0]  ex_aux = 0; wire [15:0] ex_next;
    reg          dx_valid = 0; wire dx_ready; reg [15:0] dx_seq = 0; reg [31:0] dx_xy = 0;
    reg [3:0]    dx_mask = 0; reg [127:0] dx_depth = 0; reg dx_last = 0;
    reg          ord_valid = 0; reg [15:0] ord_seq = 0;
    wire [39:0]  occ_count; reg occ_clear = 0;
    wire         req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
    wire [32-LS-1:0] req_line; wire [LB-1:0] req_be; wire [LB*8-1:0] req_wdata, rsp_rdata;
    wire [7:0]   req_tag, rsp_tag;

    ad_rop #(.ADDR_W(32), .LINE_BYTES(LB), .LINE_SHIFT(LS), .STENCIL(1)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .busy(busy),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy), .ex_mask(ex_mask),
        .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last), .ex_aux(ex_aux), .ex_next(ex_next),
        .dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy), .dx_mask(dx_mask),
        .dx_depth(dx_depth), .dx_last(dx_last), .ord_valid(ord_valid), .ord_seq(ord_seq),
        .occ_count(occ_count), .occ_clear(occ_clear),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error)
    );

`ifdef AD_OOO_MEM
    // reads may overtake writes (independent channels): checks read-after-write handling
    ad_amb_mem_ooo #(.LINE_BYTES(LB), .LINE_SHIFT(LS), .MEM_LINES(MEMB / LB), .WLAT(25), .RLAT(3)) mem (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error)
    );
`else
    ad_amb_mem #(.LINE_BYTES(LB), .LINE_SHIFT(LS), .MEM_LINES(MEMB / LB), .LAT_MIN(3), .LAT_MAX(20),
                 .READY_PCT(65), .SEED(11)) mem (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error)
    );
`endif

    reg [899:0] cmd [0:4095];
    reg [7:0]   expm [0:MEMB-1];
    reg [39:0]  exp_occ [0:0];
    integer     n, i, err, cyc, quads_in, scene;
    reg [899:0] c;
    reg [3:0]   t;

    always @(posedge clk) cyc <= cyc + 1;

    task wait_idle;
        integer k;
        begin
            k = 0;
            while (k < 40) begin
                @(posedge clk);
                if (busy) k = 0; else k = k + 1;
            end
        end
    endtask

    initial begin
        cyc = 0; err = 0; quads_in = 0; scene = 1;
        for (i = 0; i < 4096; i = i + 1) cmd[i] = {900{1'bx}};
        $readmemh("sim/vec/sys_cmd.hex", cmd);
        $readmemh("sim/vec/sys_init.hex", mem.mem);
        $readmemh("sim/vec/sys_exp.hex", expm);
        $readmemh("sim/vec/sys_occ.hex", exp_occ);
        repeat (4) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);
        n = 0;
        while (cmd[n] !== {900{1'bx}}) begin
            c = cmd[n];
            t = c[899:896];
            case (t)
                4'd1: begin                                 // STATE write
                    st_we <= 1; st_idx <= c[40:32]; st_wdata <= c[31:0];
                    @(posedge clk); st_we <= 0;
                end
                4'd2: begin                                 // issue a sequence number
                    ord_valid <= 1; ord_seq <= c[895:880];
                    @(posedge clk); ord_valid <= 0;
                end
                4'd3: begin                                 // SU beat
                    ex_valid <= 1; ex_seq <= c[895:880]; ex_xy <= c[879:848]; ex_mask <= c[847:844];
                    ex_last <= c[840]; ex_aux <= c[837:684]; ex_color <= c[683:172]; ex_depth <= c[171:44];
                    @(posedge clk);
                    while (!ex_ready) @(posedge clk);
                    ex_valid <= 0; quads_in = quads_in + 1;
                    if ($random % 4 == 0) @(posedge clk);
                end
                4'd4: begin                                 // direct quad
                    dx_valid <= 1; dx_seq <= c[895:880]; dx_xy <= c[879:848]; dx_mask <= c[847:844];
                    dx_last <= c[840]; dx_depth <= c[171:44];
                    @(posedge clk);
                    while (!dx_ready) @(posedge clk);
                    dx_valid <= 0; quads_in = quads_in + 1;
                end
                4'd5: begin                                 // ROP idle before the next scene's STATE
                    wait_idle;
                    $display("  scene %0d done at cycle %0d (%0d beats so far)", scene, cyc, quads_in);
                    scene = scene + 1;
                end
                4'd6: begin occ_clear <= 1; @(posedge clk); occ_clear <= 0; end
                default: ;
            endcase
            n = n + 1;
        end
        wait_idle;
        for (i = 0; i < MEMB; i = i + 1)
            if (mem.mem[i] !== expm[i]) begin
                if (err < 12) $display("mem[%05h] = %02h, expected %02h", i, mem.mem[i], expm[i]);
                err = err + 1;
            end
        if (err == 0) $display("PASS ad_rop_sys.memory (%0d bytes, %0d beats, %0d reads, %0d writes, LINE_BYTES %0d)",
                               MEMB, quads_in, mem.n_reads, mem.n_writes, LB);
        else $display("FAIL ad_rop_sys.memory (%0d bytes differ)", err);
        if (occ_count === exp_occ[0]) $display("PASS ad_rop_sys.occ (%0d samples)", occ_count);
        else begin $display("FAIL ad_rop_sys.occ (%0d, expected %0d)", occ_count, exp_occ[0]); err = err + 1; end
        if (err == 0) $display("PASS ad_rop_sys");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL ad_rop_sys (timeout, busy=%b, cmd %0d)", busy, n);
        $finish;
    end
endmodule
