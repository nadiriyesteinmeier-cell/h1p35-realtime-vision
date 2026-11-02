// yolo_osd.v - overlay of the detector results on a 1280 x 720 video stream: class-coloured boxes, a tag "<R|G|B><score %>" above every box, and a status line
//
// Stream in: in_vs / in_de / in_data (24-bit RGB, [23:16] = R), any sync polarity: the line counter restarts at every vs edge (both edges lie in the vertical blanking).
// Stream out: the same stream, LAT = 3 clocks later, with the overlay drawn where enabled.
// Boxes: nbox (0..8) entries of boxes[60*i +: 60] = {cls[59:58], score[57:42] (Q16), x0[41:31], y0[30:21], x1[20:10], y1[9:0]} in frame pixels (yolo_decode output).
// Box border 2 pixels; tag 3 characters (class letter, two score digits) of 12 x 16 pixels (5 x 7 font, x2) on a filled class-coloured field, above the box (inside the
// box if it touches the top). Status line at (16, 688): "CV" / "YOLO" / "CV+YOLO" / "CAPTURE" + the detection rate, the latency and the box count (or the frame counter
// in capture mode).  Font and text are LUT logic (no block RAM). The geometry (box list, digits) is refreshed once per frame at the vs edge, so a frame never mixes two results.
// show_boxes / show_status come from the integrator (mode). Reset: control flags only.

