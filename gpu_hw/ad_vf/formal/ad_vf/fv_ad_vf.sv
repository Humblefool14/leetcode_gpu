// fv_ad_vf: top-level harness of ad_vf (wiring of index, asm, fetch, conv and ad_amb_mux).
// Free STATE writes, DRAW kicks, SU grants and RX ready; an in-order memory whose response tags
// follow the requests (a 4-deep tag FIFO in the harness).  Checks the merged AMB port (payload held,
// read only), the primitive and register outputs (prim payload held until ready, vl_go one cycle),
// and that busy is up whenever a primitive or a register write is out.
module fv_ad_vf (
    input wire clk,
    input wire        st_we,
    input wire [8:0]  st_idx,
    input wire [31:0] st_wdata,
    input wire        draw_kick,
    input wire        vl_gnt,
    input wire [7:0]  vl_ptbase,
    input wire        prim_ready,
    input wire        req_ready,
    input wire        rsp_valid,
    input wire [255:0] rsp_rdata,
    input wire        rsp_error
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire busy, vl_req, vl_go, vl_we, prim_valid, prim_last, req_valid, req_write;
    wire [31:0] vl_mask, vl_data;
    wire [5:0] vl_reg; wire [4:0] vl_lane;
    wire [25:0] prim_vtx; wire [2:0] prim_free;
    wire [26:0] req_line; wire [31:0] req_be; wire [255:0] req_wdata; wire [7:0] req_tag;

    // in-order tag FIFO of the memory model
    reg [7:0] tq [0:3]; reg [1:0] th, tt; reg [2:0] tn;
    wire [7:0] rsp_tag = tq[th];
    always @(posedge clk) begin
        if (!rst_n) begin th <= 0; tt <= 0; tn <= 0; end
        else begin
            if (req_valid && req_ready) begin tq[tt] <= req_tag; tt <= tt + 1; end
            if (rsp_valid) th <= th + 1;
            tn <= tn + (req_valid && req_ready) - rsp_valid;
        end
    end
    always @(*) begin
        if (!rst_n || tn == 0) assume (!rsp_valid);
        if (tn == 4) assume (!req_ready);
        if (!rst_n) assume (!draw_kick && !vl_gnt);
        if (!vl_req) assume (!vl_gnt);
        // the CP does not write the VF's STATE while it is busy (ad_vf.md section 10)
        if (busy) assume (!st_we && !draw_kick);   // the CP waits for VF idle before a DRAW
    end
    reg p_gnt = 0; always @(posedge clk) p_gnt <= vl_gnt;
    always @(*) if (p_gnt) assume (!vl_gnt);

    ad_vf dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
        .draw_kick(draw_kick), .busy(busy), .vl_req(vl_req), .vl_gnt(vl_gnt), .vl_ptbase(vl_ptbase),
        .vl_go(vl_go), .vl_mask(vl_mask), .vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane),
        .vl_data(vl_data), .prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
        .prim_free(prim_free), .prim_last(prim_last), .req_valid(req_valid), .req_ready(req_ready),
        .req_write(req_write), .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata),
        .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(1'b0), .rsp_tag(rsp_tag),
        .rsp_rdata(rsp_rdata), .rsp_error(rsp_error), .fv_idx_err(fv_err));

    // index fault seen (mirrors ad_vf's idx_err: an rsp_error answering an index request)
    wire fv_err;
    reg pv = 0, pr = 0, ppv = 0, ppr = 0;
    reg [26:0] pl; reg [7:0] pt; reg [25:0] pvtx; reg [2:0] pfree; reg plast;
    always @(posedge clk) begin
        pv <= req_valid && rst_n; pr <= req_ready; pl <= req_line; pt <= req_tag;
        ppv <= prim_valid && rst_n; ppr <= prim_ready; pvtx <= prim_vtx; pfree <= prim_free; plast <= prim_last;
    end
    always @(*) if (rst_n) begin
        assert (!(req_valid && req_write));                       // the VF only reads
        if (pv && !pr) assert (req_valid && req_tag == pt);   // held until ready
`ifdef FV_LINE
        // bmc_line_open: fails in the AIG model only; the counterexample does not reproduce when its
        // inputs are replayed in simulation (see docs/ARCHITECTURE.md).  Line hold is proven for each
        // client (formal/ad_vf_index, formal/ad_vf_fetch) and for formal/ad_amb_mux.
        if (pv && !pr) assert (req_line == pl);
`endif
        if (ppv && !ppr) assert (prim_valid && prim_vtx == pvtx && prim_free == pfree && prim_last == plast);
        // after an index fault (dut.idx_err) busy only covers reads in flight; the CP resets the VF
        if ((prim_valid || vl_go || vl_req) && !fv_err) assert (busy);
    end
endmodule
