// ad_rop_logicop_tb -- see spec/gpu/rop/ad_rop_blend.md §8; vectors from tools/gen_blend_vectors.py
`timescale 1ns/1ps
module ad_rop_logicop_tb;
`include "sim/tb/ad_rop_blend_tb.vh"
    initial begin
        total_err = 0; total_beats = 0;
        run_file("sim/vec/blend_lop_all16.hex", "ad_rop_logicop.all16");
        run_file("sim/vec/blend_lop_masks.hex", "ad_rop_logicop.masks");
        run_file("sim/vec/blend_lop_indep.hex", "ad_rop_logicop.independent_blend");
        run_file("sim/vec/blend_lop_formats.hex", "ad_rop_logicop.formats");
        if (total_err == 0) $display("PASS ad_rop_logicop");
        else $display("FAIL ad_rop_logicop (%0d errors, %0d beats)", total_err, total_beats);
        $finish;
    end
endmodule
