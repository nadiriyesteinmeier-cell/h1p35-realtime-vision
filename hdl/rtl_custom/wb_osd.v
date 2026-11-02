// wb_osd.v - white-balance page overlay on a 1280 x 720 stream, and the average colour of the measurement window
//
// Stream in: in_vs / in_de / in_data (24-bit RGB, [23:16] = R), data aligned with de; the line counter restarts at every vs edge (both edges lie in
// the vertical blanking), like yolo_osd. Stream out: the same stream, LAT = 3 clocks later, with the page drawn when `enable` is 1.
// Measurement (always running, on the INPUT stream, so the overlay never disturbs it): the 128 x 128 window at (WX0, WY0); at every vs edge the sums of
// a complete window (exactly 16384 pixels) become avg_r / avg_g / avg_b = sum >> 14 (truncated mean), otherwise the old averages stay. The page shows
// them for the frame after the one they were measured in.
// Page (enable = 1): a 2-pixel outline just outside the window and three text lines at x = SX (5 x 7 font scaled x2 in 12 x 16 cells, white on a
// darkened field):
//   SY0  "WB AUTO R1.32 G1.00 B0.87"     mode (AUTO / MAN / OFF) and the gains the ISP applies; the selected gain is drawn black on yellow
//   SY1  "AVG R128 G130 B127"            the window average (0..255; equal values = neutral)
//   SY2  "K1- K2+ K3 SEL K4 MODE K3+K4 NEXT"
// wb_mode / sel / digits (wb_ctrl) are latched at the vs edge, so a frame never mixes two settings. digits = {gain R, G, B, avg R, G, B} x {d2, d1, d0} BCD.
// Reset: control flags only.

