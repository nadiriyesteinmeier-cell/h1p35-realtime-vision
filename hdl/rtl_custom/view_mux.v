// view_mux.v - selects which picture goes to the display
//
//   mode 0 : rgb_orig                          (original video)
//   mode 1 : rgb_gray                          (e.g. rgb_to_gray.out_rgb)
//   mode 2 : rgb_mask                          (e.g. color_segment.out_mask)
//   mode 3 : hit ? TINT_COLOR : rgb_orig       (original video with the detected target painted)
//
// All data inputs and the sideband must already be ALIGNED with each other by the integrator
// (e.g. delay the original RGB with sync_delay by the 2 clocks of rgb_to_gray / color_segment).
// Registered output, fixed latency 1 clock; sideband delayed by the same clock.
// out_de = 0 forces every output to 0. mode is sampled every clock (switch it during blanking
// if a tear-free change is wanted). Reset: active-low asynchronous.

module view_mux #(
    parameter [23:0] TINT_COLOR = 24'hFF00FF
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_de,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,
    input  wire [23:0] rgb_orig,
    input  wire [23:0] rgb_gray,
    input  wire [23:0] rgb_mask,
    input  wire        hit,
    input  wire [1:0]  mode,

    output reg         out_de,
    output reg  [23:0] out_rgb,
    output reg  [11:0] out_x,
    output reg  [11:0] out_y,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof
);

    localparam LATENCY = 1;

    reg [23:0] sel;
    always @* begin
        case (mode)
            2'd0:    sel = rgb_orig;
            2'd1:    sel = rgb_gray;
            2'd2:    sel = rgb_mask;
            default: sel = hit ? TINT_COLOR : rgb_orig;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de  <= 1'b0;  out_rgb <= 24'd0;
            out_x   <= 12'd0; out_y   <= 12'd0;
            out_sof <= 1'b0;  out_eol <= 1'b0;  out_eof <= 1'b0;
        end
        else begin
            out_de  <= in_de;
            out_rgb <= in_de ? sel : 24'd0;
            out_x   <= in_de ? in_x : 12'd0;
            out_y   <= in_de ? in_y : 12'd0;
            out_sof <= in_de & in_sof;
            out_eol <= in_de & in_eol;
            out_eof <= in_de & in_eof;
        end
    end

endmodule
