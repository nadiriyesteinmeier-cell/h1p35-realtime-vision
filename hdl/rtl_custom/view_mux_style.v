// view_mux_style.v - display selection of the v2 build: 8 views in two pages
//
//   page 0 (analysis views)                                      page 1 (style views)
//     mode 0 : original video                                      mode 0 : SKETCH   - dark edges on shaded paper
//     mode 1 : gray video                                          mode 1 : CARTOON  - 8-level posterized colours, black edges
//     mode 2 : colour-coded mask  (R / G / B hits on black)        mode 2 : EDGE+    - dimmed video, edges drawn in green
//     mode 3 : original with the detected targets painted          mode 3 : THERMAL  - pseudo-colour (blue-cyan-green-yellow-red) of the gray value
//
// All data inputs and the sideband must already be aligned with each other (the edge_style outputs are: rgb, gray and edge
// share its 3-clock latency; the three hit flags have to be delayed by the integrator by the same amount).
// Registered output, fixed latency 1 clock; out_de = 0 forces every output to 0. page / mode are sampled every clock.
// Reset: active-low asynchronous.

module view_mux_style (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_de,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,
    input  wire [23:0] rgb_orig,
    input  wire [7:0]  gray,
    input  wire        edge_px,
    input  wire        hit_r,
    input  wire        hit_g,
    input  wire        hit_b,
    input  wire        page,
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

    wire [23:0] gray_rgb = {gray, gray, gray};
    wire [23:0] mask     = {hit_r ? 8'hFF : 8'h00, hit_g ? 8'hFF : 8'h00, hit_b ? 8'hFF : 8'h00};
    wire [23:0] tint     = hit_r ? 24'hFF3030 : hit_g ? 24'h30FF30 : hit_b ? 24'h3050FF : rgb_orig;

    // Bin centres (16,48,...,240) keep quantization error <=16 and preserve shadows.
    wire [23:0] poster = {rgb_orig[23:21], 5'b10000, rgb_orig[15:13], 5'b10000, rgb_orig[7:5], 5'b10000};
    wire [7:0] paper = 8'd96 + {1'b0, gray[7:1]};  // 96..223: visible shading, no uniform white fill
    wire [23:0] dim_rgb = {1'b0, rgb_orig[23:17], 1'b0, rgb_orig[15:9], 1'b0, rgb_orig[7:1]};

    // pseudo-colour of the gray value v:  blue -> cyan -> green -> yellow -> red
    reg [7:0] tr, tg, tb;
    always @* begin
        if (gray < 8'd64)       begin tr = 8'd0;                          tg = {gray[5:0], 2'b00};              tb = 8'd255; end
        else if (gray < 8'd128) begin tr = 8'd0;                          tg = 8'd255;                          tb = 8'd255 - {gray[5:0], 2'b00}; end
        else if (gray < 8'd192) begin tr = {gray[5:0], 2'b00};            tg = 8'd255;                          tb = 8'd0; end
        else                    begin tr = 8'd255;                        tg = 8'd255 - {gray[5:0], 2'b00};     tb = 8'd0; end
    end
    wire [23:0] thermal = {tr, tg, tb};

    reg [23:0] sel;
    always @* begin
        if (!page) begin
            case (mode)
                2'd0:    sel = rgb_orig;
                2'd1:    sel = gray_rgb;
                2'd2:    sel = mask;
                default: sel = tint;
            endcase
        end
        else begin
            case (mode)
                2'd0:    sel = edge_px ? 24'h101010 : {paper, paper, paper};
                2'd1:    sel = edge_px ? 24'h000000 : poster;
                2'd2:    sel = edge_px ? 24'h00FF80 : dim_rgb;
                default: sel = thermal;
            endcase
        end
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
