// fv_ad_ctl_fq -- the two-entry in-flight queue: entries leave in push order
// with the data of the fills in fill order (tagged token: a free input picks
// one push; the harness counts the entries ahead of it and the fills that
// belong to it), never more than two entries, room exact.
module fv_ad_ctl_fq (input wire clk, input wire push, input wire [3:0] push_tag, input wire fill,
                     input wire [3:0] fill_data, input wire out_ready, input wire pick);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire room, ov; wire [3:0] ot, od;
    ad_ctl_fq #(.TW(4), .DW(4)) dut (.clk(clk), .rst_n(rst_n), .push(push), .push_tag(push_tag), .room(room),
        .fill(fill), .fill_data(fill_data), .out_valid(ov), .out_ready(out_ready), .out_tag(ot), .out_data(od));
    reg [1:0] n, nf;          // entries, entries with data
    reg armed, got; reg [1:0] ahead, fahead; reg [3:0] tt, td;
    wire pop = ov && out_ready;
    always @(*) if (rst_n) begin
        assume (!push || room);
        assume (!fill || nf < n);        // a fill only for an entry waiting for data
    end else assume (!push && !fill);
    always @(posedge clk) begin
        if (!rst_n) begin n <= 0; nf <= 0; armed <= 0; got <= 0; end
        else begin
            n <= n + push - pop; nf <= nf + fill - pop;
            if (armed && pop) begin if (ahead == 0) armed <= 1'b0; else ahead <= ahead - 1'b1; end
            if (armed && !got && fill) begin
                if (fahead == 0) begin got <= 1'b1; td <= fill_data; end else fahead <= fahead - 1'b1;
            end
            if (push && pick && !armed) begin
                armed <= 1'b1; got <= 1'b0; tt <= push_tag; ahead <= n - pop; fahead <= n - nf - (fill ? 1 : 0);
            end
        end
    end
    always @(*) if (rst_n) begin
        a_n: assert (n <= 2 && nf <= n);
        a_room: assert (room == (n < 2 || pop));
        a_ov: assert (ov == (nf != 0));
        if (armed && pop && ahead == 0) begin
            a_tag: assert (ot == tt);
            a_dat: assert (got && od == td);
        end
    end
endmodule
