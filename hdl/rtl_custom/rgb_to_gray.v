// rgb_to_gray.v
//
// Integer luma:  Y = floor((77*R + 150*G + 29*B) / 256)
//
// Contract (normalized pixel interface, see docs/ALGORITHM_INTERFACE.md):
//   - One clock = at most one pixel. No ready/stall input; no pixel is ever dropped.
//   - in_rgb is [23:16]=R, [15:8]=G, [7:0]=B (canonical order; the vendor
//     baseline order is NOT verified by this module).
//   - in_sof / in_eol / in_eof are only meaningful while in_de = 1.
//   - Fixed latency: LATENCY = 2 clocks from any input pixel to its output.
//     Every output (gray, rgb, x, y, sof, eol, eof, de) is delayed by exactly
//     the same 2 clocks, so they stay aligned with each other.
//   - When out_de = 0 every payload/sideband output is 0 (blanking is clean).
//
// Arithmetic widths:
//   77*255 = 19635, 150*255 = 38250, 29*255 = 7395  -> each product < 2^16
//   max sum = 65280 = 255*256                        -> fits in 16 bit, a
//   17-bit adder is used so no overflow reasoning is needed.
//   floor(sum/256) is simply sum[15:8]; no divider, no real, no rounding.
//   Known values: black 0, red 76, green 149, blue 28, white 255,
//   and (v,v,v) -> v for every v because 77+150+29 = 256.
//
// Reset: active-low asynchronous (rst_n). Release must be synchronized to clk
// by the integrator. Reset has priority over data; all registers clear to 0,
// so a pixel in flight when reset hits is discarded.
//
// Pipeline:
//   stage 0 (input)  : in_*
//   stage 1 (reg)    : three constant products + delayed sideband
//   stage 2 (reg)    : 17-bit sum -> Y, de-gated outputs

module rgb_to_gray (
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
    output reg  [7:0]  out_gray,
    output wire [23:0] out_rgb,     // {Y,Y,Y}
    output reg  [11:0] out_x,
    output reg  [11:0] out_y,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof
);

    localparam LATENCY = 2;

    // ---------------- stage 1 ----------------
    wire [7:0]  s0_r = in_rgb[23:16];
    wire [7:0]  s0_g = in_rgb[15:8];
    wire [7:0]  s0_b = in_rgb[7:0];

    wire [15:0] s0_pr = {8'd0, s0_r} * 16'd77;
    wire [15:0] s0_pg = {8'd0, s0_g} * 16'd150;
    wire [15:0] s0_pb = {8'd0, s0_b} * 16'd29;

    reg         s1_de;
    reg  [15:0] s1_pr;
    reg  [15:0] s1_pg;
    reg  [15:0] s1_pb;
    reg  [11:0] s1_x;
    reg  [11:0] s1_y;
    reg         s1_sof;
    reg         s1_eol;
    reg         s1_eof;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_de  <= 1'b0;
            s1_pr  <= 16'd0;
            s1_pg  <= 16'd0;
            s1_pb  <= 16'd0;
            s1_x   <= 12'd0;
            s1_y   <= 12'd0;
            s1_sof <= 1'b0;
            s1_eol <= 1'b0;
            s1_eof <= 1'b0;
        end
        else begin
            s1_de  <= in_de;
            s1_pr  <= s0_pr;
            s1_pg  <= s0_pg;
            s1_pb  <= s0_pb;
            s1_x   <= in_x;
            s1_y   <= in_y;
            s1_sof <= in_sof;
            s1_eol <= in_eol;
            s1_eof <= in_eof;
        end
    end

    // ---------------- stage 2 ----------------
    wire [16:0] s1_sum = {1'b0, s1_pr} + {1'b0, s1_pg} + {1'b0, s1_pb};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de   <= 1'b0;
            out_gray <= 8'd0;
            out_x    <= 12'd0;
            out_y    <= 12'd0;
            out_sof  <= 1'b0;
            out_eol  <= 1'b0;
            out_eof  <= 1'b0;
        end
        else begin
            out_de   <= s1_de;
            out_gray <= s1_de ? s1_sum[15:8] : 8'd0;
            out_x    <= s1_de ? s1_x         : 12'd0;
            out_y    <= s1_de ? s1_y         : 12'd0;
            out_sof  <= s1_de & s1_sof;
            out_eol  <= s1_de & s1_eol;
            out_eof  <= s1_de & s1_eof;
        end
    end

    assign out_rgb = {out_gray, out_gray, out_gray};

endmodule
