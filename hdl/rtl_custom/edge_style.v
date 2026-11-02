// edge_style.v - Sobel edge detection on the gray stream, with two inferred line buffers (block RAM)
//
// For every pixel of the incoming stream the module outputs, 3 clocks later, the SAME pixel's sideband together with
//   out_edge : 1 when the Sobel magnitude |Gx| + |Gy| of the 3x3 neighbourhood CENTRED ON THE PIXEL ONE COLUMN LEFT AND
//              ONE ROW ABOVE (x-1, y-1) is greater than 'thr'   (a window needs the next row, so the picture of the edge
//              map is shifted by one pixel diagonally relative to the stream position; harmless for display)
//   out_gray / out_rgb : the input gray / rgb delayed by the same 3 clocks (for the style views)
// No edge is reported for the first two columns and the first two rows of a frame (the window is not complete there).
//
//   Gx = (R3 + 2*R2' + R1'') ..., classical Sobel:  Gx = [ -1 0 1; -2 0 2; -1 0 1 ],  Gy = [ -1 -2 -1; 0 0 0; 1 2 1 ]
//   magnitude = |Gx| + |Gy| (0..2040), compared with the 11-bit threshold 'thr' (sampled every clock).
//
// Line buffers: two 2048 x 8 bit RAMs addressed by in_x, written one clock after they are read (so read-before-write
// order never matters); they keep the previous two rows of the frame. Everything runs at one pixel per clock; the window
// only advances on clocks with in_de = 1, so line blanking of any length is allowed.
// Fixed latency 3 clocks, all outputs 0 while out_de = 0. Reset: active-low asynchronous (the RAMs themselves are not
// reset: rows that were never written are only read inside the masked border).

module edge_style (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_de,
    input  wire [7:0]  in_gray,
    input  wire [23:0] in_rgb,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,

    input  wire [10:0] thr,

    output reg         out_de,
    output reg         out_edge,
    output reg  [7:0]  out_gray,
    output reg  [23:0] out_rgb,
    output reg  [11:0] out_x,
    output reg  [11:0] out_y,
    output reg         out_sof,
    output reg         out_eol,
    output reg         out_eof
);

    localparam LATENCY = 3;

    // ---------------- line buffers (simple dual port, synchronous read)
    (* ram_style = "bram" *) reg [7:0] mem1 [0:2047];
    (* ram_style = "bram" *) reg [7:0] mem2 [0:2047];
    reg  [7:0]  lb1_q, lb2_q;                 // rows y-1 and y-2 at address in_x (valid one clock after the read)

    // stage 1 registers (also the write side)
    reg         s1_de, s1_sof, s1_eol, s1_eof;
    reg  [7:0]  s1_gray;
    reg  [23:0] s1_rgb;
    reg  [11:0] s1_x, s1_y;

    always @(posedge clk) begin
        lb1_q <= mem1[in_x[10:0]];
        lb2_q <= mem2[in_x[10:0]];
        if (s1_de) begin
            mem1[s1_x[10:0]] <= s1_gray;
            mem2[s1_x[10:0]] <= lb1_q;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_de <= 1'b0; s1_sof <= 1'b0; s1_eol <= 1'b0; s1_eof <= 1'b0;
            s1_gray <= 8'd0; s1_rgb <= 24'd0; s1_x <= 12'd0; s1_y <= 12'd0;
        end
        else begin
            s1_de <= in_de; s1_sof <= in_de & in_sof; s1_eol <= in_de & in_eol; s1_eof <= in_de & in_eof;
            s1_gray <= in_gray; s1_rgb <= in_rgb; s1_x <= in_x; s1_y <= in_y;
        end
    end

    // ---------------- stage 2: window of three columns {row y-2, row y-1, row y}
    reg  [23:0] w0, w1, w2;                   // x-2, x-1, x   (each {top, mid, bottom})
    reg         s2_de, s2_sof, s2_eol, s2_eof;
    reg  [7:0]  s2_gray;
    reg  [23:0] s2_rgb;
    reg  [11:0] s2_x, s2_y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w0 <= 24'd0; w1 <= 24'd0; w2 <= 24'd0;
            s2_de <= 1'b0; s2_sof <= 1'b0; s2_eol <= 1'b0; s2_eof <= 1'b0;
            s2_gray <= 8'd0; s2_rgb <= 24'd0; s2_x <= 12'd0; s2_y <= 12'd0;
        end
        else begin
            if (s1_de) begin
                w0 <= w1;
                w1 <= w2;
                w2 <= {lb2_q, lb1_q, s1_gray};
            end
            s2_de <= s1_de; s2_sof <= s1_sof; s2_eol <= s1_eol; s2_eof <= s1_eof;
            s2_gray <= s1_gray; s2_rgb <= s1_rgb; s2_x <= s1_x; s2_y <= s1_y;
        end
    end

    // Sobel on the registered window
    wire [10:0] a0 = {3'b000, w0[23:16]};  wire [10:0] b0 = {3'b000, w0[15:8]};  wire [10:0] c0 = {3'b000, w0[7:0]};
    wire [10:0] a1 = {3'b000, w1[23:16]};  wire [10:0] c1 = {3'b000, w1[7:0]};
    wire [10:0] a2 = {3'b000, w2[23:16]};  wire [10:0] b2 = {3'b000, w2[15:8]};  wire [10:0] c2 = {3'b000, w2[7:0]};

    wire [11:0] gx_p = {1'b0, a2} + {b2, 1'b0} + {1'b0, c2};
    wire [11:0] gx_n = {1'b0, a0} + {b0, 1'b0} + {1'b0, c0};
    wire [11:0] gy_p = {1'b0, c0} + {c1, 1'b0} + {1'b0, c2};
    wire [11:0] gy_n = {1'b0, a0} + {a1, 1'b0} + {1'b0, a2};
    wire [11:0] gx   = (gx_p >= gx_n) ? (gx_p - gx_n) : (gx_n - gx_p);
    wire [11:0] gy   = (gy_p >= gy_n) ? (gy_p - gy_n) : (gy_n - gy_p);
    wire [12:0] mag  = {1'b0, gx} + {1'b0, gy};

    wire        full = s2_de & (s2_x >= 12'd2) & (s2_y >= 12'd2);
    wire        is_edge = full & (mag > {2'b00, thr});

    // ---------------- stage 3: outputs, de-gated
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_de <= 1'b0; out_edge <= 1'b0; out_gray <= 8'd0; out_rgb <= 24'd0;
            out_x <= 12'd0; out_y <= 12'd0; out_sof <= 1'b0; out_eol <= 1'b0; out_eof <= 1'b0;
        end
        else begin
            out_de   <= s2_de;
            out_edge <= is_edge;
            out_gray <= s2_de ? s2_gray : 8'd0;
            out_rgb  <= s2_de ? s2_rgb  : 24'd0;
            out_x    <= s2_de ? s2_x : 12'd0;
            out_y    <= s2_de ? s2_y : 12'd0;
            out_sof  <= s2_de & s2_sof;
            out_eol  <= s2_de & s2_eol;
            out_eof  <= s2_de & s2_eof;
        end
    end

endmodule
