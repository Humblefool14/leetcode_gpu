// ad_rop_dualsrc_tb -- see spec/gpu/rop/ad_rop_blend.md §8; vectors from tools/gen_blend_vectors.py
`timescale 1ns/1ps
module ad_rop_dualsrc_tb;
`include "sim/tb/ad_rop_blend_tb.vh"
    initial begin
        total_err = 0; total_beats = 0;
        run_file("sim/vec/blend_ds_factors.hex", "ad_rop_dualsrc.factors");
        run_file("sim/vec/blend_ds_font.hex", "ad_rop_dualsrc.subpixel_font");
        run_file("sim/vec/blend_ds_masks.hex", "ad_rop_dualsrc.masks");
        run_file("sim/vec/blend_ds_formats.hex", "ad_rop_dualsrc.formats");
        if (total_err == 0) $display("PASS ad_rop_dualsrc");
        else $display("FAIL ad_rop_dualsrc (%0d errors, %0d beats)", total_err, total_beats);
        $finish;
    end
endmodule