module wb_osd #(
    parameter integer WX0 = 576,
    parameter integer WY0 = 296,
    parameter integer SX  = 16,
    parameter integer SY0 = 688,
    parameter integer SY1 = 668,
    parameter integer SY2 = 648
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          in_vs,
    input  wire          in_de,
    input  wire [23:0]   in_data,
    output reg           out_vs,
    output reg           out_de,
    output reg  [23:0]   out_data,

    input  wire          enable,
    input  wire [1:0]    wb_mode,
    input  wire [1:0]    sel,
    input  wire [71:0]   digits,
    output reg  [7:0]    avg_r,
    output reg  [7:0]    avg_g,
    output reg  [7:0]    avg_b
);

    localparam integer WS = 128;

    // ------------------------------------------------------------------ 5 x 7 font (the yolo_osd codes plus 41 '.', 42 '-')
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
                6'd13: glyph = {5'b11100, 5'b10010, 5'b10001, 5'b10001, 5'b10001, 5'b10010, 5'b11100};   // D
                6'd14: glyph = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b11111};   // E
                6'd15: glyph = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b10000};   // F
                6'd16: glyph = {5'b01110, 5'b10001, 5'b10000, 5'b10111, 5'b10001, 5'b10001, 5'b01111};   // G
                6'd20: glyph = {5'b10001, 5'b10010, 5'b10100, 5'b11000, 5'b10100, 5'b10010, 5'b10001};   // K
                6'd21: glyph = {5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b11111};   // L
                6'd22: glyph = {5'b10001, 5'b11011, 5'b10101, 5'b10101, 5'b10001, 5'b10001, 5'b10001};   // M
                6'd23: glyph = {5'b10001, 5'b10001, 5'b11001, 5'b10101, 5'b10011, 5'b10001, 5'b10001};   // N
                6'd24: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};   // O
                6'd27: glyph = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10100, 5'b10010, 5'b10001};   // R
                6'd28: glyph = {5'b01111, 5'b10000, 5'b10000, 5'b01110, 5'b00001, 5'b00001, 5'b11110};   // S
                6'd29: glyph = {5'b11111, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100};   // T
                6'd30: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};   // U
                6'd31: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01010, 5'b00100};   // V
                6'd32: glyph = {5'b10001, 5'b10001, 5'b10001, 5'b10101, 5'b10101, 5'b10101, 5'b01010};   // W
                6'd33: glyph = {5'b10001, 5'b10001, 5'b01010, 5'b00100, 5'b01010, 5'b10001, 5'b10001};   // X
                6'd37: glyph = {5'b00000, 5'b00100, 5'b00100, 5'b11111, 5'b00100, 5'b00100, 5'b00000};   // +
                6'd41: glyph = {5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b01100, 5'b01100};   // .
                6'd42: glyph = {5'b00000, 5'b00000, 5'b00000, 5'b11111, 5'b00000, 5'b00000, 5'b00000};   // -
                default: glyph = 35'd0;                                                                  // space and unused codes
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

    // ------------------------------------------------------------------ window average
    wire       in_win = in_de && (x >= WX0) && (x < WX0 + WS) && (y >= WY0) && (y < WY0 + WS);
    reg [21:0] sr, sg, sb;
    reg [14:0] wn;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sr <= 22'd0; sg <= 22'd0; sb <= 22'd0; wn <= 15'd0; avg_r <= 8'd0; avg_g <= 8'd0; avg_b <= 8'd0; end
        else if (frame_edge) begin
            if (wn == WS * WS) begin avg_r <= sr[21:14]; avg_g <= sg[21:14]; avg_b <= sb[21:14]; end
            sr <= 22'd0; sg <= 22'd0; sb <= 22'd0; wn <= 15'd0;
        end
        else if (in_win) begin
            sr <= sr + {14'd0, in_data[23:16]};
            sg <= sg + {14'd0, in_data[15:8]};
            sb <= sb + {14'd0, in_data[7:0]};
            if (wn != 15'h7FFF) wn <= wn + 15'd1;
        end
    end

    // ------------------------------------------------------------------ per-frame settings
    reg        f_en;
    reg [1:0]  f_mode, f_sel;
    reg [71:0] f_dig;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) f_en <= 1'b0;
        else if (frame_edge) f_en <= enable;
    end
    always @(posedge clk) if (frame_edge) begin f_mode <= wb_mode; f_sel <= sel; f_dig <= digits; end

    // ------------------------------------------------------------------ text: line flags (registered: y only changes in the line blanking), character counters
    reg       l0, l1, l2;
    reg [3:0] lrow;
    always @(posedge clk) begin
        l0 <= (y >= SY0) && (y < SY0 + 16);
        l1 <= (y >= SY1) && (y < SY1 + 16);
        l2 <= (y >= SY2) && (y < SY2 + 16);
        lrow <= (y >= SY0 && y < SY0 + 16) ? (y[3:0] - SY0[3:0]) : (y >= SY1 && y < SY1 + 16) ? (y[3:0] - SY1[3:0]) : (y[3:0] - SY2[3:0]);
    end
    reg [5:0] ck;                                // character index and column inside the 12-pixel cell of the current pixel (x >= SX)
    reg [3:0] cc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ck <= 6'd0; cc <= 4'd0; end
        else if (!in_de) begin ck <= 6'd0; cc <= 4'd0; end
        else if (x >= SX) begin
            if (cc == 4'd11) begin cc <= 4'd0; if (ck != 6'd63) ck <= ck + 6'd1; end
            else cc <= cc + 4'd1;
        end
    end

    function [5:0] dg;                           // BCD digit -> code
        input [3:0] v;
        begin dg = {2'b00, v}; end
    endfunction
    // character k of line 0 (status), 1 (average), 2 (help); 36 = space
    function [5:0] wb_char;
        input [1:0]  ln;
        input [5:0]  k;
        input [1:0]  md;
        input [71:0] d;
        begin
            wb_char = 6'd36;
            if (ln == 2'd0) begin
                case (k)
                    6'd0: wb_char = 6'd32;  6'd1: wb_char = 6'd11;                                       // W B
                    6'd3: wb_char = (md == 2'd0) ? 6'd10 : (md == 2'd1) ? 6'd24 : 6'd22;                   // A / O / M
                    6'd4: wb_char = (md == 2'd0) ? 6'd30 : (md == 2'd1) ? 6'd15 : 6'd10;                   // U / F / A
                    6'd5: wb_char = (md == 2'd0) ? 6'd29 : (md == 2'd1) ? 6'd15 : 6'd23;                   // T / F / N
                    6'd6: wb_char = (md == 2'd0) ? 6'd24 : 6'd36;                                         // O
                    6'd8:  wb_char = 6'd27; 6'd9:  wb_char = dg(d[71:68]); 6'd10: wb_char = 6'd41; 6'd11: wb_char = dg(d[67:64]); 6'd12: wb_char = dg(d[63:60]);
                    6'd14: wb_char = 6'd16; 6'd15: wb_char = dg(d[59:56]); 6'd16: wb_char = 6'd41; 6'd17: wb_char = dg(d[55:52]); 6'd18: wb_char = dg(d[51:48]);
                    6'd20: wb_char = 6'd11; 6'd21: wb_char = dg(d[47:44]); 6'd22: wb_char = 6'd41; 6'd23: wb_char = dg(d[43:40]); 6'd24: wb_char = dg(d[39:36]);
                    default: wb_char = 6'd36;
                endcase
            end
            else if (ln == 2'd1) begin
                case (k)
                    6'd0: wb_char = 6'd10; 6'd1: wb_char = 6'd31; 6'd2: wb_char = 6'd16;                 // A V G
                    6'd4:  wb_char = 6'd27; 6'd5:  wb_char = dg(d[35:32]); 6'd6:  wb_char = dg(d[31:28]); 6'd7:  wb_char = dg(d[27:24]);
                    6'd9:  wb_char = 6'd16; 6'd10: wb_char = dg(d[23:20]); 6'd11: wb_char = dg(d[19:16]); 6'd12: wb_char = dg(d[15:12]);
                    6'd14: wb_char = 6'd11; 6'd15: wb_char = dg(d[11:8]);  6'd16: wb_char = dg(d[7:4]);   6'd17: wb_char = dg(d[3:0]);
                    default: wb_char = 6'd36;
                endcase
            end
            else begin                                                                                // K1- K2+ K3 SEL K4 MODE K3+K4 NEXT
                case (k)
                    6'd0: wb_char = 6'd20; 6'd1: wb_char = 6'd1; 6'd2: wb_char = 6'd42;
                    6'd4: wb_char = 6'd20; 6'd5: wb_char = 6'd2; 6'd6: wb_char = 6'd37;
                    6'd8: wb_char = 6'd20; 6'd9: wb_char = 6'd3; 6'd11: wb_char = 6'd28; 6'd12: wb_char = 6'd14; 6'd13: wb_char = 6'd21;
                    6'd15: wb_char = 6'd20; 6'd16: wb_char = 6'd4; 6'd18: wb_char = 6'd22; 6'd19: wb_char = 6'd24; 6'd20: wb_char = 6'd13; 6'd21: wb_char = 6'd14;
                    6'd23: wb_char = 6'd20; 6'd24: wb_char = 6'd3; 6'd25: wb_char = 6'd37; 6'd26: wb_char = 6'd20; 6'd27: wb_char = 6'd4;
                    6'd29: wb_char = 6'd23; 6'd30: wb_char = 6'd14; 6'd31: wb_char = 6'd33; 6'd32: wb_char = 6'd29;
                    default: wb_char = 6'd36;
                endcase
            end
        end
    endfunction

    wire [1:0] ln    = l0 ? 2'd0 : l1 ? 2'd1 : 2'd2;
    wire [5:0] nch   = l0 ? 6'd25 : l1 ? 6'd18 : 6'd33;
    wire       t_hit = f_en && in_de && (x >= SX) && (l0 || l1 || l2) && (ck < nch);
    wire [5:0] hl_k  = 6'd8 + {2'd0, f_sel, 2'b0} + {3'd0, f_sel, 1'b0};           // 8 + 6 * sel: the selected gain field (5 characters)
    wire       t_hl  = l0 && (ck >= hl_k) && (ck < hl_k + 6'd5);
    // window outline: 2 pixels just outside the measured window
    wire       o_box = (x + 12'd2 >= WX0) && (x < WX0 + WS + 2) && (y + 12'd2 >= WY0) && (y < WY0 + WS + 2);
    wire       o_in  = (x >= WX0) && (x < WX0 + WS) && (y >= WY0) && (y < WY0 + WS);
    wire       o_hit = f_en && in_de && o_box && !o_in;

    // ------------------------------------------------------------------ stage 1
    reg        s1_de, s1_vs;
    reg [23:0] s1_d;
    reg        s1_txt, s1_hl, s1_box;
    reg [5:0]  s1_code;
    reg [3:0]  s1_col, s1_row;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s1_de <= 1'b0; s1_vs <= 1'b0; end
        else begin s1_de <= in_de; s1_vs <= in_vs; end
    end
    always @(posedge clk) begin
        s1_d <= in_data; s1_txt <= t_hit; s1_hl <= t_hl; s1_box <= o_hit;
        s1_code <= wb_char(ln, ck, f_mode, f_dig); s1_col <= cc; s1_row <= lrow;
    end

    // ------------------------------------------------------------------ stage 2: font pixel
    reg        s2_de, s2_vs;
    reg [23:0] s2_d;
    reg        s2_txt, s2_hl, s2_box, s2_on;
    wire [4:0] g_bits = (s1_row >= 4'd1 && s1_row <= 4'd14) ? glyph_row(s1_code, (s1_row - 4'd1) >> 1) : 5'd0;
    wire       g_on   = (s1_col >= 4'd1 && s1_col <= 4'd10) ? g_bits[4 - ((s1_col - 4'd1) >> 1)] : 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s2_de <= 1'b0; s2_vs <= 1'b0; end
        else begin s2_de <= s1_de; s2_vs <= s1_vs; end
    end
    always @(posedge clk) begin
        s2_d <= s1_d; s2_txt <= s1_txt; s2_hl <= s1_hl; s2_box <= s1_box; s2_on <= g_on;
    end

    // ------------------------------------------------------------------ stage 3: colour
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin out_de <= 1'b0; out_vs <= 1'b0; end
        else begin out_de <= s2_de; out_vs <= s2_vs; end
    end
    always @(posedge clk) begin
        if (s2_txt && s2_hl)  out_data <= s2_on ? 24'h000000 : 24'hFFD020;                                   // selected gain: black on yellow
        else if (s2_txt)      out_data <= s2_on ? 24'hFFFFFF : {1'b0, s2_d[23:17], 1'b0, s2_d[15:9], 1'b0, s2_d[7:1]};
        else if (s2_box)      out_data <= 24'hFFD020;
        else                  out_data <= s2_d;
    end

endmodule
