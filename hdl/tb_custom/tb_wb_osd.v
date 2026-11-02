// tb_wb_osd.v - self-check of rtl_custom/wb_osd.v (white-balance page overlay + window average)
//
// Raster 448 x 240 active (h blanking 60, v blanking 12 lines, vs pulse in the blanking), window at (100, 20), text at x 16, lines at y 200 / 180 / 160.
// Six frames with a known picture (R, G, B functions of x, y and the frame number); the page settings (enable, mode, selection, display digits) are
// changed in the middle of every frame for the next one. Every output clock is compared with a model written here independently of the RTL:
//   * de / vs delayed by exactly 3 clocks, every pixel outside the page elements unchanged;
//   * the expected text is built as ASCII strings ("WB AUTO R1.32 G1.00 B0.87", "AVG R128 G064 B255", "K1- K2+ K3 SEL K4 MODE K3+K4 NEXT") from
//     the settings of the frame, rendered with an ASCII-indexed copy of the 5 x 7 font (x2, 1-pixel margin in a 12 x 16 cell): text pixel white, background
//     the darkened input (each channel >> 1), the selected gain field black on yellow;
//   * the 2-pixel outline around the window in yellow; nothing drawn while enable = 0;
//   * avg_r / avg_g / avg_b after every frame = the truncated mean of the 128 x 128 window of that frame's INPUT.
// Run: iverilog -g2005 -o sim_wbo.vvp tb_wb_osd.v ../rtl_custom/wb_osd.v ; vvp sim_wbo.vvp
// Final line: TB_RESULT: PASS tb_wb_osd  or  FAIL

