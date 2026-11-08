// ad_su_lds -- shared memory of the SU (spec/gpu/su/ad_su_lds.md).
// LDS_BYTES of block RAM (ad_mem_tdpram), word addressed, addresses wrap.
// One lane group at a time, one lane access per cycle, lanes in order:
//   lds   (op 0): EXEC lanes read word (rs1 + imm) >> 2; one beat with the words.
//   sts   (op 1): side-effect lanes write rs2 at (rs1 + imm) >> 2; the higher
//                 lane wins on one word; a beat without data.
//   atoms (op 2): per side-effect lane, lanes in order, a read cycle then a
//                 write cycle of the new value (ad_mem_atom_alu; operation
//                 sub[3:0], operand rs2, cmpxchg compare rs3) at rs1 >> 2 (no
//                 immediate); the beat returns the old values (l_wr = WRD).
// As the unit takes one group at a time, an atoms is indivisible with respect
// to every other lds, sts and atoms.  scrub writes 0 to every word through
// port A (ad_su_scrub); port B is the meshlet exporter's read port.
// Mutations: MUT_LDS_ATOM_RAW (lanes after the first skip their read cycle:
// the new value comes from a stale read), MUT_LDS_ATOM_NOCMP (cmpxchg
// compares with rs2).
module ad_su_lds #(
    parameter NPHYS     = 8,
    parameter NWARPS    = 4,
    parameter WARP_W    = 2,
    parameter GRP_W     = 2,
    parameter SBE_W     = 2,
    parameter UOP_W     = 108,
    parameter LDS_BYTES = 4096,
    parameter LDS_AW    = $clog2(LDS_BYTES / 4)
) (
    input  wire                  clk,
    input  wire                  rst_n,
    // execution bus
    input  wire                  x_valid,
    input  wire [WARP_W-1:0]     x_warp,
    input  wire [GRP_W-1:0]      x_grp,
    input  wire                  x_last,
    input  wire [SBE_W:0]        x_sbe,
    input  wire [15:0]           x_pc,
    input  wire [UOP_W-1:0]      x_uop,
    input  wire [NPHYS*32-1:0]   x_a,
    input  wire [NPHYS*32-1:0]   x_b,
    input  wire [NPHYS*32-1:0]   x_c,
    input  wire [2*NPHYS-1:0]    x_mask,
    input  wire [31:0]           x_info,
    output wire                  x_ready,
    // long result
    output wire                  l_valid,
    input  wire                  l_ready,
    output reg  [WARP_W-1:0]     l_warp,
    output reg  [GRP_W-1:0]      l_grp,
    output reg  [6:0]            l_rd,
    output reg  [NPHYS*32-1:0]   l_data,
    output reg  [NPHYS-1:0]      l_lanes,
    output reg                   l_wr,
    output reg                   l_last,
    output reg  [SBE_W:0]        l_sbe,
    output reg  [2:0]            l_cls,
    // scrub (session protection)
    input  wire                  scrub,
    output wire                  scrub_busy,
    // meshlet exporter read port (word address, data one cycle later)
    input  wire                  mesh_rd_en,
    input  wire [LDS_AW-1:0]     mesh_rd_addr,
    output wire [31:0]           mesh_rd_data
`ifdef FORMAL
    ,
    // formal only (harness invariants): state, latched group, read data,
    // capture and the port A write
    output wire [2:0]            fv_st,
    output wire [1:0]            fv_kind,
    output wire [NPHYS-1:0]      fv_pend,
    output wire [NPHYS*32-1:0]   fv_ad,
    output wire [NPHYS*32-1:0]   fv_opb,
    output wire [NPHYS*32-1:0]   fv_opc,
    output wire [3:0]            fv_aop,
    output wire [31:0]           fv_ram_rd,
    output wire                  fv_cap_v,
    output wire [((NPHYS > 1) ? $clog2(NPHYS) : 1)-1:0] fv_cap_ln,
    output wire                  fv_awe,
    output wire [LDS_AW-1:0]     fv_aaddr,
    output wire [31:0]           fv_awdata
`endif
);
`include "ad_su_uop.vh"

    localparam WORDS = LDS_BYTES / 4;
    localparam LIW = (NPHYS > 1) ? $clog2(NPHYS) : 1;
    localparam [2:0] S_IDLE = 3'd0, S_ACC = 3'd1, S_ATR = 3'd2, S_ATW = 3'd3, S_DRAIN = 3'd4,
                     S_BEAT = 3'd5;

    reg [2:0]            st;
    reg [1:0]            kind;      // 0 lds, 1 sts, 2 atoms
    reg [NPHYS-1:0]      pend;
    reg [NPHYS*32-1:0]   ad, opb, opc;
    reg [3:0]            aop;
    reg                  cap_v;
    reg [LIW-1:0]        cap_ln;

    wire       take = x_valid && (x_uop[AD_UOP_UNIT +: 4] == AD_UNIT_LDS) && x_ready;
    wire [7:0] op   = x_uop[AD_UOP_OP +: 8];
    wire [31:0] imm = x_uop[AD_UOP_IMM +: 32];
    wire [NPHYS-1:0] m_exec = x_mask[NPHYS-1:0];
    wire [NPHYS-1:0] m_side = x_mask[2*NPHYS-1:NPHYS];
    wire op_ld = (op == AD_LDS_LDS), op_st = (op == AD_LDS_STS), op_at = (op == AD_LDS_ATOM);
    wire [NPHYS-1:0] t_pend  = op_ld ? m_exec : (op_st || op_at) ? m_side : {NPHYS{1'b0}};
    wire [NPHYS-1:0] t_lanes = op_ld ? m_exec : op_at ? m_side : {NPHYS{1'b0}};
    reg  [NPHYS*32-1:0] t_ad;
    integer i;
    always @(*) begin
        for (i = 0; i < NPHYS; i = i + 1)
            t_ad[i*32 +: 32] = op_at ? x_a[i*32 +: 32] : x_a[i*32 +: 32] + imm;
    end

    // scrub
    wire              sc_on;
    wire [LDS_AW-1:0] sc_a;
    ad_su_scrub #(.DEPTH(WORDS), .AW(LDS_AW)) sc (
        .clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a));
    assign scrub_busy = sc_on;

    assign x_ready = (st == S_IDLE) && !sc_on;
    assign l_valid = (st == S_BEAT);

    // the first pending lane
    reg [LIW-1:0] al;
    always @(*) begin
        al = {LIW{1'b0}};
        for (i = NPHYS - 1; i >= 0; i = i - 1) if (pend[i]) al = i[LIW-1:0];
    end
    wire [31:0]       al_byte = ad[al*32 +: 32];
    wire [LDS_AW-1:0] al_w    = al_byte[LDS_AW+1:2];
    wire [NPHYS-1:0]  al_bit  = {{(NPHYS-1){1'b0}}, 1'b1} << al;
    wire [NPHYS-1:0]  pend_left = pend & ~al_bit;

    // atomic operation
    wire [31:0] ram_rd;
    wire [31:0] at_nv;
`ifdef MUT_LDS_ATOM_NOCMP
    wire [31:0] at_cmp = opb[al*32 +: 32];
