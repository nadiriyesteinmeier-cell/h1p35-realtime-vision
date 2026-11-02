// top_osd.v - last overlay before hdmi_tx, drawn on EVERY page: Anlogic logo (with its light plate), the measured capture-to-display
// latency, and on the motion page the frame-difference result (moving cells tinted red, their bounding box, the number of moving cells).
//
// Stream in: in_vs / in_de / in_data (24-bit RGB, [23:16] = R), any sync polarity; x / y are counted from de (the line counter restarts at
// every vs edge, both edges lie in the vertical blanking). Stream out: the same stream LAT = 3 clocks later.
// The logo used to be drawn by osd_overlay (CV view only); it is drawn here so that the YOLO, white-balance, motion and baseline views have
// it too (one copy of the ROM: contest_vision_v2 runs with LOGO_EN = 0).
// Text (5 x 7 LUT font, x2, 12 x 16 cells, white on a darkened field) at (TX, TY):
//   "LAT dd.dMS nF"  latency of a recent frame (lat_meter: ISP output -> HDMI read-out, ms) and the camera frames in between
//   "MAX dd.dMS"     largest latency of the last window
//   "MOTION nnn"     moving cells (motion page only) / "HIST EQ" (histogram-equalisation page, he_eq.v)
// Digits show '-' while no stamp is found. The stamp pixels (0..4, 0) are painted black. Values are taken once per frame at the vs edge.
// Motion map: map_raddr selects the cell row of the next line during the blanking, map_rdata (1 clock later) is kept for the whole line.