`timescale 1ns / 1ps

module tb_wb_osd;

    localparam integer AW = 448, AH = 240, HB = 60, VB = 12;
    localparam integer WX0 = 100, WY0 = 20, SX = 16, SY0 = 200, SY1 = 180, SY2 = 160;
    localparam integer NF = 6;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg         in_vs, in_de;
    reg  [23:0] in_data;
    wire        out_vs, out_de;
    wire [23:0] out_data;
    reg         enable;
    reg  [1:0]  wb_mode, sel;
    reg  [71:0] digits;
    wire [7:0]  avg_r, avg_g, avg_b;

    wb_osd #(.WX0(WX0), .WY0(WY0), .SX(SX), .SY0(SY0), .SY1(SY1), .SY2(SY2)) dut (
        .clk(clk), .rst_n(rst_n), .in_vs(in_vs), .in_de(in_de), .in_data(in_data), .out_vs(out_vs), .out_de(out_de), .out_data(out_data),
        .enable(enable), .wb_mode(wb_mode), .sel(sel), .digits(digits), .avg_r(avg_r), .avg_g(avg_g), .avg_b(avg_b));

    // ---------------- picture
    function [23:0] pic;
        input integer x, y, f;
        integer r, g, b;
        begin
            r = (x * 3 + y + f * 17) & 255;
            g = (x + y * 5 + f * 40) & 255;
            b = ((x ^ y) + f * 9) & 255;
            pic = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    // ---------------- settings per frame
    reg        s_en  [0:NF];
    reg [1:0]  s_md  [0:NF];
    reg [1:0]  s_sel [0:NF];
    reg [71:0] s_dig [0:NF];

    // ---------------- ASCII font (independent copy indexed by the character)
    function [4:0] font;
        input [7:0] ch;
        input integer r;
        reg [34:0] g;
        begin
            case (ch)
                "0": g = {5'b01110, 5'b10001, 5'b10011, 5'b10101, 5'b11001, 5'b10001, 5'b01110};
                "1": g = {5'b00100, 5'b01100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b01110};
                "2": g = {5'b01110, 5'b10001, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b11111};
                "3": g = {5'b11111, 5'b00010, 5'b00100, 5'b00010, 5'b00001, 5'b10001, 5'b01110};
                "4": g = {5'b00010, 5'b00110, 5'b01010, 5'b10010, 5'b11111, 5'b00010, 5'b00010};
                "5": g = {5'b11111, 5'b10000, 5'b11110, 5'b00001, 5'b00001, 5'b10001, 5'b01110};
                "6": g = {5'b00110, 5'b01000, 5'b10000, 5'b11110, 5'b10001, 5'b10001, 5'b01110};
                "7": g = {5'b11111, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b01000, 5'b01000};
                "8": g = {5'b01110, 5'b10001, 5'b10001, 5'b01110, 5'b10001, 5'b10001, 5'b01110};
                "9": g = {5'b01110, 5'b10001, 5'b10001, 5'b01111, 5'b00001, 5'b00010, 5'b01100};
                "A": g = {5'b01110, 5'b10001, 5'b10001, 5'b11111, 5'b10001, 5'b10001, 5'b10001};
                "B": g = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10001, 5'b10001, 5'b11110};
                "D": g = {5'b11100, 5'b10010, 5'b10001, 5'b10001, 5'b10001, 5'b10010, 5'b11100};
                "E": g = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b11111};
                "F": g = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b10000};
                "G": g = {5'b01110, 5'b10001, 5'b10000, 5'b10111, 5'b10001, 5'b10001, 5'b01111};
                "K": g = {5'b10001, 5'b10010, 5'b10100, 5'b11000, 5'b10100, 5'b10010, 5'b10001};
                "L": g = {5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b10000, 5'b11111};
                "M": g = {5'b10001, 5'b11011, 5'b10101, 5'b10101, 5'b10001, 5'b10001, 5'b10001};
                "N": g = {5'b10001, 5'b10001, 5'b11001, 5'b10101, 5'b10011, 5'b10001, 5'b10001};
                "O": g = {5'b01110, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};
                "R": g = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10100, 5'b10010, 5'b10001};
                "S": g = {5'b01111, 5'b10000, 5'b10000, 5'b01110, 5'b00001, 5'b00001, 5'b11110};
                "T": g = {5'b11111, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b00100};
                "U": g = {5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01110};
                "V": g = {5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b01010, 5'b00100};
                "W": g = {5'b10001, 5'b10001, 5'b10001, 5'b10101, 5'b10101, 5'b10101, 5'b01010};
                "X": g = {5'b10001, 5'b10001, 5'b01010, 5'b00100, 5'b01010, 5'b10001, 5'b10001};
                "+": g = {5'b00000, 5'b00100, 5'b00100, 5'b11111, 5'b00100, 5'b00100, 5'b00000};
                ".": g = {5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b01100, 5'b01100};
                "-": g = {5'b00000, 5'b00000, 5'b00000, 5'b11111, 5'b00000, 5'b00000, 5'b00000};
                default: g = 35'd0;
            endcase
            font = g[34 - 5 * r -: 5];
        end
    endfunction

    // text of frame f, line n: ASCII, left aligned, length in tl
    reg [8*40-1:0] txt;
    integer        tl;
    function [7:0] dch;                          // BCD digit -> ASCII
        input [3:0] v;
        begin dch = "0" + v; end
    endfunction
    task make_line;
        input integer f, n;
        reg [71:0] d;
        begin
            d = s_dig[f];
            if (n == 0) begin
                tl = 25;
                txt = {s_md[f] == 2'd0 ? "WB AUTO " : s_md[f] == 2'd1 ? "WB OFF  " : "WB MAN  ",
                       "R", dch(d[71:68]), ".", dch(d[67:64]), dch(d[63:60]), " G", dch(d[59:56]), ".", dch(d[55:52]), dch(d[51:48]),
                       " B", dch(d[47:44]), ".", dch(d[43:40]), dch(d[39:36])};
            end
            else if (n == 1) begin
                tl = 18;
                txt = {"AVG R", dch(d[35:32]), dch(d[31:28]), dch(d[27:24]), " G", dch(d[23:20]), dch(d[19:16]), dch(d[15:12]),
                       " B", dch(d[11:8]), dch(d[7:4]), dch(d[3:0])};
            end
            else begin
                tl = 33;
                txt = "K1- K2+ K3 SEL K4 MODE K3+K4 NEXT";
            end
        end
    endtask

    // expected output pixel at (x, y) of frame f with input p
    integer n_txt, n_on, n_hl, n_box, n_pass;
    reg [23:0] expect_px;
    task calc_px;
        input integer x, y, f;
        input [23:0] p;
        integer n, k, col, row, ly;
        reg [7:0] ch;
        reg on, hl;
        begin
            expect_px = p;
            if (s_en[f]) begin
                n = -1;
                if (y >= SY0 && y < SY0 + 16) begin n = 0; ly = SY0; end
                else if (y >= SY1 && y < SY1 + 16) begin n = 1; ly = SY1; end
                else if (y >= SY2 && y < SY2 + 16) begin n = 2; ly = SY2; end
                if (x >= WX0 - 2 && x < WX0 + 130 && y >= WY0 - 2 && y < WY0 + 130 && !(x >= WX0 && x < WX0 + 128 && y >= WY0 && y < WY0 + 128))
                    expect_px = 24'hFFD020;
                if (n >= 0 && x >= SX) begin
                    make_line(f, n);
                    k = (x - SX) / 12; col = (x - SX) % 12; row = y - ly;
                    if (k < tl) begin
                        ch = txt[8 * (tl - 1 - k) +: 8];
                        on = (col >= 1 && col <= 10 && row >= 1 && row <= 14) ? font(ch, (row - 1) / 2) >> (4 - (col - 1) / 2) : 1'b0;
                        hl = (n == 0) && (k >= 8 + 6 * s_sel[f]) && (k < 13 + 6 * s_sel[f]);
                        if (hl) expect_px = on ? 24'h000000 : 24'hFFD020;
                        else    expect_px = on ? 24'hFFFFFF : {1'b0, p[23:17], 1'b0, p[15:9], 1'b0, p[7:1]};
                    end
                end
            end
        end
    endtask

    // ---------------- driver: frame f, settings for f+1 applied in the middle of the frame
    integer cur_f, cx, cy;
    reg     cur_act;
    task send_frame;
        input integer f;
        integer x, y;
        begin
            for (y = 0; y < AH; y = y + 1) begin
                if (y == AH / 2) begin enable = s_en[f + 1]; wb_mode = s_md[f + 1]; sel = s_sel[f + 1]; digits = s_dig[f + 1]; end
                for (x = 0; x < AW; x = x + 1) begin
                    @(negedge clk);
                    in_de = 1'b1; in_data = pic(x, y, f); cur_f = f; cx = x; cy = y; cur_act = 1'b1;
                end
                @(negedge clk); in_de = 1'b0; in_data = 24'd0; cur_act = 1'b0;
                repeat (HB - 1) @(negedge clk);
            end
            repeat (2 * (AW + HB)) @(negedge clk);
            in_vs = 1'b1;
            repeat (3 * (AW + HB)) @(negedge clk);
            in_vs = 1'b0;
            repeat ((VB - 5) * (AW + HB)) @(negedge clk);
        end
    endtask

    // ---------------- reference pipeline (3 clocks) and check
    reg [23:0] d1, d2, d3;
    reg        e1, e2, e3, v1, v2, v3;
    integer    f1, f2, f3, x1, x2, x3, y1, y2, y3;
    integer    errors;
    reg [23:0] ep;
    always @(posedge clk) begin
        if (rst_n) begin
            if (out_de !== e3 || out_vs !== v3) begin errors = errors + 1; if (errors < 10) $display("MISMATCH t=%0t de/vs %b%b expected %b%b", $time, out_de, out_vs, e3, v3); end
            if (e3) begin
                calc_px(x3, y3, f3, d3); ep = expect_px;
                if (out_data !== ep) begin
                    errors = errors + 1;
                    if (errors < 20) $display("MISMATCH frame %0d (%0d, %0d): got %h expected %h (input %h)", f3, x3, y3, out_data, ep, d3);
                end
                if (ep == d3) n_pass = n_pass + 1;
                else if (ep == 24'hFFD020) n_box = n_box + 1;
                else if (ep == 24'h000000) n_hl = n_hl + 1;
                else if (ep == 24'hFFFFFF) n_on = n_on + 1;
                else n_txt = n_txt + 1;
            end
        end
        d3 <= d2; d2 <= d1; d1 <= in_data;
        e3 <= e2; e2 <= e1; e1 <= in_de;
        v3 <= v2; v2 <= v1; v1 <= in_vs;
        f3 <= f2; f2 <= f1; f1 <= cur_f;
        x3 <= x2; x2 <= x1; x1 <= cx;
        y3 <= y2; y2 <= y1; y1 <= cy;
    end

    // ---------------- window average
    integer ar, ag, ab, wx, wy, f;
    reg [23:0] wp;
    task check_avg;
        input integer fr;
        begin
            ar = 0; ag = 0; ab = 0;
            for (wy = WY0; wy < WY0 + 128; wy = wy + 1)
                for (wx = WX0; wx < WX0 + 128; wx = wx + 1) begin
                    wp = pic(wx, wy, fr);
                    ar = ar + wp[23:16]; ag = ag + wp[15:8]; ab = ab + wp[7:0];
                end
            if (avg_r !== ar / 16384 || avg_g !== ag / 16384 || avg_b !== ab / 16384) begin
                errors = errors + 1;
                $display("MISMATCH average of frame %0d: %0d %0d %0d expected %0d %0d %0d", fr, avg_r, avg_g, avg_b, ar / 16384, ag / 16384, ab / 16384);
            end
            else $display("frame %0d: window average %0d %0d %0d", fr, avg_r, avg_g, avg_b);
        end
    endtask

    initial begin
        errors = 0; n_txt = 0; n_on = 0; n_hl = 0; n_box = 0; n_pass = 0;
        in_vs = 0; in_de = 0; in_data = 0; cur_f = 0; cx = 0; cy = 0; cur_act = 0;
        s_en[0] = 0; s_md[0] = 2'd0; s_sel[0] = 2'd0; s_dig[0] = 72'h135_100_088_128_064_255;
        s_en[1] = 1; s_md[1] = 2'd0; s_sel[1] = 2'd0; s_dig[1] = 72'h132_100_087_128_130_127;
        s_en[2] = 1; s_md[2] = 2'd2; s_sel[2] = 2'd1; s_dig[2] = 72'h125_099_088_000_099_200;
        s_en[3] = 1; s_md[3] = 2'd1; s_sel[3] = 2'd2; s_dig[3] = 72'h100_100_100_012_345_678;
        s_en[4] = 0; s_md[4] = 2'd2; s_sel[4] = 2'd0; s_dig[4] = 72'h999_999_999_999_999_999;
        s_en[5] = 1; s_md[5] = 2'd2; s_sel[5] = 2'd0; s_dig[5] = 72'h400_025_399_255_254_253;
        s_en[6] = 1; s_md[6] = 2'd0; s_sel[6] = 2'd0; s_dig[6] = 72'h0;
        enable = s_en[0]; wb_mode = s_md[0]; sel = s_sel[0]; digits = s_dig[0];
        rst_n = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        // a vs pulse before the first frame so the first frame's settings are latched
        repeat (20) @(negedge clk); in_vs = 1'b1; repeat (40) @(negedge clk); in_vs = 1'b0; repeat (200) @(negedge clk);
        for (f = 0; f < NF; f = f + 1) begin
            send_frame(f);
            check_avg(f);
        end
        $display("tb_wb_osd: pixels pass=%0d text-background=%0d text-on=%0d highlight-on=%0d yellow=%0d, errors=%0d", n_pass, n_txt, n_on, n_hl, n_box, errors);
        if (n_on < 1000 || n_hl < 100 || n_box < 2000 || n_txt < 5000) begin errors = errors + 1; $display("COVERAGE too low"); end
        if (errors == 0) $display("TB_RESULT: PASS tb_wb_osd");
        else             $display("TB_RESULT: FAIL tb_wb_osd errors=%0d", errors);
        $finish;
    end

endmodule
