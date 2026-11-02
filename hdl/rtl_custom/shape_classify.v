// shape_classify.v - coarse shape class of one detected target from its bounding box and pixel count
//
// Inputs are the per-frame statistics of frame_bbox (valid, count, xmin..ymax), which hold their value for a whole frame.
//   w = xmax - xmin + 1,  h = ymax - ymin + 1,  area = w*h,  fill = count / area   (compared as count*16 vs area*k)
//   fill >= 14/16 (0.875)                   -> RECT      (a filled axis-aligned rectangle / square has fill ~1.0)
//   11/16 <= fill < 14/16 (0.69 .. 0.875)   -> CIRC if 3/4 <= w/h <= 4/3, otherwise OVAL   (circle / ellipse: pi/4 = 0.785)
//    6/16 <= fill < 10/16 (0.375 .. 0.625)  -> TRI       (triangle / diamond: 0.5)
//   anything else                           -> OTHER
//   valid = 0                               -> NONE
// shape code: 0 NONE, 1 RECT, 2 CIRC, 3 TRI, 4 OVAL, 5 OTHER.
// Fixed latency 3 clocks from the inputs to 'shape'; no stall. Inputs may be changed at any time (the output simply
// follows, 3 clocks later). The class limits are design choices for clean coloured paper cut-outs seen head-on,
// NOT tuned on camera images: tilted shapes, partial occlusion and segmentation holes lower the fill ratio.
// Reset: active-low asynchronous.

module shape_classify (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        valid,
    input  wire [19:0] count,
    input  wire [11:0] xmin,
    input  wire [11:0] xmax,
    input  wire [11:0] ymin,
    input  wire [11:0] ymax,

    output reg  [2:0]  shape
);

    // stage 1: box size
    reg         v1;
    reg  [19:0] c1;
    reg  [12:0] w1, h1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; c1 <= 20'd0; w1 <= 13'd0; h1 <= 13'd0;
        end
        else begin
            v1 <= valid;
            c1 <= count;
            w1 <= {1'b0, xmax} - {1'b0, xmin} + 13'd1;
            h1 <= {1'b0, ymax} - {1'b0, ymin} + 13'd1;
        end
    end

    // stage 2: area
    reg         v2;
    reg  [19:0] c2;
    reg  [12:0] w2, h2;
    reg  [25:0] a2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v2 <= 1'b0; c2 <= 20'd0; w2 <= 13'd0; h2 <= 13'd0; a2 <= 26'd0;
        end
        else begin
            v2 <= v1; c2 <= c1; w2 <= w1; h2 <= h1;
            a2 <= w1 * h1;
        end
    end

    // stage 3: fill-ratio and aspect tests
    wire [29:0] c16 = {6'd0, c2, 4'd0};
    wire [29:0] a   = {4'd0, a2};
    wire [29:0] a14 = (a << 4) - (a << 1);
    wire [29:0] a11 = (a << 3) + (a << 1) + a;
    wire [29:0] a10 = (a << 3) + (a << 1);
    wire [29:0] a6  = (a << 2) + (a << 1);

    wire is_rect = (c16 >= a14);
    wire is_circ = (c16 >= a11) & (c16 < a14);
    wire is_tri  = (c16 >= a6)  & (c16 < a10);
    wire aspect  = ({w2, 2'b00} >= ({h2, 1'b0} + h2)) & ({h2, 2'b00} >= ({w2, 1'b0} + w2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) shape <= 3'd0;
        else if (!v2)    shape <= 3'd0;
        else if (is_rect) shape <= 3'd1;
        else if (is_circ) shape <= aspect ? 3'd2 : 3'd4;
        else if (is_tri)  shape <= 3'd3;
        else              shape <= 3'd5;
    end

endmodule
