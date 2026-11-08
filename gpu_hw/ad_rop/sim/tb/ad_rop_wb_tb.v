// ad_rop_wb_tb -- ad_rop_wb + ad_rop_wpix + blend (TB model, or -DAD_REAL_BLEND) + ad_rop_fblend
// (see the .f) + ad_amb_mem, LINE_BYTES 32 and 64, against tools/wb_model.py
// (sim/vec/wb_cmd_<LB>.hex / wb_exp_<LB>.hex from tools/gen_wb_vectors.py).  After each run
// the buffer drains and the whole memory (the four render targets' regions) is compared
// byte for byte with the model.
//   write : RGBA8 (RT_FORMATS and legacy RT_FORMAT codes), R32_UINT, R32G32B32A32_UINT
//           (one and several lines a row) and random path-2 formats with write masks
//   blend : read-modify-write: BLEND ONE/ONE/ADD on 8-bit formats, partial write masks on
//           paths 0, 1 (A2B10G10R10_UNORM via ad_rop_fblend) and 2
//   drain : long runs with idle gaps (flushes in the middle); busy only falls when every
//           request is answered, never before 16 idle cycles, requests held until taken
`timescale 1ns/1ps
`include "sim/tb/ad_rop_wb_tb.vh"

module ad_rop_wb_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    ad_rop_wb_bench #(.LINE_BYTES(32), .LINE_SHIFT(5), .CMDF("sim/vec/wb_cmd_32.hex"),
                      .EXPF("sim/vec/wb_exp_32.hex"), .SEED(3)) b32 (.clk(clk));
    ad_rop_wb_bench #(.LINE_BYTES(64), .LINE_SHIFT(6), .CMDF("sim/vec/wb_cmd_64.hex"),
                      .EXPF("sim/vec/wb_exp_64.hex"), .SEED(5)) b64 (.clk(clk));
    integer ew, eb, ed;
    initial begin
        wait (b32.done && b64.done);
        ew = b32.err_sec[0] + b64.err_sec[0];
        eb = b32.err_sec[1] + b64.err_sec[1];
        ed = b32.err_sec[2] + b64.err_sec[2] + b32.err_drain + b64.err_drain;
        if (b32.n_runs < 10 || b64.n_runs < 10 || b32.n_bv == 0 || b32.n_rd == 0) begin
            ed = ed + 1; $display("FAIL ad_rop_wb coverage");
        end
        if (ew == 0) $display("PASS ad_rop_wb.write");
        if (eb == 0) $display("PASS ad_rop_wb.blend");
        if (ed == 0) $display("PASS ad_rop_wb.drain");
        if (ew + eb + ed == 0) $display("PASS ad_rop_wb");
        $finish;
    end
    initial begin #200000000; $display("FAIL ad_rop_wb timeout"); $finish; end
endmodule
