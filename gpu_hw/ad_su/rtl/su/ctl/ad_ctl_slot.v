// ad_ctl_slot -- the state machine of one warp slot (ad_su_sched), with the
// slot's pc.  States:
//   FREE  -(alloc: a vertex/fragment grant or a workgroup's reservation)-> ALLOC
//   ALLOC -(start: init_* sent for this slot)-> READY (pc 0)
//   READY -(sel: chosen for fetch)-> FETCH -(take: f_valid && f_ready)-> WAIT_FB
//   WAIT_FB -(fb 0)-> READY (pc+1) | -(fb 1)-> WAIT_WC | -(fb 2)-> REPLAY
//           (fb 2 with a wake in the same cycle -> READY)
//   REPLAY -(wake)-> READY
//   WAIT_WC -(wc 0)-> READY (pc = wc_pc) | -(wc 1)-> ENDED | -(wc 2)-> BAR (pc = wc_pc)
//   BAR -(bar_rel)-> READY;  ENDED -(xr)-> FREE
// Events outside their state are ignored.
module ad_ctl_slot (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        alloc,
    input  wire        start,
    input  wire        sel,
    input  wire        take,
    input  wire        fb,
    input  wire [1:0]  fb_kind,
    input  wire        wake,
    input  wire        wc,
    input  wire [1:0]  wc_op,
    input  wire [15:0] wc_pc,
    input  wire        bar_rel,
    input  wire        xr,
    output reg  [3:0]  st,
    output reg  [15:0] pc
);
    localparam [3:0] FREE = 4'd0, ALLOC = 4'd1, READY = 4'd2, FETCH = 4'd3, WAIT_FB = 4'd4,
                     WAIT_WC = 4'd5, REPLAY = 4'd6, BAR = 4'd7, ENDED = 4'd8;
    always @(posedge clk) begin
        if (!rst_n) begin
            st <= FREE;
            pc <= 16'd0;
        end else begin
            case (st)
            FREE:    if (alloc) st <= ALLOC;
            ALLOC:   if (start) begin st <= READY; pc <= 16'd0; end
            READY:   if (sel) st <= FETCH;
            FETCH:   if (take) st <= WAIT_FB;
            WAIT_FB: if (fb) begin
                         case (fb_kind)
                         2'd0:    begin st <= READY; pc <= pc + 16'd1; end
                         2'd1:    st <= WAIT_WC;
                         2'd2:    st <= wake ? READY : REPLAY;
                         default: st <= READY;
                         endcase
                     end
            REPLAY:  if (wake) st <= READY;
            WAIT_WC: if (wc) begin
                         case (wc_op)
                         2'd1:    st <= ENDED;
                         2'd2:    begin st <= BAR; pc <= wc_pc; end
                         default: begin st <= READY; pc <= wc_pc; end
                         endcase
                     end
            BAR:     if (bar_rel) st <= READY;
            ENDED:   if (xr) st <= FREE;
            default: st <= FREE;
            endcase
        end
    end
endmodule
