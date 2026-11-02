// he_eq.v - histogram equalisation of the brightness (contest advanced item 5: AE / AWB / histogram equalisation), HIST EQ page
//
// Statistics: on the position-aligned read-out stream (video_pos_adapter: de / x / y / rgb) every pixel with x and y even is a sample
// (640 x 360 = 230400 per frame); its brightness Y = (R + 2G + B) / 4 is counted in a 256-bin histogram (18-bit bins).
// At the last pixel of the frame the mapping is rebuilt in the vertical blanking (256 bins, one per clock, 3-stage pipeline):
//   cdf(v) = sum of bins 0..v,  lut(v) = min(255, (cdf(v) * K + 2^25) >> 26),  K = 74274 = 255 * 2^26 / 230400 (rounded up)
// the bin is cleared for the next frame, and a bar height min(127, bin >> 5) is kept for the graph.
// Apply (in_vs / in_de / in_data stream, any sync polarity, LAT = 2 clocks, only while enable = 1 and a mapping exists):
//   Y = (R + 2G + B) / 4;  every channel c' = clamp(c + lut(Y) - Y)   (the brightness is equalised, the colour differences are kept)
// and a 256 x 128 graph at (GX, GY): darkened field, last frame's histogram as grey bars, the mapping lut(v) / 2 as a yellow curve.
// Memories are small LUT RAMs (asynchronous read): histogram 256 x 18, mapping 256 x 8 (2 read ports), bar heights 256 x 7; no ERAM.
// The histogram RAM has no reset: the first build after reset only clears it, the mapping is used from the second build on.

