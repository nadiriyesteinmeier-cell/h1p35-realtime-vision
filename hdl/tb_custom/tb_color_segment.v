// tb_color_segment.v - self-checking testbench for rtl_custom/color_segment.v
//
// Seven DUT instances with different parameters see the same stimulus. Each
// instance is wrapped by seg_chk, which holds an independent oracle:
//   hit = ROI && R >= R_MIN && (R - G) >= DELTA && (R - B) >= DELTA
// evaluated in 32-bit SIGNED integers (the DUT adds DELTA in 11-bit unsigned
// vectors instead), plus a clocked expected-value pipeline of exactly 2 stages
// (contract latency) that is reset like the DUT.
//
// Build/run (Icarus Verilog):
//   iverilog -g2005 -Wall -o sim_seg.vvp tb_color_segment.v ../rtl_custom/color_segment.v
//   vvp sim_seg.vvp
// Optional +define+FULL_SWEEP checks all 2^24 colours (slow).
// Final line is "TB_RESULT: PASS ..." or "TB_RESULT: FAIL ...".

`timescale 1ns / 1ps

module seg_chk #(
    parameter [31:0] NAME  = "?",
    parameter integer R_MIN = 80,
    parameter integer DELTA = 30,
    parameter integer X0    = 0,
    parameter integer X1    = 1280,
    parameter integer Y0    = 0,
    parameter integer Y1    = 720,
    parameter integer SELFTEST = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_de,
    input  wire [23:0] in_rgb,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire        in_eof,
    input  wire        check_en,
    output reg  [31:0] err_cnt,
    output reg  [31:0] chk_cnt,
    output reg  [31:0] hit_cnt,       // clocks where the oracle says "hit"
    output reg  [31:0] oracle_err
);

    wire        out_de;
    wire        out_hit;
    wire [23:0] out_rgb;
    wire [23:0] out_mask;
    wire [11:0] out_x;
    wire [11:0] out_y;
    wire        out_sof;
    wire        out_eol;
    wire        out_eof;

    color_segment #(
        .R_MIN(R_MIN), .DELTA(DELTA), .X0(X0), .X1(X1), .Y0(Y0), .Y1(Y1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .in_de(in_de), .in_rgb(in_rgb), .in_x(in_x), .in_y(in_y),
        .in_sof(in_sof), .in_eol(in_eol), .in_eof(in_eof),
        .out_de(out_de), .out_hit(out_hit), .out_rgb(out_rgb), .out_mask(out_mask),
        .out_x(out_x), .out_y(out_y),
        .out_sof(out_sof), .out_eol(out_eol), .out_eof(out_eof)
    );

    // ---------------- independent oracle (signed integers only)
    function exp_hit;
        input [23:0] rgb;
        input [11:0] x;
        input [11:0] y;
        integer r, g, b, xi, yi;
        begin
            r  = rgb[23:16];
            g  = rgb[15:8];
            b  = rgb[7:0];
            xi = x;
            yi = y;
            exp_hit = (xi >= X0) && (xi < X1) && (yi >= Y0) && (yi < Y1) &&
                      (r >= R_MIN) && ((r - g) >= DELTA) && ((r - b) >= DELTA);
        end
    endfunction

    // literal checks of the oracle itself (only meaningful for the default instance)
    initial begin
        oracle_err = 0;
        if (SELFTEST != 0) begin
            if (exp_hit({8'd255, 8'd226, 8'd0},   12'd3, 12'd2) !== 1'b0) oracle_err = oracle_err + 1; // 226+30 = 256 wrap trap
            if (exp_hit({8'd255, 8'd0,   8'd226}, 12'd3, 12'd2) !== 1'b0) oracle_err = oracle_err + 1;
            if (exp_hit({8'd255, 8'd225, 8'd225}, 12'd3, 12'd2) !== 1'b1) oracle_err = oracle_err + 1; // 225+30 = 255 exact
            if (exp_hit({8'd80,  8'd50,  8'd50},  12'd3, 12'd2) !== 1'b1) oracle_err = oracle_err + 1; // both limits exact
            if (exp_hit({8'd79,  8'd0,   8'd0},   12'd3, 12'd2) !== 1'b0) oracle_err = oracle_err + 1; // R_MIN-1
            if (exp_hit({8'd80,  8'd51,  8'd50},  12'd3, 12'd2) !== 1'b0) oracle_err = oracle_err + 1; // G+DELTA = R+1
            if (exp_hit({8'd80,  8'd50,  8'd51},  12'd3, 12'd2) !== 1'b0) oracle_err = oracle_err + 1;
            if (exp_hit({8'd255, 8'd0,   8'd0},   12'd1279, 12'd719) !== 1'b1) oracle_err = oracle_err + 1;
            if (exp_hit({8'd255, 8'd0,   8'd0},   12'd1280, 12'd719) !== 1'b0) oracle_err = oracle_err + 1;
            if (exp_hit({8'd255, 8'd0,   8'd0},   12'd1279, 12'd720) !== 1'b0) oracle_err = oracle_err + 1;
            if (exp_hit(24'hFFFFFF, 12'd3, 12'd2) !== 1'b0) oracle_err = oracle_err + 1;
            if (exp_hit(24'h000000, 12'd3, 12'd2) !== 1'b0) oracle_err = oracle_err + 1;
        end
    end

    // ---------------- expected pipeline: e1 -> e2 == DUT outputs (latency 2)
    reg         e1_de, e2_de;
    reg         e1_hit, e2_hit;
    reg  [23:0] e1_rgb, e2_rgb;
    reg  [11:0] e1_x, e2_x, e1_y, e2_y;
    reg         e1_sof, e2_sof, e1_eol, e2_eol, e1_eof, e2_eof;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e1_de <= 1'b0; e1_hit <= 1'b0; e1_rgb <= 24'd0; e1_x <= 12'd0; e1_y <= 12'd0;
            e1_sof <= 1'b0; e1_eol <= 1'b0; e1_eof <= 1'b0;
            e2_de <= 1'b0; e2_hit <= 1'b0; e2_rgb <= 24'd0; e2_x <= 12'd0; e2_y <= 12'd0;
            e2_sof <= 1'b0; e2_eol <= 1'b0; e2_eof <= 1'b0;
        end
        else begin
            e1_de  <= in_de;
            e1_hit <= in_de & exp_hit(in_rgb, in_x, in_y);
            e1_rgb <= in_de ? in_rgb : 24'd0;
            e1_x   <= in_de ? in_x   : 12'd0;
            e1_y   <= in_de ? in_y   : 12'd0;
            e1_sof <= in_de & in_sof;
            e1_eol <= in_de & in_eol;
            e1_eof <= in_de & in_eof;
            e2_de <= e1_de; e2_hit <= e1_hit; e2_rgb <= e1_rgb; e2_x <= e1_x; e2_y <= e1_y;
            e2_sof <= e1_sof; e2_eol <= e1_eol; e2_eof <= e1_eof;
        end
    end

    initial begin
        err_cnt = 0;
        chk_cnt = 0;
        hit_cnt = 0;
    end

    task bad;
        input [159:0] what;
        input [31:0]  exp_v;
        input [31:0]  act_v;
        begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 12)
                $display("MISMATCH[%0s] t=%0t %0s expected=%h actual=%h (in_de=%b rgb=%h x=%0d y=%0d)",
                         NAME, $time, what, exp_v, act_v, in_de, in_rgb, in_x, in_y);
            if (err_cnt >= 100) begin
                $display("TB_RESULT: FAIL tb_color_segment[%0s] aborted after %0d mismatches", NAME, err_cnt);
                $finish;
            end
        end
    endtask

    always @(negedge clk) begin
        if (check_en) begin
            chk_cnt = chk_cnt + 1;
            if (e2_hit) hit_cnt = hit_cnt + 1;
            if (out_de   !== e2_de)  bad("out_de",  e2_de,  out_de);
            if (out_hit  !== e2_hit) bad("out_hit", e2_hit, out_hit);
            if (out_rgb  !== e2_rgb) bad("out_rgb", e2_rgb, out_rgb);
            if (out_mask !== (e2_hit ? 24'hFFFFFF : 24'h000000)) bad("out_mask", e2_hit ? 24'hFFFFFF : 24'h000000, out_mask);
            if (out_x    !== e2_x)   bad("out_x",   e2_x,   out_x);
            if (out_y    !== e2_y)   bad("out_y",   e2_y,   out_y);
            if (out_sof  !== e2_sof) bad("out_sof", e2_sof, out_sof);
            if (out_eol  !== e2_eol) bad("out_eol", e2_eol, out_eol);
            if (out_eof  !== e2_eof) bad("out_eof", e2_eof, out_eof);
            if (!out_de) begin
                if (out_hit !== 1'b0 || out_rgb !== 24'd0 || out_mask !== 24'd0 ||
                    out_x !== 12'd0 || out_y !== 12'd0 ||
                    out_sof !== 1'b0 || out_eol !== 1'b0 || out_eof !== 1'b0)
                    bad("blanking_not_clean", 0, out_rgb);
            end
        end
    end

endmodule


module tb_color_segment;

    reg         clk;
    reg         rst_n;
    reg         in_de;
    reg  [23:0] in_rgb;
    reg  [11:0] in_x;
    reg  [11:0] in_y;
    reg         in_sof;
    reg         in_eol;
    reg         in_eof;
    reg         check_en;

    initial clk = 1'b0;
    always #5 clk = ~clk;

`define STIM .clk(clk), .rst_n(rst_n), .in_de(in_de), .in_rgb(in_rgb), \
             .in_x(in_x), .in_y(in_y), .in_sof(in_sof), .in_eol(in_eol), \
             .in_eof(in_eof), .check_en(check_en)

    wire [31:0] eA, eB, eC, eD, eE, eF, eG;
    wire [31:0] cA, cB, cC, cD, cE, cF, cG;
    wire [31:0] hA, hB, hC, hD, hE, hF, hG;
    wire [31:0] oA, oB, oC, oD, oE, oF, oG;

    // A: defaults (R_MIN 80, DELTA 30, full 1280x720) + literal oracle self-test
    seg_chk #(.NAME("A"), .R_MIN(80),  .DELTA(30),  .X0(0),   .X1(1280), .Y0(0),  .Y1(720), .SELFTEST(1))
        uA (`STIM, .err_cnt(eA), .chk_cnt(cA), .hit_cnt(hA), .oracle_err(oA));
    // B: small ROI [2,6) x [1,4) for an 8x6 frame
    seg_chk #(.NAME("B"), .R_MIN(80),  .DELTA(30),  .X0(2),   .X1(6),    .Y0(1),  .Y1(4))
        uB (`STIM, .err_cnt(eB), .chk_cnt(cB), .hit_cnt(hB), .oracle_err(oB));
    // C: high thresholds, G+DELTA exceeds 255 for G >= 196
    seg_chk #(.NAME("C"), .R_MIN(200), .DELTA(60),  .X0(0),   .X1(1280), .Y0(0),  .Y1(720))
        uC (`STIM, .err_cnt(eC), .chk_cnt(cC), .hit_cnt(hC), .oracle_err(oC));
    // D: extreme thresholds, only pure (255,0,0)
    seg_chk #(.NAME("D"), .R_MIN(255), .DELTA(255), .X0(0),   .X1(1280), .Y0(0),  .Y1(720))
        uD (`STIM, .err_cnt(eD), .chk_cnt(cD), .hit_cnt(hD), .oracle_err(oD));
    // E: mid-image ROI [100,200) x [50,60), default thresholds
    seg_chk #(.NAME("E"), .R_MIN(80),  .DELTA(30),  .X0(100), .X1(200),  .Y0(50), .Y1(60))
        uE (`STIM, .err_cnt(eE), .chk_cnt(cE), .hit_cnt(hE), .oracle_err(oE));
    // F: zero thresholds (black and equal-channel pixels hit)
    seg_chk #(.NAME("F"), .R_MIN(0),   .DELTA(0),   .X0(0),   .X1(1280), .Y0(0),  .Y1(720))
        uF (`STIM, .err_cnt(eF), .chk_cnt(cF), .hit_cnt(hF), .oracle_err(oF));
    // G: ROI up to the 13-bit limit 4096
    seg_chk #(.NAME("G"), .R_MIN(80),  .DELTA(30),  .X0(0),   .X1(4096), .Y0(0),  .Y1(4096))
        uG (`STIM, .err_cnt(eG), .chk_cnt(cG), .hit_cnt(hG), .oracle_err(oG));

    integer seed;

    // ------------------------------------------------------------------
    // stimulus helpers (one call = one clock; inputs change at negedge)
    // ------------------------------------------------------------------
    task pix;
        input        de;
        input [23:0] rgb;
        input [11:0] x;
        input [11:0] y;
        input        sof;
        input        eol;
        input        eof;
        begin
            @(negedge clk);
            in_de  = de;
            in_rgb = rgb;
            in_x   = x;
            in_y   = y;
            in_sof = sof;
            in_eol = eol;
            in_eof = eof;
        end
    endtask

    // valid pixel, no frame flags
    task pv;
        input [23:0] rgb;
        input [11:0] x;
        input [11:0] y;
        begin
            pix(1'b1, rgb, x, y, 1'b0, 1'b0, 1'b0);
        end
    endtask

    task garbage;
        begin
            pix(1'b0, $random(seed), $random(seed), $random(seed),
                $random(seed), $random(seed), $random(seed));
        end
    endtask

    // blanking cycle with a colour that WOULD be a hit in every instance
    task garbage_hit;
        begin
            pix(1'b0, 24'hFF0000, 12'd3, 12'd2, 1'b1, 1'b1, 1'b1);
        end
    endtask

    task idle;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                pix(1'b0, 24'd0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0);
        end
    endtask

    // one colour at a spread of coordinates (inside/outside the various ROIs)
    task color_at_points;
        input [23:0] rgb;
        begin
            pv(rgb, 12'd3,    12'd2);       // inside B and G, A, C, D, F
            pv(rgb, 12'd150,  12'd55);      // inside E
            pv(rgb, 12'd0,    12'd0);
            pv(rgb, 12'd1279, 12'd719);
            pv(rgb, 12'd4095, 12'd4095);    // only G
        end
    endtask

    // sweeps at a fixed coordinate
    task sweep_g;                           // G = 0..255, fixed R and B
        input [7:0]  r;
        input [7:0]  b;
        input [11:0] x;
        input [11:0] y;
        integer g;
        begin
            for (g = 0; g < 256; g = g + 1)
                pv({r, g[7:0], b}, x, y);
        end
    endtask

    task sweep_b;                           // B = 0..255, fixed R and G
        input [7:0]  r;
        input [7:0]  g;
        input [11:0] x;
        input [11:0] y;
        integer b;
        begin
            for (b = 0; b < 256; b = b + 1)
                pv({r, g, b[7:0]}, x, y);
        end
    endtask

    task sweep_gb;                          // G = B = 0..255, fixed R
        input [7:0]  r;
        input [11:0] x;
        input [11:0] y;
        integer v;
        begin
            for (v = 0; v < 256; v = v + 1)
                pv({r, v[7:0], v[7:0]}, x, y);
        end
    endtask

    task r_sweeps;                          // all three sweeps for one R value
        input [7:0]  r;
        input [11:0] x;
        input [11:0] y;
        begin
            sweep_g (r, 8'd0, x, y);
            sweep_b (r, 8'd0, x, y);
            sweep_gb(r, x, y);
        end
    endtask

    task frame;                             // sideband-carrying frame, random colours
        input integer w;
        input integer h;
        input integer gaps;
        integer x, y;
        reg [23:0] c;
        begin
            for (y = 0; y < h; y = y + 1) begin
                for (x = 0; x < w; x = x + 1) begin
                    c = $random(seed);
                    if (($random(seed) & 1) == 0) c = {8'd255, c[15:8] >> 3, c[7:0] >> 3};   // reddish
                    pix(1'b1, c, x, y, (x == 0 && y == 0), (x == w - 1),
                        (x == w - 1 && y == h - 1));
                    if (gaps != 0 && (($random(seed) & 3) == 0)) garbage_hit;
                end
                if (gaps != 0) begin
                    garbage; garbage_hit; garbage;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // main sequence
    // ------------------------------------------------------------------
    integer i, j, k;
    reg [23:0] c24;
    reg [11:0] rx, ry;
    integer    total_err;
    integer    total_chk;
    integer    sel;
    integer    sweep_lo, sweep_hi;

    initial begin
        seed = 32'h5EED0002;
        check_en = 1'b0;
        rst_n = 1'b0;
        in_de = 1'b0; in_rgb = 24'd0; in_x = 12'd0; in_y = 12'd0;
        in_sof = 1'b0; in_eol = 1'b0; in_eof = 1'b0;

        $display("tb_color_segment: seed=0x%h", seed);

        repeat (3) @(negedge clk);
        #2 rst_n = 1'b1;
        check_en = 1'b1;
        idle(3);

        // ---- directed colours, each at five coordinates
        color_at_points(24'hFF0000);                       // pure red
        color_at_points(24'h500000);                       // R = R_MIN exactly (80)
        color_at_points(24'h4F0000);                       // R = R_MIN-1 (79)
        color_at_points({8'd80,  8'd50,  8'd50});          // R = G+DELTA = B+DELTA exactly
        color_at_points({8'd80,  8'd51,  8'd50});          // G+DELTA = R+1
        color_at_points({8'd80,  8'd50,  8'd51});          // B+DELTA = R+1
        color_at_points({8'd81,  8'd51,  8'd51});
        color_at_points({8'd255, 8'd225, 8'd225});         // 225+30 = 255, exact limit at the 8-bit edge
        color_at_points({8'd255, 8'd226, 8'd0});           // 226+30 = 256: an 8-bit adder would wrap to 0
        color_at_points({8'd255, 8'd0,   8'd226});
        color_at_points({8'd255, 8'd250, 8'd0});           // 250+30 = 280
        color_at_points({8'd255, 8'd0,   8'd250});
        color_at_points({8'd255, 8'd250, 8'd250});
        color_at_points({8'd255, 8'd200, 8'd0});           // C: 200+60 = 260 wraps to 4 in 8 bit
        color_at_points({8'd255, 8'd195, 8'd195});         // C: exactly 60
        color_at_points({8'd255, 8'd196, 8'd195});         // C: one too much
        color_at_points({8'd200, 8'd140, 8'd140});         // C: R_MIN and DELTA both exact
        color_at_points({8'd199, 8'd0,   8'd0});           // C: R_MIN-1
        color_at_points({8'd254, 8'd0,   8'd0});           // D: R below 255
        color_at_points({8'd255, 8'd1,   8'd0});           // D: DELTA 255 violated by 1
        color_at_points({8'd255, 8'd0,   8'd1});
        color_at_points({8'd10,  8'd10,  8'd10});          // F: equal channels hit
        color_at_points({8'd10,  8'd11,  8'd0});           // F: G > R
        color_at_points(24'h000000);                       // black (F hits, others do not)
        color_at_points(24'hFFFFFF);                       // white
        color_at_points(24'h505050);                       // grey at R_MIN
        color_at_points(24'hFF2010);                       // typical marker colour
        idle(2);

        // ---- ROI edges (marker colour everywhere so only the ROI decides)
        // B: [2,6) x [1,4)
        pv(24'hFF2010, 12'd1, 12'd2);  pv(24'hFF2010, 12'd2, 12'd2);
        pv(24'hFF2010, 12'd5, 12'd2);  pv(24'hFF2010, 12'd6, 12'd2);
        pv(24'hFF2010, 12'd3, 12'd0);  pv(24'hFF2010, 12'd3, 12'd1);
        pv(24'hFF2010, 12'd3, 12'd3);  pv(24'hFF2010, 12'd3, 12'd4);
        pv(24'hFF2010, 12'd2, 12'd1);  pv(24'hFF2010, 12'd5, 12'd3);   // inner corners
        pv(24'hFF2010, 12'd1, 12'd0);  pv(24'hFF2010, 12'd6, 12'd4);   // outer corners
        pv(24'hFF2010, 12'd1, 12'd1);  pv(24'hFF2010, 12'd6, 12'd3);
        // E: [100,200) x [50,60)
        pv(24'hFF2010, 12'd99,  12'd55); pv(24'hFF2010, 12'd100, 12'd55);
        pv(24'hFF2010, 12'd199, 12'd55); pv(24'hFF2010, 12'd200, 12'd55);
        pv(24'hFF2010, 12'd150, 12'd49); pv(24'hFF2010, 12'd150, 12'd50);
        pv(24'hFF2010, 12'd150, 12'd59); pv(24'hFF2010, 12'd150, 12'd60);
        pv(24'hFF2010, 12'd100, 12'd50); pv(24'hFF2010, 12'd199, 12'd59);
        pv(24'hFF2010, 12'd99,  12'd49); pv(24'hFF2010, 12'd200, 12'd60);
        pv(24'hFF2010, 12'd99,  12'd59); pv(24'hFF2010, 12'd200, 12'd50);
        // A/C/D/F: [0,1280) x [0,720), G: up to 4095
        pv(24'hFF0000, 12'd0,    12'd0);    pv(24'hFF0000, 12'd1279, 12'd719);
        pv(24'hFF0000, 12'd1280, 12'd719);  pv(24'hFF0000, 12'd1279, 12'd720);
        pv(24'hFF0000, 12'd1280, 12'd720);  pv(24'hFF0000, 12'd1281, 12'd5);
        pv(24'hFF0000, 12'd5,    12'd721);  pv(24'hFF0000, 12'd4095, 12'd4095);
        pv(24'hFF0000, 12'd4095, 12'd0);    pv(24'hFF0000, 12'd0,    12'd4095);
        // colour not a hit inside every ROI (ROI alone must not create a hit)
        pv(24'h202020, 12'd3, 12'd2);  pv(24'h202020, 12'd150, 12'd55);
        idle(3);

        // ---- threshold sweeps at coordinates inside B/A (3,2) and inside E (150,55)
        r_sweeps(8'd79,  12'd3, 12'd2);   r_sweeps(8'd79,  12'd150, 12'd55);
        r_sweeps(8'd80,  12'd3, 12'd2);   r_sweeps(8'd80,  12'd150, 12'd55);
        r_sweeps(8'd81,  12'd3, 12'd2);   r_sweeps(8'd81,  12'd150, 12'd55);
        r_sweeps(8'd110, 12'd3, 12'd2);   r_sweeps(8'd110, 12'd150, 12'd55);
        r_sweeps(8'd199, 12'd3, 12'd2);   r_sweeps(8'd199, 12'd150, 12'd55);
        r_sweeps(8'd200, 12'd3, 12'd2);   r_sweeps(8'd200, 12'd150, 12'd55);
        r_sweeps(8'd254, 12'd3, 12'd2);   r_sweeps(8'd254, 12'd150, 12'd55);
        r_sweeps(8'd255, 12'd3, 12'd2);   r_sweeps(8'd255, 12'd150, 12'd55);
        idle(3);

        // ---- R x G plane for several B values (65536 pixels each), B around DELTA edges
        for (k = 0; k < 7; k = k + 1) begin
            case (k)
                0: sel = 0;
                1: sel = 29;
                2: sel = 30;
                3: sel = 31;
                4: sel = 225;
                5: sel = 226;
                default: sel = 255;
            endcase
            for (i = 0; i < 256; i = i + 1)
                for (j = 0; j < 256; j = j + 1)
                    pv({i[7:0], j[7:0], sel[7:0]}, 12'd3, 12'd2);
        end
        idle(3);

        // ---- frames with sideband flags, continuous and with garbage blanking
        frame(8, 6, 0);
        idle(2);
        frame(8, 6, 1);
        frame(1, 1, 0);
        frame(1, 5, 1);
        frame(6, 1, 1);
        idle(3);

        // ---- random stream: 3/4 valid, random colours (half reddish), mixed coordinates
        for (i = 0; i < 300000; i = i + 1) begin
            c24 = $random(seed);
            if (($random(seed) & 1) == 0)
                c24 = {c24[23:16] | 8'h50, c24[15:8] >> (c24[2:0] & 3), c24[7:0] >> (c24[5:3] & 3)};
            case ($random(seed) & 3)
                0: begin rx = $random(seed) & 12'h007; ry = $random(seed) & 12'h007; end   // 0..7
                1: begin rx = 12'd90 + ($random(seed) & 12'h07F); ry = 12'd40 + ($random(seed) & 12'h01F); end
                2: begin rx = 12'd1272 + ($random(seed) & 12'h00F); ry = 12'd712 + ($random(seed) & 12'h00F); end
                default: begin rx = $random(seed); ry = $random(seed); end
            endcase
            if (($random(seed) & 3) != 0)
                pix(1'b1, c24, rx, ry, $random(seed), $random(seed), $random(seed));
            else
                pix(1'b0, c24, rx, ry, $random(seed), $random(seed), $random(seed));
        end
        idle(3);

        // ---- asynchronous reset in the middle of valid traffic
        for (i = 0; i < 12; i = i + 1) pv(24'hFF2010, 12'd3, 12'd2);
        @(negedge clk);
        #2 rst_n = 1'b0;
        in_de = 1'b1; in_rgb = 24'hFF0000; in_x = 12'd3; in_y = 12'd2;
        in_sof = 1'b1; in_eol = 1'b1; in_eof = 1'b1;
        pix(1'b1, 24'hFF0000, 12'd3, 12'd2, 1'b1, 1'b1, 1'b1);
        pix(1'b1, 24'hFF0000, 12'd3, 12'd2, 1'b1, 1'b1, 1'b1);
        #2 rst_n = 1'b1;
        for (i = 0; i < 12; i = i + 1) pv(24'hFF2010, 12'd3, 12'd2);
        idle(4);

`ifdef FULL_SWEEP
        // ---- colours [SWEEP_LO, SWEEP_HI) at (3,2); default = every colour (16.7 M clocks).
        //      Split over several processes with  vvp x.vvp +SWEEP_LO=n +SWEEP_HI=m
        sweep_lo = 0;
        sweep_hi = 16777216;
        if ($value$plusargs("SWEEP_LO=%d", sweep_lo)) sweep_lo = sweep_lo;
        if ($value$plusargs("SWEEP_HI=%d", sweep_hi)) sweep_hi = sweep_hi;
        $display("tb_color_segment: FULL_SWEEP colours %0d..%0d", sweep_lo, sweep_hi - 1);
        for (i = sweep_lo; i < sweep_hi; i = i + 1) begin
            c24 = i;
            pv(c24, 12'd3, 12'd2);
        end
        idle(4);
`endif

        idle(5);
        check_en = 1'b0;

        total_err = eA + eB + eC + eD + eE + eF + eG + oA + oB + oC + oD + oE + oF + oG;
        total_chk = cA;
        $display("tb_color_segment: clocks=%0d errors A=%0d B=%0d C=%0d D=%0d E=%0d F=%0d G=%0d oracle_selftest_errors=%0d",
                 total_chk, eA, eB, eC, eD, eE, eF, eG, oA);
        $display("tb_color_segment: oracle hits A=%0d B=%0d C=%0d D=%0d E=%0d F=%0d G=%0d",
                 hA, hB, hC, hD, hE, hF, hG);

        // coverage: every instance must have produced hits, and the stream must be long
        if (cA < 600000 || hA < 1000 || hB < 100 || hC < 100 || hD < 5 || hE < 5 || hF < 1000 || hG < 1000) begin
            total_err = total_err + 1;
            $display("COVERAGE too low: test would be vacuous");
        end
        if (total_err == 0) $display("TB_RESULT: PASS tb_color_segment");
        else                $display("TB_RESULT: FAIL tb_color_segment errors=%0d", total_err);
        $finish;
    end

endmodule