`else
    wire [31:0] at_cmp = opc[al*32 +: 32];
`endif
    ad_mem_atom_alu u_alu (.op(aop), .old(ram_rd), .a(opb[al*32 +: 32]), .cmp(at_cmp), .nv(at_nv));

    // port A
    wire acc_rd = (st == S_ACC) && (kind == 2'd0);
    wire acc_wr = (st == S_ACC) && (kind == 2'd1);
    // no access in a reset cycle (the state is not yet defined)
    wire a_en   = rst_n && (sc_on || acc_rd || acc_wr || (st == S_ATR) || (st == S_ATW));
    wire a_we   = rst_n && (sc_on || acc_wr || (st == S_ATW));
    wire [LDS_AW-1:0] a_addr  = sc_on ? sc_a : al_w;
    wire [31:0]       a_wdata = sc_on ? 32'd0 : (st == S_ATW) ? at_nv : opb[al*32 +: 32];

    ad_mem_tdpram #(.DEPTH(WORDS), .AW(LDS_AW), .DW(32)) u_ram (
        .clk(clk), .a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata), .a_rdata(ram_rd),
        .b_en(mesh_rd_en), .b_addr(mesh_rd_addr), .b_rdata(mesh_rd_data));

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; kind <= 2'd0; pend <= {NPHYS{1'b0}}; cap_v <= 1'b0; cap_ln <= {LIW{1'b0}};
            ad <= 0; opb <= 0; opc <= 0; aop <= 4'd0;
            l_warp <= 0; l_grp <= 0; l_rd <= 7'd0; l_data <= 0; l_lanes <= 0; l_wr <= 1'b0;
            l_last <= 1'b0; l_sbe <= 0; l_cls <= 3'd0;
        end else begin
            cap_v <= 1'b0;
            if (cap_v) l_data[cap_ln*32 +: 32] <= ram_rd;
            case (st)
            S_IDLE: if (take) begin
                l_warp <= x_warp; l_grp <= x_grp; l_rd <= x_uop[AD_UOP_RD +: 7];
                l_last <= x_last; l_sbe <= x_sbe; l_cls <= x_uop[AD_UOP_CLS +: 3];
                l_lanes <= t_lanes; l_data <= {(NPHYS*32){1'b0}};
                l_wr <= x_uop[AD_UOP_WRD] && (|t_lanes);
                pend <= t_pend; ad <= t_ad; opb <= x_b; opc <= x_c;
                aop <= x_uop[AD_UOP_SUB +: 4];
                kind <= op_at ? 2'd2 : op_st ? 2'd1 : 2'd0;
                st <= (t_pend == {NPHYS{1'b0}}) ? S_BEAT : op_at ? S_ATR : S_ACC;
            end
            S_ACC: begin
                if (kind == 2'd0) begin cap_v <= 1'b1; cap_ln <= al; end
                pend <= pend_left;
                if (pend_left == {NPHYS{1'b0}}) st <= (kind == 2'd0) ? S_DRAIN : S_BEAT;
            end
            S_ATR: st <= S_ATW;
            S_ATW: begin
                l_data[al*32 +: 32] <= ram_rd;
                pend <= pend_left;
`ifdef MUT_LDS_ATOM_RAW
                st <= (pend_left == {NPHYS{1'b0}}) ? S_BEAT : S_ATW;
`else
                st <= (pend_left == {NPHYS{1'b0}}) ? S_BEAT : S_ATR;
`endif
            end
            S_DRAIN: st <= S_BEAT;
            S_BEAT: if (l_ready) st <= S_IDLE;
            default: st <= S_IDLE;
            endcase
        end
    end

`ifdef FORMAL
    assign fv_st = st; assign fv_kind = kind; assign fv_pend = pend; assign fv_ad = ad; assign fv_opb = opb;
    assign fv_opc = opc; assign fv_aop = aop; assign fv_ram_rd = ram_rd; assign fv_cap_v = cap_v;
    assign fv_cap_ln = cap_ln; assign fv_awe = a_we; assign fv_aaddr = a_addr; assign fv_awdata = a_wdata;
`endif

    wire unused = &{1'b0, x_pc, x_info, al_byte, NWARPS[0]};
endmodule
