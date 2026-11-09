// fv_ad_vf_asm_step -- the assembly step (with ad_vf_asm_carry and ad_vf_asm_topo) driven as
// ad_vf_asm drives it, against a vertex-history model of spec section 4.  Each cycle one event:
//   add   (optionally clr: the run ends first, as on a change of instance) at the next lane;
//   rst   (restart marker: the run ends);
//   carry (a new warp: the carried vertices are rebased onto lanes 0, 1 and the next lane = count).
// Model: k = vertices of the run (k%2, k%3, k>=1, k>=2 kept) and the lanes of the run's first,
// newest and second-newest vertices; the carry rule rebases them as the spec lists ("the last two
// of a strip, the fan's first and last; the started vertices of a list primitive or a line
// strip's last").  Checked at each add: the primitive completed (Vulkan's vertex numbers:
// line list 2i+1, line strip i>=1, triangle list 3i+2, strip / fan i>=2), its assembly lanes,
// the strip parity, and the list fit rule.  The carry count and the run state are also checked.
module fv_ad_vf_asm_step (
    input wire       clk,
    input wire [1:0] ev,       // 0 none, 1 add, 2 rst, 3 carry
    input wire       ev_clr
);
    (* anyconst *) reg [2:0] topo;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;

    wire [2:0] cls; wire [1:0] kind, psize; wire is_list;
    ad_vf_asm_topo u_topo (.topo(topo), .cls(cls), .kind(kind), .is_list(is_list), .psize(psize));

    // parent registers (as in ad_vf_asm)
    reg [1:0] n = 2'd0; reg par = 1'b0; reg [4:0] r0_l = 5'd0, r1_l = 5'd0; reg [5:0] lane = 6'd0;
    wire add = (ev == 2'd1), rst = (ev == 2'd2), car = (ev == 2'd3);
    wire clr = ev_clr;          // the step is evaluated every cycle; only an add applies it
    wire nofit, pv, ppar, par_nx, r1_new; wire [4:0] x, y, z; wire [1:0] n_nx, r0_sel;
    ad_vf_asm_step dut (.cls(cls), .is_list(is_list), .psize(psize), .n(n), .par(par), .clr(clr),
        .r0_l(r0_l), .r1_l(r1_l), .lane(lane[4:0]), .nofit(nofit), .pv(pv), .x(x), .y(y), .z(z),
        .ppar(ppar), .n_nx(n_nx), .par_nx(par_nx), .r0_sel(r0_sel), .r1_new(r1_new));
    wire [1:0] c_cnt; wire c_c0_r1, c_r0_mv, c_r1_mv, c_r1_l;
    ad_vf_asm_carry u_carry (.cls(cls), .n(n), .cnt(c_cnt), .c0_r1(c_c0_r1), .r0_mv(c_r0_mv),
        .r1_mv(c_r1_mv), .r1_l(c_r1_l));

    // model
    reg k1 = 1'b0, k2 = 1'b0, km2 = 1'b0; reg [1:0] km3 = 2'd0;      // k>=1, k>=2, k%2, k%3
    reg [4:0] h_new = 5'd0, h_old = 5'd0, h_first = 5'd0;
    wire e1 = clr ? 1'b0 : k1, e2 = clr ? 1'b0 : k2, em2 = clr ? 1'b0 : km2;
    wire [1:0] em3 = clr ? 2'd0 : km3;
    wire start = (cls == 3'd1) ? !em2 : (cls == 3'd3) ? (em3 == 2'd0) : 1'b1;   // starts a list primitive
    // the parent adds only at lanes 0..31 and not a list primitive that does not fit
    always @(*) if (!init && add) begin
        assume (lane <= 6'd31);
        assume (!nofit);
    end

    always @(*) if (!init) begin
        if (lane <= 6'd31) a_fit: assert (nofit == (is_list && start && ({1'b0, lane} + {4'd0, psize} > 6'd32)));
        if (add) begin
            case (cls)
                3'd1: begin a_pv1: assert (pv == em2);
                            if (pv) a_l1: assert (x == h_new && y == lane[4:0]); end
                3'd2: begin a_pv2: assert (pv == e1);
                            if (pv) a_l2: assert (x == h_new && y == lane[4:0]); end
                3'd3: begin a_pv3: assert (pv == (em3 == 2'd2));
                            if (pv) a_l3: assert (x == h_old && y == h_new && z == lane[4:0]); end
                3'd4: begin a_pv4: assert (pv == e2);
                            if (pv) a_l4: assert (x == h_old && y == h_new && z == lane[4:0] && ppar == em2); end
                3'd5: begin a_pv5: assert (pv == e2);
                            if (pv) a_l5: assert (x == h_new && y == lane[4:0] && z == h_first); end
                default: begin a_pv0: assert (pv); a_l0: assert (x == lane[4:0] && y == lane[4:0] && z == lane[4:0]); end
            endcase
        end
        if (car) begin
            case (cls)
                3'd1:       a_c1: assert (c_cnt == (km2 ? 2'd1 : 2'd0));
                3'd2:       a_c2: assert (c_cnt == (k1 ? 2'd1 : 2'd0));
                3'd3:       a_c3: assert (c_cnt == km3);
                3'd4, 3'd5: a_c4: assert (c_cnt == (k2 ? 2'd2 : k1 ? 2'd1 : 2'd0));
                default:    a_c0: assert (c_cnt == 2'd0);
            endcase
        end
        // run state consistent with the model
        a_n: assert (n == ((cls == 3'd1) ? {1'b0, km2} : (cls == 3'd3) ? km3 :
                           (cls == 3'd2) ? {1'b0, k1} : (cls == 3'd4 || cls == 3'd5) ? (k2 ? 2'd2 : {1'b0, k1}) : 2'd0));
    end

    always @(posedge clk) begin
        if (add) begin
            n <= n_nx; par <= par_nx; lane <= lane + 6'd1;
            if (r0_sel == 2'd1) r0_l <= lane[4:0]; else if (r0_sel == 2'd2) r0_l <= r1_l;
            if (r1_new) r1_l <= lane[4:0];
            // model
            if (!e1) h_first <= lane[4:0];
            h_old <= h_new; h_new <= lane[4:0];
            k1 <= 1'b1; k2 <= e1; km2 <= !em2; km3 <= (em3 == 2'd2) ? 2'd0 : em3 + 2'd1;
        end else if (rst) begin
            n <= 2'd0; par <= 1'b0;
            k1 <= 1'b0; k2 <= 1'b0; km2 <= 1'b0; km3 <= 2'd0;
        end else if (car) begin
            if (c_r0_mv) r0_l <= 5'd0;
            if (c_r1_mv) r1_l <= {4'd0, c_r1_l};
            lane <= {4'd0, c_cnt};
            // model: spec carry rule on the vertex history
            case (cls)
                3'd1: if (km2) h_new <= 5'd0;
                3'd2: if (k1) h_new <= 5'd0;
                3'd3: if (km3 == 2'd1) h_new <= 5'd0;
                      else if (km3 == 2'd2) begin h_old <= 5'd0; h_new <= 5'd1; end
                3'd4: if (k2) begin h_old <= 5'd0; h_new <= 5'd1; end
                      else if (k1) h_new <= 5'd0;
                3'd5: if (k2) begin h_first <= 5'd0; h_new <= 5'd1; end
                      else if (k1) begin h_first <= 5'd0; h_new <= 5'd0; end
                default: ;
            endcase
        end
    end
endmodule
