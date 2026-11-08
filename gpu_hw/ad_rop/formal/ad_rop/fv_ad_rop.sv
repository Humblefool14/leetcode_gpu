// Top-level formal harness for ad_rop: the whole wiring (order, ms, ds, occ, wb,
// wpix, mux) with the arithmetic datapaths blackboxed (fblend, blend, dtest and the
// fp adder are replaced by unconstrained stubs in fv_bb.v).  Checks the external
// AMB client port protocol, that the ROP never requests memory while idle, that
// the occlusion counter only moves on quads, and that ex_ready implies the offered
// seq is ex_next.  Free inputs are module ports (new values every cycle).
module fv_ad_rop (
    input clk,
    input st_we, input [8:0] st_idx, input [31:0] st_wdata,
    input ex_valid, input [15:0] ex_seq, input [31:0] ex_xy, input [3:0] ex_mask,
    input [511:0] ex_color, input [127:0] ex_depth, input ex_last, input [153:0] ex_aux,
    input dx_valid, input [15:0] dx_seq, input [31:0] dx_xy, input [3:0] dx_mask,
    input [127:0] dx_depth, input dx_last,
    input ord_valid, input [15:0] ord_seq, input occ_clear,
    input req_ready, input rsp_valid, input rsp_write, input [7:0] rsp_tag,
    input [255:0] rsp_rdata, input rsp_error
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire busy, ex_ready, dx_ready, req_valid, req_write;
    wire [15:0] ex_next; wire [39:0] occ_count;
    wire [26:0] req_line; wire [31:0] req_be; wire [255:0] req_wdata; wire [7:0] req_tag;

    ad_rop #(.ADDR_W(32), .LINE_BYTES(32), .LINE_SHIFT(5), .STENCIL(1)) dut (
        .clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .busy(busy),
        .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy), .ex_mask(ex_mask),
        .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last), .ex_aux(ex_aux), .ex_next(ex_next),
        .dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy), .dx_mask(dx_mask),
        .dx_depth(dx_depth), .dx_last(dx_last), .ord_valid(ord_valid), .ord_seq(ord_seq),
        .occ_count(occ_count), .occ_clear(occ_clear),
        .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
        .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
        .rsp_error(rsp_error)
    );

    // the memory side: one response per accepted request, with an outstanding tag
    wire [4:0] outstanding;
    ad_amb_client_props #(.LINE_BYTES(32), .LINE_W(27), .CNT_W(5)) amb (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
        .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
        .rsp_valid(rsp_valid), .outstanding(outstanding));
    // tags in flight (the mux remaps to its 16-entry table index)
    reg [255:0] tag_out; reg [255:0] tag_wr;
    always @(posedge clk) begin
        if (!rst_n) begin tag_out <= 0; tag_wr <= 0; end
        else begin
            if (rsp_valid) tag_out[rsp_tag] <= 1'b0;
            if (req_valid && req_ready) begin tag_out[req_tag] <= 1'b1; tag_wr[req_tag] <= req_write; end
        end
    end
    always @(*) begin
        if (rsp_valid) begin
            assume (tag_out[rsp_tag]);
            assume (rsp_write == tag_wr[rsp_tag]);
        end
        assume (outstanding < 5'd30);
        // CP rule: the ROP range is not written while the ROP is busy
        if (busy) assume (!st_we);
    end
    reg [3:0] issued;
    always @(posedge clk) if (!rst_n) issued <= 0; else issued <= issued + (ord_valid ? 4'd1 : 4'd0);
    always @(*) assume (!(ord_valid && issued >= 4'd12));      // bounded issue for the BMC window

    reg [39:0] p_occ; reg p_ok = 0; reg p_clr;
    always @(posedge clk) begin p_occ <= occ_count; p_ok <= rst_n; p_clr <= occ_clear; end
    always @(posedge clk) if (rst_n && p_ok) begin
        if (!p_clr && occ_count != p_occ) a_occ_mono: assert (occ_count > p_occ);
    end
    always @(*) if (rst_n) begin
        if (ex_valid && ex_ready) a_ex_seq: assert (ex_seq == ex_next);
        if (!busy) a_idle_noreq: assert (!req_valid);
        if (!busy) a_idle_noout: assert (outstanding == 0);
    end
    always @(*) if (rst_n) cover (req_valid && req_ready);   // a quad reaches memory (a write needs ~20 cycles, beyond the cover window)
endmodule