module top_osd #(
    parameter [11:0] LOGO_X = 12'd16,
    parameter [11:0] LOGO_Y = 12'd16,
    parameter [11:0] TX     = 12'd1108,
    parameter [11:0] TY     = 12'd16
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          in_vs,
    input  wire          in_de,
    input  wire [23:0]   in_data,
    output reg           out_vs,
    output reg           out_de,
    output reg  [23:0]   out_data,

    input  wire          lat_valid,
    input  wire [16:0]   lat_us,
    input  wire [16:0]   max_us,
    input  wire [3:0]    lat_fr,
    input  wire          motion_en,
    input  wire          he_en,
    input  wire [9:0]    mot_count,
    input  wire [4:0]    mot_bx0,
    input  wire [4:0]    mot_bx1,
    input  wire [4:0]    mot_by0,
    input  wire [4:0]    mot_by1,
    output wire [4:0]    map_raddr,
    input  wire [31:0]   map_rdata
);
    localparam integer LOGO_W = 160;
    localparam integer LOGO_H = 94;                    // osd_logo_rom.v
    localparam [23:0]  LOGO_NAVY = 24'h1C2D4E;
    localparam [23:0]  LOGO_RED  = 24'hED1C24;

    // ------------------------------------------------------------------ 5 x 7 font (yolo_osd.v codes + 41 '.', 42 '-')
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
                6'd14: glyph = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b11111};   // E
                6'd15: glyph = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b10000};   // F
                6'd17: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b11111, 5'b10001, 5'b10001, 5'b10001};   // H
                6'd18: glyph = {5'b01110, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b01110};   // I
                6'd21: glyph = {5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b11111};   // L
                6'd22: glyph = {5'b10001, 5'b11011, 5'b10101, 5'b10101, 5'b10001, 5'b10001, 5'b10001};   // M
                6'd23: glyph = {5'b10001, 5'b10001, 5'b11001, 5'b10101, 5'b10011, 5'b10001, 5'b10001};   // N
                6'd24: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};   // O
                6'd26: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b10001, 5'b10101, 5'b10010, 5'b01101};   // Q
                6'd28: glyph = {5'b01111, 5'b10000, 5'b10000, 5'b01110, 5'b00001, 5'b00001, 5'b11110};   // S
                6'd29: glyph = {5'b11111, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100};   // T
                6'd33: glyph = {5'b10001, 5'b10001, 5'b01010, 5'b00100, 5'b01010, 5'b10001, 5'b10001};   // X
                6'd41: glyph = {5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b01100, 5'b01100};   // .
                6'd42: glyph = {5'b00000, 5'b00000, 5'b00000, 5'b01110, 5'b00000, 5'b00000, 5'b00000};   // -
                default: glyph = 35'd0;                                                                  // 36 = space
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

    // ------------------------------------------------------------------ x / y counters, cell position (40 x 40 cells)
    reg [11:0] x, y;
    reg        vs_q, de_q;
    reg [5:0]  xc_n, yc;
    reg [4:0]  bx_n, by;
    wire       frame_edge = (in_vs != vs_q);
    wire [5:0] xc = (x == 12'd0) ? 6'd0 : xc_n;
    wire [4:0] bx = (x == 12'd0) ? 5'd0 : bx_n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin x <= 12'd0; y <= 12'd0; vs_q <= 1'b0; de_q <= 1'b0; xc_n <= 6'd0; bx_n <= 5'd0; yc <= 6'd0; by <= 5'd0; end
        else begin
            vs_q <= in_vs; de_q <= in_de;
            if (frame_edge) begin y <= 12'd0; yc <= 6'd0; by <= 5'd0; end
            else if (de_q & ~in_de) begin
                y <= y + 12'd1;
                if (yc == 6'd39) begin yc <= 6'd0; by <= by + 5'd1; end
                else yc <= yc + 6'd1;
            end
            if (in_de) begin
                x <= x + 12'd1;
                if (xc == 6'd39) begin xc_n <= 6'd0; bx_n <= bx + 5'd1; end
                else begin xc_n <= xc + 6'd1; bx_n <= bx; end
            end
            else x <= 12'd0;
        end
    end
    assign map_raddr = by;
    reg [31:0] row_bits;
    always @(posedge clk) if (!in_de) row_bits <= map_rdata;      // the row of the coming line (map_raddr changed at the line end)

    // ------------------------------------------------------------------ per-frame values (latched at the vs edge)
    wire [19:0] lat_bcd, max_bcd;
    wire [11:0] cnt_bcd;
    osd_bin2bcd #(.BITS(17), .DIGITS(5)) u_bl (.clk(clk), .rst_n(rst_n), .bin(lat_us), .bcd(lat_bcd));
    osd_bin2bcd #(.BITS(17), .DIGITS(5)) u_bm (.clk(clk), .rst_n(rst_n), .bin(max_us), .bcd(max_bcd));
    osd_bin2bcd #(.BITS(10), .DIGITS(3)) u_bc (.clk(clk), .rst_n(rst_n), .bin(mot_count), .bcd(cnt_bcd));
    reg        f_val, f_mot, f_box, f_he;
    reg [11:0] f_l, f_m, f_c;                   // three digits each: tens, ones, tenths of ms / hundreds, tens, ones
    reg [3:0]  f_fr;
    reg [11:0] f_x0, f_x1, f_y0, f_y1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin f_val <= 1'b0; f_mot <= 1'b0; f_box <= 1'b0; f_he <= 1'b0; end
        else if (frame_edge) begin f_val <= lat_valid; f_mot <= motion_en; f_box <= motion_en && (mot_count != 10'd0); f_he <= he_en; end
    end
    always @(posedge clk) begin
        if (frame_edge) begin
            f_l <= lat_bcd[19:8]; f_m <= max_bcd[19:8]; f_c <= cnt_bcd; f_fr <= lat_fr;
            f_x0 <= {2'd0, mot_bx0, 5'd0} + {4'd0, mot_bx0, 3'd0};
            f_x1 <= {2'd0, mot_bx1, 5'd0} + {4'd0, mot_bx1, 3'd0} + 12'd39;
            f_y0 <= {2'd0, mot_by0, 5'd0} + {4'd0, mot_by0, 3'd0};
            f_y1 <= {2'd0, mot_by1, 5'd0} + {4'd0, mot_by1, 3'd0} + 12'd39;
        end
    end

    function [5:0] dg;                          // digit or '-'
        input       v;
        input [3:0] d;
        begin dg = v ? {2'b00, d} : 6'd42; end
    endfunction
    function [5:0] tchar;
        input [1:0]  ln;
        input [3:0]  k;
        input        v;
        input [11:0] l, m, c;
        input [3:0]  fr;
        input        he;
        begin
            tchar = 6'd36;
            case (ln)
                2'd0: case (k)                  // LAT dd.dMS nF
                    4'd0: tchar = 6'd21; 4'd1: tchar = 6'd10; 4'd2: tchar = 6'd29;
                    4'd4: tchar = dg(v, l[11:8]); 4'd5: tchar = dg(v, l[7:4]); 4'd6: tchar = 6'd41; 4'd7: tchar = dg(v, l[3:0]);
                    4'd8: tchar = 6'd22; 4'd9: tchar = 6'd28; 4'd11: tchar = dg(v, fr); 4'd12: tchar = 6'd15;
                    default: tchar = 6'd36;
                endcase
                2'd1: case (k)                  // MAX dd.dMS
                    4'd0: tchar = 6'd22; 4'd1: tchar = 6'd10; 4'd2: tchar = 6'd33;
                    4'd4: tchar = dg(v, m[11:8]); 4'd5: tchar = dg(v, m[7:4]); 4'd6: tchar = 6'd41; 4'd7: tchar = dg(v, m[3:0]);
                    4'd8: tchar = 6'd22; 4'd9: tchar = 6'd28;
                    default: tchar = 6'd36;
                endcase
                default: if (he) case (k)       // HIST EQ
                    4'd0: tchar = 6'd17; 4'd1: tchar = 6'd18; 4'd2: tchar = 6'd28; 4'd3: tchar = 6'd29;
                    4'd5: tchar = 6'd14; 4'd6: tchar = 6'd26;
                    default: tchar = 6'd36;
                endcase
                else case (k)                   // MOTION nnn
                    4'd0: tchar = 6'd22; 4'd1: tchar = 6'd24; 4'd2: tchar = 6'd29; 4'd3: tchar = 6'd18; 4'd4: tchar = 6'd24; 4'd5: tchar = 6'd23;
                    4'd7: tchar = {2'b00, c[11:8]}; 4'd8: tchar = {2'b00, c[7:4]}; 4'd9: tchar = {2'b00, c[3:0]};
                    default: tchar = 6'd36;
                endcase
            endcase
        end
    endfunction

    // ------------------------------------------------------------------ stage 0: hit tests (combinational on x / y)
    localparam integer NCH = 13;
    wire [11:0] tdx   = x - TX;
    wire [11:0] tdy   = y - TY;
    wire        t_x   = (x >= TX) && (tdx < NCH * 12);
    wire [1:0]  t_ln  = (tdy < 12'd20) ? 2'd0 : (tdy < 12'd40) ? 2'd1 : 2'd2;
    wire [11:0] t_ry  = tdy - ((t_ln == 2'd0) ? 12'd0 : (t_ln == 2'd1) ? 12'd20 : 12'd40);
    wire        t_y   = (y >= TY) && (t_ry < 12'd16) && (t_ln != 2'd2 || f_mot || f_he);
    wire        dark  = (x + 12'd4 >= TX) && (x < TX + NCH * 12 + 4) && (y + 12'd4 >= TY) && (y < TY + ((f_mot || f_he) ? 12'd60 : 12'd40));
    // character index / column inside the 12-pixel cell of the current pixel: counters that start at x = TX (cheaper than comparing
    // x - TX with every cell border); outside the text box they run on and are ignored (t_x)
    reg  [3:0]  t_k;
    reg  [3:0]  t_col;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin t_k <= 4'd0; t_col <= 4'd0; end
        else if (in_de) begin
            if (x == TX - 12'd1)     begin t_k <= 4'd0; t_col <= 4'd0; end
            else if (t_col == 4'd11) begin t_k <= t_k + 4'd1; t_col <= 4'd0; end
            else                     t_col <= t_col + 4'd1;
        end
    end

    wire [11:0] ldx      = x - LOGO_X;
    wire [11:0] ldy      = y - LOGO_Y;
    wire        logo_in  = (x >= LOGO_X) && (ldx < LOGO_W) && (y >= LOGO_Y) && (ldy < LOGO_H);
    wire [13:0] logo_a   = {ldy[6:0], 7'd0} + {2'd0, ldy[6:0], 5'd0} + {2'd0, ldx};
    wire        plate_in = (x + 12'd6 >= LOGO_X) && (x < LOGO_X + LOGO_W + 6) && (y + 12'd6 >= LOGO_Y) && (y < LOGO_Y + LOGO_H + 6);
    wire [5:0]  logo_q;
    osd_logo_rom u_logo (.clk(clk), .addr(logo_in ? logo_a : 14'd0), .data(logo_q));

    wire        mcell = f_mot && row_bits[bx];
    wire        bbox = f_box && (x + 12'd3 >= f_x0) && (x < f_x1 + 12'd4) && (y + 12'd3 >= f_y0) && (y < f_y1 + 12'd4) &&   // 4-pixel border
                       !((x > f_x0) && (x < f_x1) && (y > f_y0) && (y < f_y1));
    wire        hide = (y == 12'd0) && (x < 12'd8);

    // ------------------------------------------------------------------ stage 1
    reg        s1_de, s1_vs;
    reg [23:0] s1_d;
    reg        s1_txt, s1_dark, s1_logo, s1_plate, s1_cell, s1_box, s1_hide;
    reg [5:0]  s1_code;
    reg [3:0]  s1_col, s1_row;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s1_de <= 1'b0; s1_vs <= 1'b0; end
        else begin s1_de <= in_de; s1_vs <= in_vs; end
    end
    always @(posedge clk) begin
        s1_d <= in_data;
        s1_txt <= t_x && t_y; s1_dark <= dark; s1_logo <= logo_in; s1_plate <= plate_in; s1_cell <= mcell; s1_box <= bbox; s1_hide <= hide;
        s1_code <= tchar(t_ln, t_k, f_val, f_l, f_m, f_c, f_fr, f_he); s1_col <= t_col; s1_row <= t_ry[3:0];
    end

    // ------------------------------------------------------------------ stage 2: lower layers, font pixel, logo alpha
    wire [4:0]  g_bits = (s1_row >= 4'd1 && s1_row <= 4'd14) ? glyph_row(s1_code, (s1_row - 4'd1) >> 1) : 5'd0;
    wire        g_on   = (s1_col >= 4'd1 && s1_col <= 4'd10) ? g_bits[4 - ((s1_col - 4'd1) >> 1)] : 1'b0;
    wire [23:0] v_cell = s1_cell ? {1'b1, s1_d[23:17], 1'b0, s1_d[15:9], 1'b0, s1_d[7:1]} : s1_d;     // red tint
    wire [23:0] v_box  = s1_box  ? 24'hFFE000 : v_cell;
    wire [23:0] v_dark = s1_dark ? {1'b0, v_box[23:17], 1'b0, v_box[15:9], 1'b0, v_box[7:1]} : v_box;
    wire [9:0]  pr = {2'b00, v_dark[23:16]} + 10'd765;                  // plate: (v * 4 + 255 * 12) / 16
    wire [9:0]  pg = {2'b00, v_dark[15:8]}  + 10'd765;
    wire [9:0]  pb = {2'b00, v_dark[7:0]}   + 10'd765;
    wire [23:0] v_plate = s1_plate ? {pr[9:2], pg[9:2], pb[9:2]} : v_dark;
    reg        s2_de, s2_vs;
    reg [23:0] s2_d;
    reg [4:0]  s2_alpha;
    reg        s2_cls, s2_on, s2_hide;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s2_de <= 1'b0; s2_vs <= 1'b0; end
        else begin s2_de <= s1_de; s2_vs <= s1_vs; end
    end
    always @(posedge clk) begin
        s2_d <= v_plate; s2_alpha <= s1_logo ? logo_q[4:0] : 5'd0; s2_cls <= logo_q[5]; s2_on <= s1_txt && g_on; s2_hide <= s1_hide;
    end

    // ------------------------------------------------------------------ stage 3: logo blend, text, stamp pixels
    function [7:0] blend8;               // (v*(16-a) + c*a) >> 4, a = 0..16
        input [7:0] v;
        input [7:0] c;
        input [4:0] a;
        reg   [12:0] p;
        begin
            p = v * (5'd16 - a) + c * a;
            blend8 = p[11:4];
        end
    endfunction
    wire [23:0] lcol   = s2_cls ? LOGO_RED : LOGO_NAVY;
    wire [23:0] v_logo = {blend8(s2_d[23:16], lcol[23:16], s2_alpha), blend8(s2_d[15:8], lcol[15:8], s2_alpha), blend8(s2_d[7:0], lcol[7:0], s2_alpha)};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin out_de <= 1'b0; out_vs <= 1'b0; end
        else begin out_de <= s2_de; out_vs <= s2_vs; end
    end
    always @(posedge clk) out_data <= s2_hide ? 24'h000000 : s2_on ? 24'hFFFFFF : v_logo;

endmodule
