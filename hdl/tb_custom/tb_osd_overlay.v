// tb_osd_overlay.v - pixel-exact self-checking testbench for rtl_custom/osd_overlay.v
//
// Seven full 1280x720 frames are streamed through the DUT (default parameters). The expected output of
// every pixel comes from the INDEPENDENT Python golden model tb_custom/gen_osd_golden.py (it only
// shares the font/logo assets with the RTL): a sparse list of the pixels that differ from the
// synthetic background, everything else must equal the background exactly.
//   frame 0: all layers except the line, target found       frame 1: box over logo/text, count/cross saturate, line at x=0
//   frame 2: all layers, target LOST ('----', no box/cross)   frame 3: no text, box/cross/line at the frame corner
//   frame 4: nothing enabled -> output must equal the input  frame 5: box whose outer frame covers pixel (0,0), box+cross only
//   frame 6: text only
// Frames 1 and 5 are chosen so that the first pixel (0,0), which carries in_sof, already needs the NEW control values.
// The next frame's control values are applied in the MIDDLE of the current frame (pixel 400000):
// they must not change the current frame (sampled at in_sof), and must be fully effective in the next.
//
// Checked every clock: out_de, out_rgb, out_x, out_y, out_sof/eol/eof against the golden expectation
// delayed by exactly the 3 clocks of the DUT latency; blanking (de = 0, with garbage rgb/sof/eol/eof
// on the input) must give all-zero outputs.
//
// Needs the golden files: python gen_osd_golden.py (run_all.ps1 does it). Directory: +GOLDEN=<dir>,
// default osd_assets/golden (relative to the working directory tb_custom).
//
// Build/run (Icarus Verilog), from F:\fpga_s2\tb_custom:
//   python gen_osd_golden.py
//   iverilog -g2005 -Wall -o sim_osd.vvp tb_osd_overlay.v ../rtl_custom/osd_overlay.v ../rtl_custom/osd_bin2bcd.v ../rtl_custom/osd_font_rom.v ../rtl_custom/osd_logo_rom.v
//   vvp sim_osd.vvp
// Final line: "TB_RESULT: PASS ..." or "TB_RESULT: FAIL ...".

