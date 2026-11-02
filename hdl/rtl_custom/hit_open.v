// hit_open.v - horizontal noise filter for a hit stream: removes every run of hit pixels shorter than RUN
//
// A pixel of the output is a hit iff it belongs to a run of at least RUN consecutive hit pixels in its own line (a 1-D
// morphological opening = erosion + dilation). Runs of RUN or more pixels pass unchanged (exact edges), isolated pixels,
// short speckles and thin vertical streaks (one pixel wide in every row) disappear. That keeps single noisy pixels from
// stretching the bounding box of frame_bbox and from jumping the target centre.
//
// Streaming implementation: a window of 2*RUN-1 hit bits; the pixel in the middle of the window is the one being decided,
// so every output (hit AND the sideband) is delayed by exactly LATENCY = RUN clocks (the pixel needs RUN-1 more clocks to
// reach the middle of the window, plus the usual register stage):
//     out_hit(x) = OR over j = 0..RUN-1 of AND(window[j .. j+RUN-1])       (all RUN-long windows that contain x)
// Blanking: a pixel with in_de = 0 enters the window as 0, so runs never cross line ends (the line blanking is at least
// RUN-1 clocks long, so the last pixels of a line are decided with zeros as their "future"; the delayed out_de still marks
// them valid). The module needs at least RUN-1 clocks of de = 0 between lines (any real video timing has hundreds).
// All sideband outputs are 0 while out_de = 0. Reset: active-low asynchronous.

module hit_open #(
    parameter integer RUN = 5
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_de,
    input  wire        in_hit,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,

    output wire        out_de,
    output wire        out_hit,
    output wire [11:0] out_x,
    output wire [11:0] out_y,
    output wire        out_sof,
    output wire        out_eol,
    output wire        out_eof
);

    localparam integer LATENCY = RUN;
    localparam integer WW      = 2 * RUN - 1;

    // sideband delay line (LATENCY stages) of {de, x, y, sof, eol, eof}
    wire [27:0] side_in = {in_de, in_x, in_y, in_de & in_sof, in_de & in_eol, in_de & in_eof};
    wire [27:0] side_out;
    sync_delay #(.N(LATENCY), .W(28)) u_dly (.clk(clk), .rst_n(rst_n), .din(side_in), .dout(side_out));

    reg [WW-1:0] hw;                          // hw[0] newest ... hw[WW-1] oldest; hw[RUN-1] is the pixel being decided
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hw <= {WW{1'b0}};
        else        hw <= {hw[WW-2:0], in_de & in_hit};
    end

    // OR over the RUN windows hw[j +: RUN], j = 0..RUN-1, of the AND of the window
    reg any;
    integer j, k;
    reg all;
    always @* begin
        any = 1'b0;
        for (j = 0; j < RUN; j = j + 1) begin
            all = 1'b1;
            for (k = 0; k < RUN; k = k + 1) all = all & hw[j + k];
            any = any | all;
        end
    end

    assign out_de  = side_out[27];
    assign out_hit = out_de & any;
    assign out_x   = side_out[26:15];
    assign out_y   = side_out[14:3];
    assign out_sof = side_out[2];
    assign out_eol = side_out[1];
    assign out_eof = side_out[0];

endmodule
