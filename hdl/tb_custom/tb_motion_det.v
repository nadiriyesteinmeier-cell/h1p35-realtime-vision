`timescale 1ns/1ps
// tb_motion_det.v - motion_det against an independent model written here (per-cell sums of the samples, prev, threshold, count, box, map)
// Frames (1280 x 720, position-aligned stream: de / x / y / rgb, 24 blank clocks per line, 300 per frame):
//   0 base picture (no previous frame: nothing moves)      1 the same (nothing moves)
//   2 bright square over cells (5..7, 3..4) + edge cases   3 the square moved to (20..22, 10..12), partly covering cell borders
//   4 global change just below the threshold everywhere    5 one cell exactly at the threshold, one just below
//   6 square at the frame corner (cell 31, 17)              7 back to the base picture
// After every frame: count, box (when count != 0), and all 18 map rows through the read port.
module tb_motion_det;
    localparam integer W = 1280, H = 720, NF = 8, THR = 6;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg de = 1'b0;
    reg [11:0] x = 12'd0, y = 12'd0;
    reg [23:0] rgb = 24'd0;
    reg [4:0] raddr = 5'd0;
    wire [31:0] rdata;
    wire [9:0] count;
    wire [4:0] bx0, bx1, by0, by1;
    wire ready;
    motion_det #(.THR(THR)) dut (.clk(clk), .rst_n(rst_n), .de(de), .x(x), .y(y), .rgb(rgb), .map_raddr(raddr), .map_rdata(rdata),
                                 .count(count), .bx0(bx0), .bx1(bx1), .by0(by0), .by1(by1), .ready(ready));

    // picture of frame f
    function [23:0] pix;
        input integer f, px, py;
        integer r, g, b, n;
        begin
            n = (px * 7 + py * 13 + ((px * py) >> 3)) & 7;              // fixed texture (identical in every frame)
            r = 40 + ((px >> 3) & 63) + n;
            g = 50 + ((py >> 2) & 63) + n;
            b = 60 + (((px + py) >> 4) & 63);
            if (f == 2 && px >= 200 && px < 320 && py >= 120 && py < 200) begin r = 250; g = 250; b = 250; end
            if (f == 3 && px >= 805 && px < 905 && py >= 410 && py < 505) begin r = 250; g = 250; b = 250; end
            if (f == 4) begin r = r + 7; g = g + 7; b = b + 7; end         // +7 levels: cur changes by about 5.5 < 6 (checked by the model)
            if (f == 5 && px >= 400 && px < 440 && py >= 400 && py < 440) begin r = r + 8; g = g + 8; b = b + 8; end
            if (f == 5 && px >= 600 && px < 640 && py >= 400 && py < 440) begin r = r + 6; g = g + 6; b = b + 6; end
            if (f == 6 && px >= 1250 && py >= 690) begin r = 0; g = 0; b = 0; end
            pix = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    integer cur [0:575];
    integer prv [0:575];
    integer exp_map [0:17];
    integer exp_cnt, ex0, ex1, ey0, ey1, have_prev;
    integer f, i, j, c, s, errors, xx, yy;
    reg [23:0] p;
    integer yv;
    // model: sums of Y = (R + 2G + B) >> 2 over x mod 4 = 2, y mod 4 = 2 per 40 x 40 cell, cur = sum >> 7
    task model(input integer fr);
        integer cx, cy, k, d;
        begin
            for (k = 0; k < 576; k = k + 1) cur[k] = 0;
            for (yy = 2; yy < H; yy = yy + 4)
                for (xx = 2; xx < W; xx = xx + 4) begin
                    p = pix(fr, xx, yy);
                    yv = (p[23:16] + 2 * p[15:8] + p[7:0]) >> 2;
                    cur[(yy / 40) * 32 + xx / 40] = cur[(yy / 40) * 32 + xx / 40] + yv;
                end
            exp_cnt = 0; ex0 = 31; ex1 = 0; ey0 = 31; ey1 = 0;
            for (cy = 0; cy < 18; cy = cy + 1) begin
                exp_map[cy] = 0;
                for (cx = 0; cx < 32; cx = cx + 1) begin
                    k = cy * 32 + cx;
                    cur[k] = cur[k] >> 7;
                    d = cur[k] - prv[k];
                    if (d < 0) d = -d;
                    if (have_prev && d >= THR) begin
                        exp_map[cy] = exp_map[cy] | (1 << cx);
                        exp_cnt = exp_cnt + 1;
                        if (cx < ex0) ex0 = cx;
                        if (cx > ex1) ex1 = cx;
                        if (cy < ey0) ey0 = cy;
                        if (cy > ey1) ey1 = cy;
                    end
                end
            end
        end
    endtask

    initial begin
        errors = 0; have_prev = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        for (f = 0; f < NF; f = f + 1) begin
            model(f);
            for (j = 0; j < H; j = j + 1) begin
                for (i = 0; i < W; i = i + 1) begin
                    @(negedge clk); de = 1'b1; x = i; y = j; rgb = pix(f, i, j);
                end
                @(negedge clk); de = 1'b0; x = 12'd0; y = 12'd0; rgb = 24'd0;
                repeat (23) @(negedge clk);
            end
            repeat (300) @(negedge clk);
            // frame result
            if (count !== exp_cnt) begin errors = errors + 1; $display("MISMATCH frame %0d count %0d expected %0d", f, count, exp_cnt); end
            if (exp_cnt != 0 && (bx0 !== ex0 || bx1 !== ex1 || by0 !== ey0 || by1 !== ey1)) begin
                errors = errors + 1; $display("MISMATCH frame %0d box %0d..%0d x %0d..%0d expected %0d..%0d x %0d..%0d", f, bx0, bx1, by0, by1, ex0, ex1, ey0, ey1);
            end
            if (ready !== 1'b1) begin errors = errors + 1; $display("MISMATCH frame %0d ready %b", f, ready); end
            for (c = 0; c < 18; c = c + 1) begin
                @(negedge clk); raddr = c;
                @(negedge clk);
                if (rdata !== exp_map[c]) begin errors = errors + 1; $display("MISMATCH frame %0d map row %0d %h expected %h", f, c, rdata, exp_map[c]); end
            end
            $display("frame %0d: moving cells %0d (expected %0d) box %0d..%0d x %0d..%0d", f, count, exp_cnt, bx0, bx1, by0, by1);
            for (s = 0; s < 576; s = s + 1) prv[s] = cur[s];
            have_prev = 1;
        end
        if (errors == 0) $display("TB_RESULT: PASS tb_motion_det (%0d frames)", NF);
        else             $display("TB_RESULT: FAIL tb_motion_det errors=%0d", errors);
        $finish;
    end
endmodule
