// fv_ad_vf_idx_walk -- the two-level walk (reduced to W = 4 bits) against a flat step counter:
// after s steps of a walk loaded with (cn, ci), n = s mod cn and i = s div cn; last exactly at
// s = cn*ci - 1; active for exactly cn*ci steps; nothing moves without step.
module fv_ad_vf_idx_walk (
    input wire       clk,
    input wire       rst_n,
    input wire       load,
    input wire [3:0] cnt_n,
    input wire [3:0] cnt_i,
    input wire       step
);
    localparam W = 4;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) if (init) assume (!rst_n);
    always @(*) if (load) assume (cnt_n != 0 && cnt_i != 0);
    wire [W-1:0] n, i; wire active, last_n, last;
    ad_vf_idx_walk #(.W(W)) dut (.clk(clk), .rst_n(rst_n), .load(load), .cnt_n(cnt_n), .cnt_i(cnt_i), .step(step),
        .n(n), .i(i), .active(active), .last_n(last_n), .last(last));
    reg [W-1:0] cn, ci, rn, ri; reg [2*W-1:0] s; reg ract;
    always @(posedge clk) begin
        if (!rst_n) begin ract <= 1'b0; s <= 0; rn <= 0; ri <= 0; cn <= 1; ci <= 1; end
        else if (load) begin ract <= 1'b1; s <= 0; rn <= 0; ri <= 0; cn <= cnt_n; ci <= cnt_i; end
        else if (step && ract) begin
            s <= s + 1'b1;
            if (rn + 1'b1 == cn) begin rn <= 0; ri <= ri + 1'b1; end else rn <= rn + 1'b1;
            if (s + 1'b1 == cn * ci) ract <= 1'b0;
        end
    end
    always @(*) if (!init && rst_n) begin
        a_act: assert (active == ract);
        if (ract) begin
            a_n: assert (n == rn);
            a_i: assert (i == ri);
            a_s: assert (s == {{W{1'b0}}, ri} * cn + rn);
            a_lastn: assert (last_n == (rn + 1'b1 == cn));
            a_last:  assert (last == (s + 1'b1 == cn * ci));
            a_rng:   assert (rn < cn && ri < ci);
        end
    end
endmodule