module yolo_osd (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          in_vs,
    input  wire          in_de,
    input  wire [23:0]   in_data,
    output reg           out_vs,
    output reg           out_de,
    output reg  [23:0]   out_data,

    input  wire          show_boxes,
    input  wire          show_status,
    input  wire [1:0]    mode,
    input  wire [3:0]    nbox,
    input  wire [479:0]  boxes,
    input  wire [7:0]    det_rate,
    input  wire [7:0]    lat_ms,
    input  wire [15:0]   cap_count
);

    // ------------------------------------------------------------------ 5 x 7 font: code -> 7 rows of 5 bits (bit 4 = leftmost)
    // codes: 0..9 digits, 10 'A' .. 35 'Z', 36 space, 37 '+', 38 '=', 39 '/', 40 '%'
    function [34:0] glyph;
        input [5:0] c;
        begin
            case (c)
                6'd0:  glyph = {5'b01110, 5'b10001, 5'b10011, 5'b10101, 5'b11001, 5'b10001, 5'b01110};
                6'd1:  glyph = {5'b00100, 5'b01100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b01110};
                6'd2:  glyph = {5'b01110, 5'b10001, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b11111};
                6'd3:  glyph = {5'b11111, 5'b00010, 5'b00100, 5'b00010, 5'b00001, 5'b10001, 5'b01110};
                6'd4:  glyph = {5'b00010, 5'b00110, 5'b01010, 5'b10010, 5'b11111, 5'b00010, 5'b00010};
                6'd5:  glyph = {5'b11111, 5'b10000, 5'b11110, 5'b00001, 5'b00001, 5'b10001, 5'b01110};
                6'd6:  glyph = {5'b00110, 5'b01000, 5'b10000, 5'b11110, 5'b10001, 5'b10001, 5'b01110};
                6'd7:  glyph = {5'b11111, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b01000, 5'b01000};
                6'd8:  glyph = {5'b01110, 5'b10001, 5'b10001, 5'b01110, 5'b10001, 5'b10001, 5'b01110};
                6'd9:  glyph = {5'b01110, 5'b10001, 5'b10001, 5'b01111, 5'b00001, 5'b00010, 5'b01100};
                6'd10: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b11111, 5'b10001, 5'b10001, 5'b10001};   // A
                6'd11: glyph = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10001, 5'b10001, 5'b11110};   // B
                6'd12: glyph = {5'b01110, 5'b10001, 5'b10000, 5'b10000, 5'b10000, 5'b10001, 5'b01110};   // C
                6'd13: glyph = {5'b11100, 5'b10010, 5'b10001, 5'b10001, 5'b10001, 5'b10010, 5'b11100};   // D
                6'd14: glyph = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b11111};   // E
                6'd15: glyph = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b10000};   // F
                6'd16: glyph = {5'b01110, 5'b10001, 5'b10000, 5'b10111, 5'b10001, 5'b10001, 5'b01111};   // G
                6'd17: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b11111, 5'b10001, 5'b10001, 5'b10001};   // H
                6'd18: glyph = {5'b01110, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b01110};   // I
                6'd19: glyph = {5'b00111, 5'b00010, 5'b00010, 5'b00010, 5'b00010, 5'b10010, 5'b01100};   // J
                6'd20: glyph = {5'b10001, 5'b10010, 5'b10100, 5'b11000, 5'b10100, 5'b10010, 5'b10001};   // K
                6'd21: glyph = {5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b11111};   // L
                6'd22: glyph = {5'b10001, 5'b11011, 5'b10101, 5'b10101, 5'b10001, 5'b10001, 5'b10001};   // M
                6'd23: glyph = {5'b10001, 5'b10001, 5'b11001, 5'b10101, 5'b10011, 5'b10001, 5'b10001};   // N
                6'd24: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};   // O
                6'd25: glyph = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10000, 5'b10000, 5'b10000};   // P
                6'd26: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b10001, 5'b10101, 5'b10010, 5'b01101};   // Q
                6'd27: glyph = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10100, 5'b10010, 5'b10001};   // R
                6'd28: glyph = {5'b01111, 5'b10000, 5'b10000, 5'b01110, 5'b00001, 5'b00001, 5'b11110};   // S
                6'd29: glyph = {5'b11111, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100};   // T
                6'd30: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};   // U
                6'd31: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01010, 5'b00100};   // V
                6'd32: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b10101, 5'b10101, 5'b10101, 5'b01010};   // W
                6'd33: glyph = {5'b10001, 5'b10001, 5'b01010, 5'b00100, 5'b01010, 5'b10001, 5'b10001};   // X
                6'd34: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b01010, 5'b00100, 5'b00100, 5'b00100};   // Y
                6'd35: glyph = {5'b11111, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b10000, 5'b11111};   // Z
                6'd37: glyph = {5'b00000, 5'b00100, 5'b00100, 5'b11111, 5'b00100, 5'b00100, 5'b00000};   // +
                6'd38: glyph = {5'b00000, 5'b00000, 5'b11111, 5'b00000, 5'b11111, 5'b00000, 5'b00000};   // =
                6'd39: glyph = {5'b00001, 5'b00010, 5'b00010, 5'b00100, 5'b01000, 5'b01000, 5'b10000};   // /
                6'd40: glyph = {5'b11001, 5'b11010, 5'b00010, 5'b00100, 5'b01000, 5'b01011, 5'b10011};   // %
                default: glyph = 35'd0;
            endcase
        end
    endfunction
    function [4:0] glyph_row;
        input [5:0] c;
        input [2:0] r;
        reg [34:0] g;
        begin
            g = glyph(c);
            glyph_row = g[34 - 5 * r -: 5];
        end
    endfunction
    function [5:0] dig;                     // binary 0..9 -> code
        input [3:0] v;
        begin dig = {2'b00, v}; end
    endfunction

    // ------------------------------------------------------------------ x / y counters of the incoming stream
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
    wire frame_edge = (in_vs != vs_q);

    // ------------------------------------------------------------------ per-frame geometry (latched at the vs edge)
    reg [3:0]  fn;
    reg [10:0] bx0 [0:7], bx1 [0:7];
    reg [9:0]  by0 [0:7], by1 [0:7];
    reg [1:0]  bc  [0:7];
    reg [10:0] tx  [0:7];                   // tag origin
    reg [9:0]  ty  [0:7];
    reg [3:0]  td1 [0:7], td0 [0:7];        // score tens / ones
    reg        f_boxes, f_status;
    reg [1:0]  f_mode;
    reg [7:0]  f_rate, f_lat;
    reg [15:0] f_cap;
    reg [3:0]  f_n;
    integer i;
    reg [22:0] pct_w;
    reg [6:0]  pct;
    always @(posedge clk) begin
        if (frame_edge) begin
            fn <= (nbox > 4'd8) ? 4'd8 : nbox;
            f_boxes <= show_boxes; f_status <= show_status; f_mode <= mode; f_rate <= det_rate; f_lat <= lat_ms; f_cap <= cap_count; f_n <= nbox;
            for (i = 0; i < 8; i = i + 1) begin
                bc[i]  <= boxes[60*i+58 +: 2];
                bx0[i] <= boxes[60*i+31 +: 11]; by0[i] <= boxes[60*i+21 +: 10];
                bx1[i] <= boxes[60*i+10 +: 11]; by1[i] <= boxes[60*i +: 10];
                tx[i]  <= (boxes[60*i+31 +: 11] > 11'd1243) ? 11'd1243 : boxes[60*i+31 +: 11];
                ty[i]  <= (boxes[60*i+21 +: 10] >= 10'd18) ? (boxes[60*i+21 +: 10] - 10'd18) : (boxes[60*i+21 +: 10] + 10'd2);
                pct_w = ({7'd0, boxes[60*i+42 +: 16]} << 6) + ({7'd0, boxes[60*i+42 +: 16]} << 5) + ({7'd0, boxes[60*i+42 +: 16]} << 2);   // x 100 as shift-add (no DSP)
                pct = pct_w[22:16];
                td1[i] <= (pct >= 7'd90) ? 4'd9 : (pct >= 7'd80) ? 4'd8 : (pct >= 7'd70) ? 4'd7 : (pct >= 7'd60) ? 4'd6 : (pct >= 7'd50) ? 4'd5 :
                          (pct >= 7'd40) ? 4'd4 : (pct >= 7'd30) ? 4'd3 : (pct >= 7'd20) ? 4'd2 : (pct >= 7'd10) ? 4'd1 : 4'd0;
                td0[i] <= pct - 7'd10 * ((pct >= 7'd90) ? 7'd9 : (pct >= 7'd80) ? 7'd8 : (pct >= 7'd70) ? 7'd7 : (pct >= 7'd60) ? 7'd6 : (pct >= 7'd50) ? 7'd5 :
                          (pct >= 7'd40) ? 7'd4 : (pct >= 7'd30) ? 7'd3 : (pct >= 7'd20) ? 7'd2 : (pct >= 7'd10) ? 7'd1 : 7'd0);
            end
        end
    end

    // two-digit decimal of a byte (0..99, 99 when larger), done once per frame
    function [7:0] dec2;
        input [7:0] v;
        reg [7:0] w;
        reg [3:0] t;
        begin
            w = (v > 8'd99) ? 8'd99 : v;
            t = (w >= 8'd90) ? 4'd9 : (w >= 8'd80) ? 4'd8 : (w >= 8'd70) ? 4'd7 : (w >= 8'd60) ? 4'd6 : (w >= 8'd50) ? 4'd5 :
                (w >= 8'd40) ? 4'd4 : (w >= 8'd30) ? 4'd3 : (w >= 8'd20) ? 4'd2 : (w >= 8'd10) ? 4'd1 : 4'd0;
            dec2 = {t, w[3:0] + 4'd0 - (t << 3) - (t << 1)};
        end
    endfunction
    wire [7:0] rate_d = dec2(f_rate);
    wire [7:0] lat_d  = dec2(f_lat);

    // status text: 24 characters
    localparam integer SX = 16, SY = 688, NCH = 24;
    function [5:0] status_char;
        input [4:0] k;
        input [1:0] md;
        input [7:0] rd, ld;
        input [3:0] n;
        input [15:0] cap;
        begin
            status_char = 6'd36;
            if (md == 2'd3) begin
                case (k)   // "CAPTURE hhhh": the number of frames sent so far, hexadecimal (codes 0..15 are the digits 0-9 and the letters A-F)
                    5'd0: status_char = 6'd12; 5'd1: status_char = 6'd10; 5'd2: status_char = 6'd25; 5'd3: status_char = 6'd29;
                    5'd4: status_char = 6'd30; 5'd5: status_char = 6'd27; 5'd6: status_char = 6'd14;
                    5'd8: status_char = {2'b00, cap[15:12]}; 5'd9: status_char = {2'b00, cap[11:8]};
                    5'd10: status_char = {2'b00, cap[7:4]};  5'd11: status_char = {2'b00, cap[3:0]};
                    default: status_char = 6'd36;
                endcase
            end
            else begin
                case (k)
                    5'd0: status_char = (md == 2'd1) ? 6'd34 : 6'd12;            // Y / C
                    5'd1: status_char = (md == 2'd1) ? 6'd24 : 6'd31;            // O / V
                    5'd2: status_char = (md == 2'd1) ? 6'd21 : (md == 2'd2) ? 6'd37 : 6'd36;   // L / + / ' '
                    5'd3: status_char = (md == 2'd1) ? 6'd24 : (md == 2'd2) ? 6'd34 : 6'd36;   // O / Y
                    5'd4: status_char = (md == 2'd2) ? 6'd24 : 6'd36;
                    5'd5: status_char = (md == 2'd2) ? 6'd21 : 6'd36;
                    5'd6: status_char = (md == 2'd2) ? 6'd24 : 6'd36;
                    5'd8:  status_char = (md == 2'd0) ? 6'd36 : dig(rd[7:4]);
                    5'd9:  status_char = (md == 2'd0) ? 6'd36 : dig(rd[3:0]);
                    5'd10: status_char = (md == 2'd0) ? 6'd36 : 6'd15;      // F
                    5'd11: status_char = (md == 2'd0) ? 6'd36 : 6'd25;      // P
                    5'd12: status_char = (md == 2'd0) ? 6'd36 : 6'd28;      // S
                    5'd14: status_char = (md == 2'd0) ? 6'd36 : dig(ld[7:4]);
                    5'd15: status_char = (md == 2'd0) ? 6'd36 : dig(ld[3:0]);
                    5'd16: status_char = (md == 2'd0) ? 6'd36 : 6'd22;      // M
                    5'd17: status_char = (md == 2'd0) ? 6'd36 : 6'd28;      // S
                    5'd19: status_char = (md == 2'd0) ? 6'd36 : 6'd23;      // N
                    5'd20: status_char = (md == 2'd0) ? 6'd36 : 6'd38;      // =
                    5'd21: status_char = (md == 2'd0) ? 6'd36 : dig(n > 4'd9 ? 4'd9 : n);
                    default: status_char = 6'd36;
                endcase
            end
        end
    endfunction

    // ------------------------------------------------------------------ stage 1: hit tests
    reg        s1_de, s1_vs;
    reg [23:0] s1_d;
    reg        s1_border, s1_tag, s1_txt;
    reg [1:0]  s1_bc, s1_tc;
    reg [5:0]  s1_code;
    reg [3:0]  s1_col, s1_row;        // position inside the 12 x 16 character cell
    reg        s1_tagbg;
    reg        hb, ht;
    reg [1:0]  hbc, htc;
    reg [5:0]  hcode;
    reg [3:0]  hcol, hrow;
    reg [11:0] dx;
    reg [11:0] dy;
    reg [5:0]  k;
    integer j;
    always @(*) begin
        hb = 1'b0; hbc = 2'd0; ht = 1'b0; htc = 2'd0; hcode = 6'd36; hcol = 4'd0; hrow = 4'd0; dx = 12'd0; dy = 12'd0;   // complete assignment: no latch
        for (j = 7; j >= 0; j = j - 1) begin                 // box 0 has the highest priority (it is written last)
            if (j < fn && f_boxes) begin
                if (x >= {1'b0, bx0[j]} && x <= {1'b0, bx1[j]} && y >= {2'b00, by0[j]} && y <= {2'b00, by1[j]} &&
                    (x < {1'b0, bx0[j]} + 12'd2 || x + 12'd2 > {1'b0, bx1[j]} || y < {2'b00, by0[j]} + 12'd2 || y + 12'd2 > {2'b00, by1[j]})) begin
                    hb = 1'b1; hbc = bc[j];
                end
                dx = x - {1'b0, tx[j]};
                dy = y - {2'b00, ty[j]};
                if (x >= {1'b0, tx[j]} && dx < 12'd36 && y >= {2'b00, ty[j]} && dy < 12'd16) begin
                    ht = 1'b1; htc = bc[j];
                    hrow = dy[3:0];
                    if (dx < 12'd12) begin hcol = dx[3:0]; hcode = (bc[j] == 2'd0) ? 6'd27 : (bc[j] == 2'd1) ? 6'd16 : 6'd11; end     // R / G / B
                    else if (dx < 12'd24) begin hcol = dx[3:0] - 4'd12; hcode = dig(td1[j]); end
                    else begin hcol = dx[3:0] - 4'd8; hcode = dig(td0[j]); end                       // dx - 24 (mod 16)
                end
            end
        end
    end
    // status line hit
    wire [11:0] sdx = x - SX;
    wire        s_hit = f_status && (x >= SX) && (sdx < NCH * 12) && (y >= SY) && (y < SY + 16);
    reg  [4:0]  s_k;
    reg  [3:0]  s_col;
    always @(*) begin
        s_k = 5'd0; s_col = 4'd0;
        for (j = 0; j < NCH; j = j + 1) if (sdx >= j * 12 && sdx < j * 12 + 12) begin s_k = j; s_col = sdx - j * 12; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s1_de <= 1'b0; s1_vs <= 1'b0; end
        else begin s1_de <= in_de; s1_vs <= in_vs; end
    end
    always @(posedge clk) begin
        s1_d <= in_data;
        s1_border <= hb; s1_bc <= hbc;
        s1_tag <= ht; s1_tc <= htc;
        s1_txt <= s_hit;
        if (ht) begin s1_code <= hcode; s1_col <= hcol; s1_row <= hrow; end
        else begin s1_code <= status_char(s_k, f_mode, rate_d, lat_d, f_n, f_cap); s1_col <= s_col; s1_row <= y[3:0] - SY[3:0]; end
    end

    // ------------------------------------------------------------------ stage 2: font pixel
    reg        s2_de, s2_vs;
    reg [23:0] s2_d;
    reg        s2_border, s2_tag, s2_txt, s2_on;
    reg [1:0]  s2_bc, s2_tc;
    wire [4:0] g_bits = (s1_row >= 4'd1 && s1_row <= 4'd14) ? glyph_row(s1_code, (s1_row - 4'd1) >> 1) : 5'd0;
    wire       g_on = (s1_col >= 4'd1 && s1_col <= 4'd10) ? g_bits[4 - ((s1_col - 4'd1) >> 1)] : 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s2_de <= 1'b0; s2_vs <= 1'b0; end
        else begin s2_de <= s1_de; s2_vs <= s1_vs; end
    end
    always @(posedge clk) begin
        s2_d <= s1_d; s2_border <= s1_border; s2_bc <= s1_bc; s2_tag <= s1_tag; s2_tc <= s1_tc; s2_txt <= s1_txt; s2_on <= g_on;
    end

    // ------------------------------------------------------------------ stage 3: colour
    function [23:0] ccol;
        input [1:0] c;
        begin ccol = (c == 2'd0) ? 24'hFF3030 : (c == 2'd1) ? 24'h30FF30 : 24'h3080FF; end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin out_de <= 1'b0; out_vs <= 1'b0; end
        else begin out_de <= s2_de; out_vs <= s2_vs; end
    end
    always @(posedge clk) begin
        if (s2_tag)          out_data <= s2_on ? 24'h000000 : ccol(s2_tc);
        else if (s2_border)  out_data <= ccol(s2_bc);
        else if (s2_txt)     out_data <= s2_on ? 24'hFFFFFF : {1'b0, s2_d[23:17], 1'b0, s2_d[15:9], 1'b0, s2_d[7:1]};    // white text on a darkened field
        else                 out_data <= s2_d;
    end

endmodule
