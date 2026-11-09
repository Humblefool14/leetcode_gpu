// ad_vf_fetch_lbuf -- one attribute stream's line buffer of ad_vf_fetch (spec §4): 8 entries of
// {tag = line address, valid, pend, data}.  Streams are s = k[1:0]; ad_vf_fetch has four.
//
// Lookup (combinational): h0/he0 = a valid entry holds line l0 (and h1/he1 for l1).
// Allocation (a_en0 for l0, a_en1 for l1; the parent allocates only lines that miss, and only
//   while no entry is pending): entries are taken round-robin from ptr, skipping the entry that
//   hits for the other line of the same attribute, so an attribute crossing a line keeps both
//   of its entries.  An allocated entry gets the tag, pend = 1, valid = 0.
// Fill (w_en, w_ent): the response of a pending entry; data = w_err ? 0 : w_data (an error reads
//   as zero), valid = 1, pend = 0.  A response for an entry that is not pending is ignored.
// clr (warp end): every entry invalid, ptr = 0.
// Read (combinational): rd0/rv0 = data/valid of entry r_e0, rd1/rv1 of r_e1.
module ad_vf_fetch_lbuf #(
    parameter LW         = 27,          // line address width (ADDR_W - LINE_SHIFT)
    parameter LINE_BYTES = 32
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    clr,
    // lookup
    input  wire [LW-1:0]           l0,
    input  wire [LW-1:0]           l1,
    input  wire                    two,
    output wire                    h0,
    output reg  [2:0]              he0,
    output wire                    h1,
    output reg  [2:0]              he1,
    // allocation
    input  wire                    a_en0,
    input  wire                    a_en1,
    output wire [2:0]              ae0,
    output wire [2:0]              ae1,
    // fill
    input  wire                    w_en,
    input  wire [2:0]              w_ent,
    input  wire [LINE_BYTES*8-1:0] w_data,
    input  wire                    w_err,
    // read
    input  wire [2:0]              r_e0,
    input  wire [2:0]              r_e1,
    output reg  [LINE_BYTES*8-1:0] rd0,
    output reg  [LINE_BYTES*8-1:0] rd1,
    output reg                     rv0,
    output reg                     rv1,
    // observation (formal / debug)
    output reg  [7:0]              o_valid,
    output reg  [7:0]              o_pend,
    output reg  [8*LW-1:0]         o_tags      // entry e's tag in [e*LW +: LW]
`ifdef AD_FV_LBUF
    ,output reg [8*LINE_BYTES*8-1:0] fv_data   // formal only: every entry's data
`endif
);
    reg [8*LINE_BYTES*8-1:0] data;          // entry e in [e*LB +: LB]
    localparam LB = LINE_BYTES * 8;
    reg [2:0]              ptr;

    // lookup
    reg [7:0] m0, m1;
    integer i;
    always @(*) begin
        he0 = 3'd0; he1 = 3'd0;
        for (i = 0; i < 8; i = i + 1) begin
            m0[i] = o_valid[i] && (o_tags[i*LW +: LW] == l0);
            m1[i] = o_valid[i] && (o_tags[i*LW +: LW] == l1);
        end
        for (i = 7; i >= 0; i = i - 1) begin
            if (m0[i]) he0 = i[2:0];
            if (m1[i]) he1 = i[2:0];
        end
    end
    assign h0 = |m0;
    assign h1 = |m1;

    // allocation: round-robin from ptr, never the entry the other line of the attribute hits
    assign ae0 = (two && h1 && ptr == he1) ? ptr + 3'd1 : ptr;
    wire [2:0] b1 = a_en0 ? ae0 + 3'd1 : ptr;
    assign ae1 = (!a_en0 && h0 && b1 == he0) ? b1 + 3'd1 : b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            o_valid <= 8'd0; o_pend <= 8'd0; ptr <= 3'd0;
            o_tags <= {8*LW{1'b0}};
        end else if (clr) begin
            o_valid <= 8'd0; o_pend <= 8'd0; ptr <= 3'd0;
        end else begin
            if (w_en && o_pend[w_ent]) begin
                o_valid[w_ent] <= 1'b1; o_pend[w_ent] <= 1'b0;
            end
            if (a_en0) begin
                for (i = 0; i < 8; i = i + 1) if (ae0 == i) o_tags[i*LW +: LW] <= l0;
                o_valid[ae0] <= 1'b0; o_pend[ae0] <= 1'b1;
            end
            if (a_en1) begin
                for (i = 0; i < 8; i = i + 1) if (ae1 == i) o_tags[i*LW +: LW] <= l1;
                o_valid[ae1] <= 1'b0; o_pend[ae1] <= 1'b1;
            end
            if (a_en1)      ptr <= ae1 + 3'd1;
            else if (a_en0) ptr <= ae0 + 3'd1;
        end
    end

    // data: pure datapath, qualified by valid
    always @(posedge clk)
        if (rst_n && !clr && w_en && o_pend[w_ent])
            for (i = 0; i < 8; i = i + 1)
                if (w_ent == i) data[i*LB +: LB] <= w_err ? {LB{1'b0}} : w_data;

    // read ports (written as selects over the entries)
    always @(*) begin
        rd0 = {LB{1'b0}}; rd1 = {LB{1'b0}}; rv0 = 1'b0; rv1 = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            if (r_e0 == i) begin rd0 = data[i*LB +: LB]; rv0 = o_valid[i]; end
            if (r_e1 == i) begin rd1 = data[i*LB +: LB]; rv1 = o_valid[i]; end
        end
    end

`ifdef AD_FV_LBUF
    always @(*) fv_data = data;
`endif
endmodule
