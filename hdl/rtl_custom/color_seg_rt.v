// color_seg_rt.v - colour segmentation with RUN-TIME thresholds and a fixed / adaptive decision rule
//
// Same normalized pixel interface and the same fixed latency (2 clocks) as color_segment.v. The module detects the
// dominant colour in the "R" slot ([23:16]) of in_rgb; to detect green or blue the integrator simply permutes the
// channels in front of it (green: {G,R,B}, blue: {B,G,R}), so one module serves all three colours.
//
// hit (per pixel) = in_de && R >= thr_rmin && rule
//   adaptive = 0 (fixed rule)   : R >= G + thr_delta  &&  R >= B + thr_delta      (absolute difference, as color_segment)
//   adaptive = 1 (ratio rule)   : 8*R >= 13*G         &&  8*R >= 13*B             (G, B at most 61.5 % of R)
// The ratio rule only depends on the ratios between the channels, so it does not change when the whole scene
// becomes brighter or darker; thr_rmin (driven by the integrator from the measured scene brightness, see
// thr_adapt.v) is the only absolute quantity left, and it is the noise floor.
//
// Widths: every sum / product is wide enough that nothing wraps (G + DELTA <= 510 in 10 bits, 13*G <= 3315 and
// 8*R <= 2040 in 12 bits). thr_* are sampled every clock (change them in blanking for a tear-free change; a change
// in the middle of a frame only changes the decision for the following pixels).
//
// Outputs: out_de / out_hit / x / y / sof / eol / eof, all delayed by exactly LATENCY = 2 clocks, all 0 while out_de = 0.
// Reset: active-low asynchronous, release synchronized by the integrator.

module color_seg_rt (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_de,
    input  wire [23:0] in_rgb,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,

    input  wire [7:0]  thr_rmin,
    input  wire [7:0]  thr_delta,
    input  wire        adaptive,

    output reg         out_de,
    output reg         out_hit,
    output reg  [11:0] out_x,
    output reg  [11:0] out_y,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof
);

    localparam LATENCY = 2;

    // ---------------- stage 1 : conditions
    wire [9:0]  r10 = {2'b00, in_rgb[23:16]};
    wire [9:0]  gd  = {2'b00, in_rgb[15:8]} + {2'b00, thr_delta};
    wire [9:0]  bd  = {2'b00, in_rgb[7:0]}  + {2'b00, thr_delta};

    wire [11:0] r8  = {1'b0, in_rgb[23:16], 3'b000};                                   // 8*R
    wire [11:0] g13 = {1'b0, in_rgb[15:8], 3'b000} + {2'b00, in_rgb[15:8], 2'b00} + {4'b0000, in_rgb[15:8]};   // 13*G
    wire [11:0] b13 = {1'b0, in_rgb[7:0],  3'b000} + {2'b00, in_rgb[7:0],  2'b00} + {4'b0000, in_rgb[7:0]};    // 13*B

    wire c_rmin = (r10 >= {2'b00, thr_rmin});
    wire c_rg   = adaptive ? (r8 >= g13) : (r10 >= gd);
    wire c_rb   = adaptive ? (r8 >= b13) : (r10 >= bd);

    reg         s1_de, s1_c_rmin, s1_c_rg, s1_c_rb, s1_sof, s1_eol, s1_eof;
    reg  [11:0] s1_x, s1_y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_de <= 1'b0; s1_c_rmin <= 1'b0; s1_c_rg <= 1'b0; s1_c_rb <= 1'b0;
            s1_sof <= 1'b0; s1_eol <= 1'b0; s1_eof <= 1'b0; s1_x <= 12'd0; s1_y <= 12'd0;
        end
        else begin
            s1_de <= in_de; s1_c_rmin <= c_rmin; s1_c_rg <= c_rg; s1_c_rb <= c_rb;
            s1_sof <= in_sof; s1_eol <= in_eol; s1_eof <= in_eof; s1_x <= in_x; s1_y <= in_y;
        end
    end

    // ---------------- stage 2 : combine, de-gate
    wire s1_hit = s1_de & s1_c_rmin & s1_c_rg & s1_c_rb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de <= 1'b0; out_hit <= 1'b0; out_x <= 12'd0; out_y <= 12'd0;
            out_sof <= 1'b0; out_eol <= 1'b0; out_eof <= 1'b0;
        end
        else begin
            out_de  <= s1_de;
            out_hit <= s1_hit;
            out_x   <= s1_de ? s1_x : 12'd0;
            out_y   <= s1_de ? s1_y : 12'd0;
            out_sof <= s1_de & s1_sof;
            out_eol <= s1_de & s1_eol;
            out_eof <= s1_de & s1_eof;
        end
    end

endmodule
