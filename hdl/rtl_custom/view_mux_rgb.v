// view_mux_rgb.v - display selection for the three-colour recognition path
//
//   mode 0 : rgb_orig                                           (original video)
//   mode 1 : rgb_gray                                           (gray video)
//   mode 2 : colour-coded mask: {hit_r ? FF : 00, hit_g ? FF : 00, hit_b ? FF : 00}   (red / green / blue targets on black;
//            a pixel claimed by two colours shows their mix)
//   mode 3 : original video with every detected pixel painted in its own saturated colour
//            (red FF3030, green 30FF30, blue 3050FF; priority red > green > blue)
//
// Like view_mux.v: all data inputs and the sideband must already be aligned, registered output with fixed latency
// 1 clock, out_de = 0 forces every output to 0, mode is sampled every clock, reset is active-low asynchronous.

module view_mux_rgb (
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
    input  wire        hit_r,
    input  wire        hit_g,
    input  wire        hit_b,
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

    wire [23:0] mask = {hit_r ? 8'hFF : 8'h00, hit_g ? 8'hFF : 8'h00, hit_b ? 8'hFF : 8'h00};
    wire [23:0] tint = hit_r ? 24'hFF3030 : hit_g ? 24'h30FF30 : hit_b ? 24'h3050FF : rgb_orig;

    reg [23:0] sel;
    always @* begin
        case (mode)
            2'd0:    sel = rgb_orig;
            2'd1:    sel = rgb_gray;
            2'd2:    sel = mask;
            default: sel = tint;
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
