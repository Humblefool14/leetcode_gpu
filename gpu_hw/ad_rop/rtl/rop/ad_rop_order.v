// ad_rop_order -- primitive-order retirement (spec/gpu/rop/ad_rop_order.md).
// A FIFO of the sequence numbers the rasterizer issued (ord_*); its head is
// the number to retire (ex_next).  SU quads (ex_*) and direct quads (dx_*) are
// taken only when their number equals the head (SU first); a quad with last
// pops the head.  Lane-less quads are taken and not forwarded.  One output
// register stage (valid/ready, no bubble) to ad_rop_ms.
// Parameters only narrow the datapath for formal; ad_rop uses the defaults.
module ad_rop_order #(
    parameter SEQ_W   = 16,
    parameter COLOR_W = 512,
    parameter DEPTH_W = 128,
    parameter AUX_W   = 154,
    parameter FIFO_LG = 4             // FIFO of 2^FIFO_LG issued numbers
) (
    input  wire               clk,
    input  wire               rst_n,
    // SU 0
    input  wire               ex_valid,
    output wire               ex_ready,
    input  wire [SEQ_W-1:0]   ex_seq,
    input  wire [31:0]        ex_xy,
    input  wire [3:0]         ex_mask,
    input  wire [COLOR_W-1:0] ex_color,
    input  wire [DEPTH_W-1:0] ex_depth,
    input  wire               ex_last,
    input  wire [AUX_W-1:0]   ex_aux,
    output wire [SEQ_W-1:0]   ex_next,
    // direct path
    input  wire               dx_valid,
    output wire               dx_ready,
    input  wire [SEQ_W-1:0]   dx_seq,
    input  wire [31:0]        dx_xy,
    input  wire [3:0]         dx_mask,
    input  wire [DEPTH_W-1:0] dx_depth,
    input  wire               dx_last,
    // issued numbers
    input  wire               ord_valid,
    input  wire [SEQ_W-1:0]   ord_seq,
    // to ad_rop_ms
    output reg                o_valid,
    input  wire               o_ready,
    output reg  [31:0]        o_xy,
    output reg  [3:0]         o_mask,
    output reg  [COLOR_W-1:0] o_color,
    output reg  [DEPTH_W-1:0] o_depth,
    output reg                o_dbg,
    output reg  [AUX_W-1:0]   o_aux,
    output wire               busy,
    output reg                ovf            // sticky: an issue into a full FIFO (simulation check)
);
    localparam N = 1 << FIFO_LG;
    // direct path's beat: rt 0, qlast, qfirst, nocol 0, front, d_s 0, zexp 0, sample 0 of each lane
    localparam [153:0] DX_AUX = {2'd0, 1'b1, 1'b1, 1'b0, 1'b1, 128'd0, 4'd0, 16'h1111};

    // ---------------- FIFO of issued numbers ----------------
    reg [SEQ_W-1:0]   fifo [0:N-1];
    reg [FIFO_LG-1:0] rd, wr;
    reg [FIFO_LG:0]   cnt;
    wire              nonempty = (cnt != 0);
    wire [SEQ_W-1:0]  cur = fifo[rd];
    assign ex_next = cur;

    // ---------------- acceptance ----------------
    wire out_free = !o_valid || o_ready;
`ifdef MUT_ORD_ANYSEQ
    wire ex_match = nonempty;                         // mutation: ignores the number
`else
    wire ex_match = nonempty && (ex_seq == cur);
`endif
    wire dx_match = nonempty && (dx_seq == cur);
    assign ex_ready = ex_match && out_free;
    assign dx_ready = dx_match && out_free && !(ex_valid && ex_match);   // SU first
    wire ex_fire = ex_valid && ex_ready;
    wire dx_fire = dx_valid && dx_ready;
    wire pop  = (ex_fire && ex_last) || (dx_fire && dx_last);
    wire push = ord_valid && (cnt != N[FIFO_LG:0] || pop);

    always @(posedge clk) begin
        if (!rst_n) begin
            rd <= 0; wr <= 0; cnt <= 0; ovf <= 1'b0;
        end else begin
            if (push) begin
                fifo[wr] <= ord_seq;
                wr <= wr + 1'b1;
            end
            if (pop) rd <= rd + 1'b1;
            cnt <= cnt + {{FIFO_LG{1'b0}}, push} - {{FIFO_LG{1'b0}}, pop};
            if (ord_valid && !push) ovf <= 1'b1;
        end
    end
`ifndef FORMAL
    always @(posedge clk)
        if (rst_n && ord_valid && !push)
            $display("FAIL ad_rop_order: issued sequence FIFO overflow (seq %h dropped)", ord_seq);
`endif

    // ---------------- output register ----------------
    always @(posedge clk) begin
        if (!rst_n) o_valid <= 1'b0;
        else if (ex_fire && ex_mask != 4'd0) o_valid <= 1'b1;
        else if (dx_fire && dx_mask != 4'd0) o_valid <= 1'b1;
        else if (o_ready) o_valid <= 1'b0;
    end
    always @(posedge clk) begin
        if (ex_fire) begin
            if (ex_mask != 4'd0) begin
                o_xy <= ex_xy; o_mask <= ex_mask; o_color <= ex_color; o_depth <= ex_depth;
                o_dbg <= 1'b0; o_aux <= ex_aux;
            end
        end else if (dx_fire && dx_mask != 4'd0) begin
            o_xy <= dx_xy; o_mask <= dx_mask; o_color <= {COLOR_W{1'b0}}; o_depth <= dx_depth;
            o_dbg <= 1'b1; o_aux <= DX_AUX[AUX_W-1:0];
        end
    end

    assign busy = o_valid || nonempty;
endmodule
