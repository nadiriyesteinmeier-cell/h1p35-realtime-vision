// color_segment.v
//
// Fixed-threshold red-marker segmentation with a rectangular ROI.
//
// hit (per pixel) =  in_de
//                 && X0 <= x < X1 && Y0 <= y < Y1          (half-open ROI)
//                 && R >= R_MIN
//                 && R >= G + DELTA
//                 && R >= B + DELTA
//
// Parameters (compile-time only in this batch; no adaptive logic yet):
//   R_MIN  default 80    valid 0..1023 (>255 means "never hits")
//   DELTA  default 30    valid 0..1023 (>255 means "never hits")
//   X0,X1,Y0,Y1  default full 1280x720 image. X1/Y1 are 13 bit so X1 = 4096
//                is expressible. X0 >= X1 or Y0 >= Y1 gives an empty ROI.
//   For a different frame size override X1/Y1 (e.g. 8x6 -> X1=8, Y1=6).
//
// Widths: G+DELTA and B+DELTA are computed in 11 bit (max 255+1023 = 1278),
// so an 8-bit wrap such as G=226, DELTA=30 (sum 256) can never create a false
// hit. All comparisons are between unsigned vectors of equal width.
//
// Interface / timing:
//   - Same normalized pixel interface as rgb_to_gray (one pixel per clock, no
//     stall, canonical RGB order [23:16]=R [15:8]=G [7:0]=B).
//   - Fixed latency LATENCY = 2 clocks for every output.
//       stage 1 (reg): four condition bits (R>=R_MIN, R>=G+DELTA, R>=B+DELTA,
//                      in ROI) + delayed rgb / de / x / y / sof / eol / eof
//       stage 2 (reg): out_hit = de & all four conditions, outputs de-gated
//   - out_rgb  : original RGB delayed by LATENCY (for later overlay / OSD)
//   - out_mask : hit ? 24'hFFFFFF : 24'h000000 (combinational from out_hit)
//   - When out_de = 0 every output is 0 (hit, rgb, mask, x, y, sof/eol/eof).
//
// Reset: active-low asynchronous, release must be synchronized to clk by the
// integrator. Reset has priority; all registers clear to 0.

module color_segment #(
    parameter [9:0]  R_MIN = 10'd80,
    parameter [9:0]  DELTA = 10'd30,
    parameter [12:0] X0    = 13'd0,
    parameter [12:0] X1    = 13'd1280,
    parameter [12:0] Y0    = 13'd0,
    parameter [12:0] Y1    = 13'd720
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_de,
    input  wire [23:0] in_rgb,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,

    output reg         out_de,
    output reg         out_hit,
    output reg  [23:0] out_rgb,
    output wire [23:0] out_mask,
    output reg  [11:0] out_x,
    output reg  [11:0] out_y,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof
);

    localparam LATENCY = 2;

    // ---------------- stage 1 : conditions ----------------
    wire [10:0] s0_r  = {3'b000, in_rgb[23:16]};
    wire [10:0] s0_gd = {3'b000, in_rgb[15:8]} + {1'b0, DELTA};
    wire [10:0] s0_bd = {3'b000, in_rgb[7:0]}  + {1'b0, DELTA};

    wire        s0_c_rmin = (s0_r >= {1'b0, R_MIN});
    wire        s0_c_rg   = (s0_r >= s0_gd);
    wire        s0_c_rb   = (s0_r >= s0_bd);

    wire [12:0] s0_x13 = {1'b0, in_x};
    wire [12:0] s0_y13 = {1'b0, in_y};
    wire        s0_c_roi = (s0_x13 >= X0) && (s0_x13 < X1) &&
                           (s0_y13 >= Y0) && (s0_y13 < Y1);

    reg         s1_de;
    reg         s1_c_rmin;
    reg         s1_c_rg;
    reg         s1_c_rb;
    reg         s1_c_roi;
    reg  [23:0] s1_rgb;
    reg  [11:0] s1_x;
    reg  [11:0] s1_y;
    reg         s1_sof;
    reg         s1_eol;
    reg         s1_eof;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_de     <= 1'b0;
            s1_c_rmin <= 1'b0;
            s1_c_rg   <= 1'b0;
            s1_c_rb   <= 1'b0;
            s1_c_roi  <= 1'b0;
            s1_rgb    <= 24'd0;
            s1_x      <= 12'd0;
            s1_y      <= 12'd0;
            s1_sof    <= 1'b0;
            s1_eol    <= 1'b0;
            s1_eof    <= 1'b0;
        end
        else begin
            s1_de     <= in_de;
            s1_c_rmin <= s0_c_rmin;
            s1_c_rg   <= s0_c_rg;
            s1_c_rb   <= s0_c_rb;
            s1_c_roi  <= s0_c_roi;
            s1_rgb    <= in_rgb;
            s1_x      <= in_x;
            s1_y      <= in_y;
            s1_sof    <= in_sof;
            s1_eol    <= in_eol;
            s1_eof    <= in_eof;
        end
    end

    // ---------------- stage 2 : combine, de-gate ----------------
    wire s1_hit = s1_de & s1_c_rmin & s1_c_rg & s1_c_rb & s1_c_roi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de  <= 1'b0;
            out_hit <= 1'b0;
            out_rgb <= 24'd0;
            out_x   <= 12'd0;
            out_y   <= 12'd0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
        end
        else begin
            out_de  <= s1_de;
            out_hit <= s1_hit;
            out_rgb <= s1_de ? s1_rgb : 24'd0;
            out_x   <= s1_de ? s1_x   : 12'd0;
            out_y   <= s1_de ? s1_y   : 12'd0;
            out_sof <= s1_de & s1_sof;
            out_eol <= s1_de & s1_eol;
            out_eof <= s1_de & s1_eof;
        end
    end

    assign out_mask = out_hit ? 24'hFFFFFF : 24'h000000;

endmodule
