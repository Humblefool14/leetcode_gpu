// ad_rop_occ_tb -- random increments / clears / ROP_CTRL writes against an in-TB model.
`timescale 1ns/1ps
`include "ad_rop_state.vh"
module ad_rop_occ_tb;
    reg clk = 0, rst_n = 0;
    reg st_we = 0; reg [8:0] st_idx = 0; reg [31:0] st_wdata = 0;
    reg inc_valid = 0; reg [4:0] inc_n = 0; reg clear = 0;
    wire [39:0] count;
    ad_rop_occ dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
                    .inc_valid(inc_valid), .inc_n(inc_n), .clear(clear), .count(count));
    always #5 clk = ~clk;
    reg [39:0] m_count; reg m_en;
    integer i, err = 0, seed = 7, n_both = 0, n_clr = 0, n_inc_off = 0;
    initial begin
        m_count = 0; m_en = 0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1;
        for (i = 0; i < 20000; i = i + 1) begin
            // drive (after the edge)
            st_we    = ($random(seed) % 50) == 0;
            st_idx   = (($random(seed) & 3) == 0) ? 9'h08C : `AD_S_ROP_CTRL;
            st_wdata = $random(seed);
            inc_valid = $random(seed);
            inc_n    = $unsigned($random(seed)) % 17;
            clear    = ($random(seed) % 20) == 0;
            if (i == 100) begin st_we = 1; st_idx = `AD_S_ROP_CTRL; st_wdata = 1; end
            if (i == 101) begin clear = 1; inc_valid = 1; inc_n = 9; end
            if (clear && inc_valid && m_en) n_both = n_both + 1;
            if (clear) n_clr = n_clr + 1;
            if (inc_valid && !m_en && inc_n != 0) n_inc_off = n_inc_off + 1;
            @(posedge clk);
            m_count = (clear ? 40'd0 : m_count) + ((inc_valid && m_en) ? inc_n : 0);
            if (st_we && st_idx == `AD_S_ROP_CTRL) m_en = st_wdata[0];
            #1;
            if (count !== m_count) begin
                err = err + 1;
                if (err < 5) $display("FAIL ad_rop_occ.count cycle %0d got %0d exp %0d", i, count, m_count);
            end
        end
        // reset clears
        rst_n = 0; @(posedge clk); #1;
        if (count !== 0) begin err = err + 1; $display("FAIL ad_rop_occ.count reset"); end
        if (n_both == 0 || n_clr == 0 || n_inc_off == 0) begin err = err + 1; $display("FAIL ad_rop_occ.count coverage"); end
        if (err == 0) $display("PASS ad_rop_occ.count");
        if (err == 0) $display("PASS ad_rop_occ");
        $finish;
    end
endmodule
