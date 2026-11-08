`timescale 1ns/1ps
// ad_rop_raw_tb -- review regression: with a memory whose reads can overtake writes,
// a draw that blends on a line just flushed by wb must see the flushed data.
module ad_rop_raw_tb;
    localparam LB = 32, LS = 5, MEMB = 32*1024;
    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0; wire busy;
    reg ex_valid = 0; wire ex_ready; reg [15:0] ex_seq = 0; reg [31:0] ex_xy = 0;
    reg [3:0] ex_mask = 0; reg [511:0] ex_color = 0; reg [127:0] ex_depth = 0; reg ex_last = 0;
    reg [153:0] ex_aux = 0; wire [15:0] ex_next;
    reg ord_valid = 0; reg [15:0] ord_seq = 0; wire [39:0] occ_count;
    wire req_valid, req_ready, req_write, rsp_valid, rsp_write, rsp_error;
    wire [32-LS-1:0] req_line; wire [LB-1:0] req_be; wire [LB*8-1:0] req_wdata, rsp_rdata; wire [7:0] req_tag, rsp_tag;
    wire dx_ready;
    ad_rop #(.LINE_BYTES(LB), .LINE_SHIFT(LS), .STENCIL(1)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .busy(busy),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy), .ex_mask(ex_mask),
        .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last), .ex_aux(ex_aux), .ex_next(ex_next),
        .dx_valid(1'b0), .dx_ready(dx_ready), .dx_seq(16'd0), .dx_xy(32'd0), .dx_mask(4'd0), .dx_depth(128'd0), .dx_last(1'b0),
        .ord_valid(ord_valid), .ord_seq(ord_seq), .occ_count(occ_count), .occ_clear(1'b0),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
    ad_amb_mem_ooo #(.LINE_BYTES(LB), .LINE_SHIFT(LS), .MEM_LINES(MEMB/LB)) mem (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error));
    task stw(input [8:0] i, input [31:0] d); begin st_we <= 1; st_idx <= i; st_wdata <= d; @(posedge clk); st_we <= 0; end endtask
    task quad(input [15:0] seq, input [15:0] x, input [15:0] y); begin
        ord_valid <= 1; ord_seq <= seq; @(posedge clk); ord_valid <= 0;
        ex_valid <= 1; ex_seq <= seq; ex_xy <= {y, x}; ex_mask <= 4'hF; ex_last <= 1;
        ex_color <= {16{32'h3D80_8081}};
        ex_aux <= {2'd0, 1'b1, 1'b1, 1'b0, 1'b1, 128'd0, 4'd0, 16'h1111};
        @(posedge clk); while (!ex_ready) @(posedge clk); ex_valid <= 0; end endtask
    task wait_idle; integer k; begin k = 0; while (k < 40) begin @(posedge clk); if (busy) k = 0; else k = k + 1; end end endtask
    integer i;
    initial begin
        for (i = 0; i < MEMB; i = i + 1) mem.mem[i] = 8'hAA;
        for (i = 32'h1020; i < 32'h1040; i = i + 1) mem.mem[i] = 8'h11;
        for (i = 32'h1060; i < 32'h1080; i = i + 1) mem.mem[i] = 8'h11;
        repeat (4) @(posedge clk); rst_n <= 1; @(posedge clk);
        for (i = 0; i < MEMB; i = i + 1) mem.mem[i] = 8'h10;
        stw(9'h070, 32'h1000); stw(9'h071, 64); stw(9'h072, 1); stw(9'h07D, 37);
        stw(9'h076, 0); stw(9'h05E, 0); stw(9'h07C, 32'hF);
        // BLEND ADD, ONE/ONE colour and alpha; never changed afterwards
        stw(9'h07A, 32'h1 | (32'd1 << 1) | (32'd1 << 5) | (32'd1 << 12) | (32'd1 << 16));
        quad(0, 0, 0);                                     // 0x10 + 0x10 = 0x20
        @(posedge clk); while (!(dut.u_wb.st == 4'd8 && dut.u_wb.req_fire)) @(posedge clk);
        quad(1, 0, 0);                                     // same state, next draw: 0x20 + 0x10 = 0x30
        wait_idle;
        if ({mem.mem['h1000], mem.mem['h1001], mem.mem['h1002], mem.mem['h1003]} === 32'h30303030) begin
            $display("PASS ad_rop_raw.flush_then_blend"); $display("PASS ad_rop_raw");
        end else $display("FAIL ad_rop_raw.flush_then_blend (%h %h %h %h, expected 30)", mem.mem['h1000], mem.mem['h1001], mem.mem['h1002], mem.mem['h1003]);
        $finish;
    end
    initial begin #2_000_000; $display("FAIL ad_rop_raw (timeout)"); $finish; end
endmodule