module he_eq #(
    parameter [11:0] GX = 12'd16,
    parameter [11:0] GY = 12'd584
)(
    input  wire         clk,
    input  wire         rst_n,
    // statistics stream
    input  wire         s_de,
    input  wire [11:0]  s_x,
    input  wire [11:0]  s_y,
    input  wire [23:0]  s_rgb,
    // display stream
    input  wire         enable,
    input  wire         in_vs,
    input  wire         in_de,
    input  wire [23:0]  in_data,
    output reg          out_vs,
    output reg          out_de,
    output reg  [23:0]  out_data
);
    localparam [16:0] K = 17'd74274;

    function [7:0] luma;
        input [23:0] p;
        reg [9:0] s;
        begin
            s = {2'b00, p[23:16]} + {1'b0, p[15:8], 1'b0} + {2'b00, p[7:0]};
            luma = s[9:2];
        end
    endfunction

    // ------------------------------------------------------------------ histogram (one port: count during the frame, read + clear while building)
    reg  [17:0] hist [0:255];
    reg  [7:0]  lut  [0:255];
    reg  [6:0]  bar  [0:255];
    reg  [1:0]  bst;                    // 0 idle, 1 building
    reg  [8:0]  bv;                     // bin being read (stage 1)
    wire        samp  = s_de && !s_x[0] && !s_y[0] && (bst == 2'd0);
    wire [7:0]  ybin  = luma(s_rgb);
    wire [7:0]  haddr = (bst != 2'd0) ? bv[7:0] : ybin;
    wire [17:0] hq    = hist[haddr];
    wire        eof   = s_de && (s_x == 12'd1279) && (s_y == 12'd719);
    always @(posedge clk) begin
        if (samp)                          hist[haddr] <= hq + 18'd1;
        else if (bst != 2'd0 && !bv[8])    hist[haddr] <= 18'd0;
    end

    // build pipeline: stage 1 cdf, stage 2 product, stage 3 write
    reg  [17:0] cdf;
    reg         p1_v, p2_v;
    reg  [7:0]  p1_a, p2_a;
    reg  [17:0] p1_cdf;
    reg  [6:0]  p1_bar;
    reg  [34:0] p2_prod;
    reg         lut_ok;
    reg         first_done;
    wire [17:0] cdf_n = cdf + hq;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin bst <= 2'd0; bv <= 9'd0; cdf <= 18'd0; p1_v <= 1'b0; p2_v <= 1'b0; lut_ok <= 1'b0; first_done <= 1'b0; end
        else begin
            p1_v <= 1'b0;
            if (bst == 2'd0) begin
                if (eof) begin bst <= 2'd1; bv <= 9'd0; cdf <= 18'd0; end
            end
            else if (!bv[8]) begin
                cdf <= cdf_n;
                p1_v <= 1'b1;
                bv <= bv + 9'd1;
            end
            else if (!p1_v && !p2_v) begin bst <= 2'd0; first_done <= 1'b1; lut_ok <= first_done; end
            p2_v <= p1_v;
        end
    end
    always @(posedge clk) begin
        p1_a <= bv[7:0]; p1_cdf <= cdf_n; p1_bar <= (hq[17:12] != 6'd0) ? 7'd127 : hq[11:5];
        p2_a <= p1_a; p2_prod <= p1_cdf * K + 35'd33554432;
        if (p1_v) bar[p1_a] <= p1_bar;
        if (p2_v) lut[p2_a] <= (p2_prod[34:26] > 9'd255) ? 8'd255 : p2_prod[33:26];
    end

    // ------------------------------------------------------------------ display: x / y counters
    reg [11:0] x, y;
    reg        vs_q, de_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin x <= 12'd0; y <= 12'd0; vs_q <= 1'b0; de_q <= 1'b0; end
        else begin
            vs_q <= in_vs; de_q <= in_de;
            if (in_vs != vs_q) y <= 12'd0;
            else if (de_q & ~in_de) y <= y + 12'd1;
            if (in_de) x <= x + 12'd1;
            else x <= 12'd0;
        end
    end
    reg en_f;                           // enable taken once per frame
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) en_f <= 1'b0;
        else if (in_vs != vs_q) en_f <= enable && lut_ok;
    end

    // stage 1: mapping, graph hit tests
    wire [7:0]  yv   = luma(in_data);
    wire [7:0]  ly   = lut[yv];
    wire [11:0] gdx  = x - GX;
    wire [11:0] gdy  = y - GY;
    wire        g_in = (x >= GX) && (gdx < 12'd256) && (y >= GY) && (gdy < 12'd128);
    wire [6:0]  hgt  = 7'd127 - gdy[6:0];                       // height above the graph floor
    wire [6:0]  gb   = bar[gdx[7:0]];
    wire [7:0]  gl   = lut[gdx[7:0]];
    wire [6:0]  gc   = gl[7:1];                                 // curve height = lut / 2
    reg         s1_de, s1_vs, s1_g, s1_bar, s1_cur;
    reg [23:0]  s1_d;
    reg [8:0]   s1_dy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s1_de <= 1'b0; s1_vs <= 1'b0; end
        else begin s1_de <= in_de; s1_vs <= in_vs; end
    end
    always @(posedge clk) begin
        s1_d <= in_data;
        s1_dy <= {1'b0, ly} - {1'b0, yv};
        s1_g <= en_f && g_in;
        s1_bar <= (hgt < gb);
        s1_cur <= (hgt == gc) || ({1'b0, hgt} == {1'b0, gc} + 8'd1);     // 8 bits: gc = 127 must not wrap to the floor
    end

    // stage 2: apply, draw
    function [7:0] addc;                // clamp(c + d), d = 9-bit two's complement
        input [7:0] c;
        input [8:0] d;
        reg   [9:0] t;
        begin
            t = {2'b00, c} + {d[8], d};
            addc = t[9] ? 8'd0 : t[8] ? 8'd255 : t[7:0];
        end
    endfunction
    wire [23:0] v_eq = en_f ? {addc(s1_d[23:16], s1_dy), addc(s1_d[15:8], s1_dy), addc(s1_d[7:0], s1_dy)} : s1_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin out_de <= 1'b0; out_vs <= 1'b0; end
        else begin out_de <= s1_de; out_vs <= s1_vs; end
    end
    always @(posedge clk) begin
        if (s1_g && s1_cur)      out_data <= 24'hFFE000;
        else if (s1_g && s1_bar) out_data <= 24'hB0B0B0;
        else if (s1_g)           out_data <= {1'b0, v_eq[23:17], 1'b0, v_eq[15:9], 1'b0, v_eq[7:1]};
        else                     out_data <= v_eq;
    end
endmodule