`timescale 1ns / 1ps

module tb_osd_overlay;

    localparam integer W   = 1280;
    localparam integer H   = 720;
    localparam integer NF  = 7;
    localparam integer LAT = 3;            // contract latency of osd_overlay
    localparam integer CHANGE_AT = 400000; // pixel index (inside the frame) where the next frame's controls are applied

    reg         clk;
    reg         rst_n;
    reg         in_de;
    reg  [23:0] in_rgb;
    reg  [11:0] in_x, in_y;
    reg         in_sof, in_eol, in_eof;

    reg  [4:0]  cfg_flags;
    reg  [1:0]  cfg_mode;
    reg         tgt_valid;
    reg  [11:0] tgt_xmin, tgt_xmax, tgt_ymin, tgt_ymax, tgt_cx, tgt_cy;
    reg  [19:0] tgt_count;
    reg  [11:0] line_x;
    reg  [15:0] cross_cnt;

    wire        out_de, out_sof, out_eol, out_eof;
    wire [23:0] out_rgb;
    wire [11:0] out_x, out_y;

    osd_overlay dut (
        .clk(clk), .rst_n(rst_n),
        .in_de(in_de), .in_rgb(in_rgb), .in_x(in_x), .in_y(in_y),
        .in_sof(in_sof), .in_eol(in_eol), .in_eof(in_eof),
        .cfg_flags(cfg_flags), .cfg_mode(cfg_mode), .tgt_valid(tgt_valid),
        .tgt_xmin(tgt_xmin), .tgt_xmax(tgt_xmax), .tgt_ymin(tgt_ymin), .tgt_ymax(tgt_ymax),
        .tgt_cx(tgt_cx), .tgt_cy(tgt_cy), .tgt_count(tgt_count), .line_x(line_x), .cross_cnt(cross_cnt),
        .out_de(out_de), .out_rgb(out_rgb), .out_x(out_x), .out_y(out_y),
        .out_sof(out_sof), .out_eol(out_eol), .out_eof(out_eof)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- synthetic background, same formula as the Python model
    function [23:0] bgf;
        input integer x;
        input integer y;
        integer r, g, b;
        begin
            r = (x * 5 + y * 3) % 256;
            g = (x ^ y) % 256;
            b = (x * 2 + (y / 2)) % 256;
            bgf = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    // ---------------- golden data
    reg [8*256-1:0] gdir;
    reg [8*256-1:0] fname;
    reg [127:0]     stmem [0:0];
    reg [127:0]     stv [0:NF-1];
    reg [47:0]      sp [0:131071];
    integer         spi;

    task apply_state;
        input integer k;
        begin
            {cfg_flags, cfg_mode, tgt_valid, tgt_xmin, tgt_xmax, tgt_ymin, tgt_ymax,
             tgt_cx, tgt_cy, tgt_count, line_x, cross_cnt} = stv[k];
        end
    endtask

    // ---------------- expected record pipeline (LAT stages): {de, rgb, x, y, sof, eol, eof}
    reg [51:0] eq0;
    reg [51:0] eq1, eq2, eq3;
    always @(posedge clk) begin
        eq1 <= eq0;
        eq2 <= eq1;
        eq3 <= eq2;
    end

    integer errors;
    integer compared;
    integer ndiff_total;
    integer ndiff_frame;
    integer cur_frame;
    integer seed;
    reg     chk_en;

    task bad;
        input [127:0] what;
        input [51:0]  exp_v;
        input [51:0]  act_v;
        begin
            errors = errors + 1;
            if (errors <= 10)
                $display("MISMATCH frame=%0d t=%0t %0s expected=%h actual=%h (output x=%0d y=%0d)",
                         cur_frame, $time, what, exp_v, act_v, out_x, out_y);
            if (errors >= 100) begin
                $display("TB_RESULT: FAIL tb_osd_overlay aborted after %0d mismatches", errors);
                $finish;
            end
        end
    endtask

    wire [51:0] act = {out_de, out_rgb, out_x, out_y, out_sof, out_eol, out_eof};

    always @(negedge clk) begin
        if (chk_en) begin
            compared = compared + 1;
            if (act !== eq3) begin
                if (out_de !== eq3[51])            bad("out_de",  eq3, act);
                else if (out_rgb !== eq3[50:27])   bad("out_rgb", eq3, act);
                else                               bad("out_xy_sideband", eq3, act);
            end
        end
    end

    // ---------------- stimulus
    task idle;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                in_de  = 1'b0;
                in_rgb = $random(seed);
                in_x   = $random(seed);
                in_y   = $random(seed);
                in_sof = $random(seed);        // garbage flags while de = 0 must be ignored
                in_eol = $random(seed);
                in_eof = $random(seed);
                eq0    = 52'd0;
            end
        end
    endtask

    task run_frame;
        input integer k;
        integer x, y, idx;
        reg [23:0] e;
        reg [23:0] bg;
        begin
            cur_frame = k;
            ndiff_frame = 0;
            $sformat(fname, "%0s/exp_%0d.hex", gdir, k);
            $readmemh(fname, sp);
            spi = 0;
            for (y = 0; y < H; y = y + 1) begin
                for (x = 0; x < W; x = x + 1) begin
                    idx = y * W + x;
                    bg  = bgf(x, y);
                    if (sp[spi][47:24] == idx) begin
                        e = sp[spi][23:0];
                        spi = spi + 1;
                        ndiff_frame = ndiff_frame + 1;
                    end
                    else begin
                        e = bg;
                    end
                    @(negedge clk);
                    in_de  = 1'b1;
                    in_rgb = bg;
                    in_x   = x;
                    in_y   = y;
                    in_sof = (x == 0) && (y == 0);
                    in_eol = (x == W - 1);
                    in_eof = (x == W - 1) && (y == H - 1);
                    eq0    = {1'b1, e, x[11:0], y[11:0], in_sof, in_eol, in_eof};
                    if (idx == CHANGE_AT && k + 1 < NF) apply_state(k + 1);
                end
                // short horizontal blanking after some lines inside the frame: de = 0 with garbage sof/eol/eof.
                // A stray sof here must NOT re-sample the controls (they were changed mid-frame and have to stay
                // unused until the next real frame start); this is what the real uivtc stream does every line
                if ((y % 5) == 4 && y < H - 1) idle(2);
            end
            ndiff_total = ndiff_total + ndiff_frame;
            $display("tb_osd_overlay: frame %0d done, pixels differing from background %0d", k, ndiff_frame);
        end
    endtask

    integer k;
    initial begin
        errors = 0; compared = 0; ndiff_total = 0; ndiff_frame = 0; cur_frame = 0; seed = 32'h5EED0007;
        chk_en = 1'b0;
        in_de = 1'b0; in_rgb = 24'd0; in_x = 12'd0; in_y = 12'd0; in_sof = 1'b0; in_eol = 1'b0; in_eof = 1'b0;
        eq0 = 52'd0;
        if (!$value$plusargs("GOLDEN=%s", gdir)) gdir = "osd_assets/golden";
        for (k = 0; k < NF; k = k + 1) begin
            $sformat(fname, "%0s/state_%0d.hex", gdir, k);
            $readmemh(fname, stmem);
            stv[k] = stmem[0];
        end
        apply_state(0);
        rst_n = 1'b0;
        $display("tb_osd_overlay: golden dir '%0s', %0d frames of %0dx%0d", gdir, NF, W, H);
        repeat (4) @(negedge clk);
        #2 rst_n = 1'b1;
        idle(150);                            // controls stable well before the first sof
        chk_en = 1'b1;
        for (k = 0; k < NF; k = k + 1) begin
            run_frame(k);
            idle(150);
        end
        idle(LAT + 4);
        chk_en = 1'b0;

        $display("tb_osd_overlay: compared %0d clocks, differing-from-background pixels in golden %0d, errors %0d",
                 compared, ndiff_total, errors);
        if (compared < NF * W * H || ndiff_total < 250000) begin
            errors = errors + 1;
            $display("COVERAGE too low: test would be vacuous");
        end
        if (errors == 0) $display("TB_RESULT: PASS tb_osd_overlay");
        else             $display("TB_RESULT: FAIL tb_osd_overlay errors=%0d", errors);
        $finish;
    end

endmodule
