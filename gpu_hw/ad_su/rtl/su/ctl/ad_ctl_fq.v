// ad_ctl_fq -- two-entry in-flight queue with late data (ad_su_fetch).
// push: an entry {tag} enters (request accepted).  fill: data for the oldest
// entry that has none (responses come in push order).  The head leaves when it
// has data and out_ready.  room = an entry is free, or the head leaves this
// cycle.  A fill with no entry waiting is a protocol error (ignored).
module ad_ctl_fq #(
    parameter TW = 18,
    parameter DW = 64
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          push,
    input  wire [TW-1:0] push_tag,
    output wire          room,
    input  wire          fill,
    input  wire [DW-1:0] fill_data,
    output wire          out_valid,
    input  wire          out_ready,
    output wire [TW-1:0] out_tag,
    output wire [DW-1:0] out_data
);
    reg [TW-1:0] tag0, tag1;          // entry 0 is the head
    reg [DW-1:0] dat0, dat1;
    reg          v0, v1, h0, h1;      // valid, has data

    wire pop = v0 && h0 && out_ready;
    assign out_valid = v0 && h0;
    assign out_tag   = tag0;
    assign out_data  = dat0;
    assign room      = !v1 || pop;

    // fill target before the pop: the oldest valid entry without data
    wire fill0 = fill && v0 && !h0;
`ifdef MUT_FQ_FILL
    wire fill1 = fill && v1 && !h1;                  // mutation: may skip the head
`else
    wire fill1 = fill && v1 && h0 && !h1;
`endif

    always @(posedge clk) begin
        if (!rst_n) begin
            v0 <= 1'b0; v1 <= 1'b0; h0 <= 1'b0; h1 <= 1'b0;
        end else if (pop) begin
            // entry 1 (after its fill) moves to the head; a push lands behind it
            v0   <= v1 || push;
            tag0 <= v1 ? tag1 : push_tag;
            h0   <= v1 ? (h1 || fill1) : 1'b0;
            dat0 <= fill1 ? fill_data : dat1;
            v1   <= v1 && push;
            tag1 <= push_tag;
            h1   <= 1'b0;
        end else begin
            if (fill0) begin h0 <= 1'b1; dat0 <= fill_data; end
            if (fill1) begin h1 <= 1'b1; dat1 <= fill_data; end
            if (push && !v0) begin v0 <= 1'b1; tag0 <= push_tag; h0 <= 1'b0; end
            else if (push) begin v1 <= 1'b1; tag1 <= push_tag; h1 <= 1'b0; end
        end
    end
endmodule
