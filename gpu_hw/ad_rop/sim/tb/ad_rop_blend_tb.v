// ad_rop_blend_tb -- see spec/gpu/rop/ad_rop_blend.md §8; vectors from tools/gen_blend_vectors.py
`timescale 1ns/1ps
module ad_rop_blend_tb;
`include "sim/tb/ad_rop_blend_tb.vh"
    initial begin
        total_err = 0; total_beats = 0;
        run_file("sim/vec/blend_formats.hex", "ad_rop_blend.formats");
        run_file("sim/vec/blend_factors.hex", "ad_rop_blend.factors");
        run_file("sim/vec/blend_r8rg8.hex", "ad_rop_blend.r8rg8");
        run_file("sim/vec/blend_const.hex", "ad_rop_blend.const");
        if (total_err == 0) $display("PASS ad_rop_blend");
        else $display("FAIL ad_rop_blend (%0d errors, %0d beats)", total_err, total_beats);
        $finish;
    end
endmodule
