// ad_vf_asm_step -- one assembly step of ad_vf_asm (spec section 4): a new vertex at lane `lane`
// joins the current run (strip / fan / list primitive).  clr ends the run first (restart marker
// already consumed, or a change of instance).  Outputs the primitive it completes (assembly
// order x, y, z and the strip parity, for ad_vf_asm_order), the run's next state, and the list
// fit rule: nofit = the vertex starts a list primitive that no longer fits in lanes lane..31.
// Run slots (see ad_vf_asm_carry): r0_sel 0 keep, 1 the new vertex, 2 r1; r1_new r1 <= new.
module ad_vf_asm_step #(
    parameter LANES = 32        // lanes per warp (32; formal/ad_vf_asm reduces it)
) (
    input  wire [2:0] cls,
    input  wire       is_list,
    input  wire [1:0] psize,
    input  wire [1:0] n,        // run state: vertices (strip/fan saturate at 2; list position)
    input  wire       par,      // strip parity
    input  wire       clr,      // end the run before this vertex
    input  wire [4:0] r0_l,
    input  wire [4:0] r1_l,
    input  wire [4:0] lane,
    output wire       nofit,
    output reg        pv,       // a primitive is complete
    output reg  [4:0] x,
    output reg  [4:0] y,
    output reg  [4:0] z,
    output reg        ppar,
    output reg  [1:0] n_nx,
    output reg        par_nx,
    output reg  [1:0] r0_sel,
    output reg        r1_new
);
    wire [1:0] ne = clr ? 2'd0 : n;
    wire       pe = clr ? 1'b0 : par;
    localparam [5:0] NL = LANES;
    assign nofit = is_list && (ne == 2'd0) && ({1'b0, lane} + {4'd0, psize} > NL);

    always @(*) begin
        pv = 1'b0; x = lane; y = lane; z = lane; ppar = 1'b0;
        n_nx = ne; par_nx = pe; r0_sel = 2'd0; r1_new = 1'b0;
        case (cls)
            3'd1: begin                                   // line list
                if (ne == 2'd0) begin r0_sel = 2'd1; n_nx = 2'd1; end
                else begin pv = 1'b1; x = r0_l; y = lane; n_nx = 2'd0; end
            end
            3'd2: begin                                   // line strip
                if (ne != 2'd0) begin pv = 1'b1; x = r1_l; y = lane; end
                r1_new = 1'b1; n_nx = 2'd1;
            end
            3'd3: begin                                   // triangle list
                if (ne == 2'd0)      begin r0_sel = 2'd1; n_nx = 2'd1; end
                else if (ne == 2'd1) begin r1_new = 1'b1; n_nx = 2'd2; end
                else begin pv = 1'b1; x = r0_l; y = r1_l; z = lane; n_nx = 2'd0; end
            end
            3'd4: begin                                   // triangle strip
                if (ne == 2'd0)      begin r1_new = 1'b1; n_nx = 2'd1; end
                else if (ne == 2'd1) begin r0_sel = 2'd2; r1_new = 1'b1; n_nx = 2'd2; end
                else begin
                    pv = 1'b1; x = r0_l; y = r1_l; z = lane; ppar = pe;
                    r0_sel = 2'd2; r1_new = 1'b1; par_nx = ~pe;
                end
            end
            3'd5: begin                                   // fan
                if (ne == 2'd0)      begin r0_sel = 2'd1; n_nx = 2'd1; end
                else if (ne == 2'd1) begin r1_new = 1'b1; n_nx = 2'd2; end
                else begin pv = 1'b1; x = r1_l; y = lane; z = r0_l; r1_new = 1'b1; end
            end
            default: begin pv = 1'b1; n_nx = 2'd0; end    // points
        endcase
    end
endmodule
