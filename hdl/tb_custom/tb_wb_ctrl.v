// tb_wb_ctrl.v - self-check of rtl_custom/wb_ctrl.v (white-balance page control)
//
// Small timing parameters (KEY_DEB 4, REP_DELAY 200, REP_PER 50, REP_FAST 60000, LONG_PRESS 400 clocks). Checks:
//   * reset state: AUTO, R selected, manual gains 1.00 (Q4.12 4096);
//   * keys are ignored while the page is inactive, and a press that started on the page but ends after leaving it does nothing;
//   * KEY4 alone cycles AUTO -> MAN -> OFF -> AUTO, entering MAN takes over the applied gains (one-push), KEY3 alone selects R -> G -> B -> R,
//     KEY3 + KEY4 together (either order, either release order) changes neither, KEY1 + KEY2 together does not step;
//   * KEY1 / KEY2 in AUTO or OFF switch to MAN starting from the applied gains, single steps of 0.01, clamping at 0.25 / 4.00;
//   * a full sweep 1.00 -> 0.25 -> 8.00 with auto-repeat: every value 25..800 hundredths appears once and man = round(h * 4096 / 100) exactly
//     (computed here as (h * 4096 + 50) / 100), steps of exactly 1 before REP_FAST and of 5 (or up to the clamp) after it;
//   * KEY4 held alone for LONG_PRESS: MAN with 1.00 / 1.00 / 1.00, nothing at the release;
//   * display digits: gains in hundredths round(cur * 100 / 4096) ((cur * 100 + 2048) / 4096 here), shown as at most 9.99, for 3,000 values
//     (edges + random), and the averages 0..255 as three BCD digits.
// Run: iverilog -g2005 -o sim_wbc.vvp tb_wb_ctrl.v ../rtl_custom/wb_ctrl.v ../rtl_custom/key_debounce.v ; vvp sim_wbc.vvp
// Final line: TB_RESULT: PASS tb_wb_ctrl  or  FAIL

`timescale 1ns / 1ps

module tb_wb_ctrl;

    localparam integer REP_DELAY = 200, REP_PER = 50, REP_FAST = 60000, LONG_PRESS = 400;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg         active;
    reg  [3:0]  key_n;
    reg  [15:0] cur_r, cur_g, cur_b;
    reg  [7:0]  avg_r, avg_g, avg_b;
    wire [1:0]  wb_mode, sel;
    wire [15:0] man_r, man_g, man_b;
    wire [71:0] digits;

    wb_ctrl #(.KEY_DEB(4), .REP_DELAY(REP_DELAY), .REP_PER(REP_PER), .REP_FAST(REP_FAST), .LONG_PRESS(LONG_PRESS)) dut (
        .clk(clk), .rst_n(rst_n), .active(active), .key_n(key_n), .cur_r(cur_r), .cur_g(cur_g), .cur_b(cur_b),
        .avg_r(avg_r), .avg_g(avg_g), .avg_b(avg_b), .wb_mode(wb_mode), .sel(sel), .man_r(man_r), .man_g(man_g), .man_b(man_b), .digits(digits));

    integer errors;
    integer checks;

    function [15:0] conv;                        // hundredths -> Q4.12, round to nearest
        input integer h;
        begin conv = (h * 4096 + 50) / 100; end
    endfunction
    function integer hund;                       // Q4.12 -> hundredths, round to nearest
        input integer g;
        begin hund = (g * 100 + 2048) / 4096; end
    endfunction

    task expect_state;
        input [8*24-1:0] what;
        input [1:0]  m;
        input [1:0]  s;
        input integer hr, hg, hb;
        begin
            repeat (40) @(negedge clk);                  // the Q4.12 conversion runs sequentially (~36 clocks for the three channels)
            checks = checks + 1;
            if (wb_mode !== m || sel !== s || man_r !== conv(hr) || man_g !== conv(hg) || man_b !== conv(hb)) begin
                errors = errors + 1;
                $display("MISMATCH %0s: mode %0d sel %0d man %0d %0d %0d, expected mode %0d sel %0d man %0d %0d %0d (h %0d %0d %0d)",
                         what, wb_mode, sel, man_r, man_g, man_b, m, s, conv(hr), conv(hg), conv(hb), hr, hg, hb);
            end
        end
    endtask

    // key k (0..3) down / up, then let the debouncer and the pipeline settle
    task kdown; input integer k; begin @(negedge clk); key_n[k] = 1'b0; repeat (12) @(negedge clk); end endtask
    task kup;   input integer k; begin @(negedge clk); key_n[k] = 1'b1; repeat (12) @(negedge clk); end endtask
    task tap;   input integer k; begin kdown(k); kup(k); repeat (6) @(negedge clk); end endtask

    // ---------------- a second instance with a short REP_FAST for the accelerated steps (same keys)
    localparam integer REP_FAST2 = 1000;
    wire [1:0]  wb_mode2, sel2;
    wire [15:0] man2_r, man2_g, man2_b;
    wire [71:0] digits2;
    wb_ctrl #(.KEY_DEB(4), .REP_DELAY(REP_DELAY), .REP_PER(REP_PER), .REP_FAST(REP_FAST2), .LONG_PRESS(LONG_PRESS)) dut2 (
        .clk(clk), .rst_n(rst_n), .active(active), .key_n(key_n), .cur_r(cur_r), .cur_g(cur_g), .cur_b(cur_b),
        .avg_r(avg_r), .avg_g(avg_g), .avg_b(avg_b), .wb_mode(wb_mode2), .sel(sel2), .man_r(man2_r), .man_g(man2_g), .man_b(man2_b), .digits(digits2));
    reg        f2_on;
    integer    f2_h, f2_n1, f2_n5, f2_t, f2_hh, f2_i;
    reg [15:0] man2_q;
    initial begin f2_on = 1'b0; man2_q = 16'd4096; end
    always @(posedge clk) begin
        if (f2_on) f2_t = f2_t + 1;
        if (f2_on && man2_r !== man2_q) begin
            f2_hh = -1;
            for (f2_i = 25; f2_i <= 800; f2_i = f2_i + 1) if (conv(f2_i) == man2_r) f2_hh = f2_i;
            if (f2_h - f2_hh == 1 && f2_t < REP_FAST2 + 60) f2_n1 = f2_n1 + 1;      // + 60: the sequential conversion delays the change by up to ~36 clocks
            else if ((f2_h - f2_hh == 5 || (f2_hh == 25 && f2_h - f2_hh < 5)) && f2_t > REP_FAST2) f2_n5 = f2_n5 + 1;
            else begin errors = errors + 1; $display("MISMATCH fast test: %0d -> %0d after %0d clocks", f2_h, f2_hh, f2_t); end
            f2_h = f2_hh;
        end
        man2_q <= man2_r;
    end

    // ---------------- sweep monitor: every change of man_r while sweeping
    reg        mon_on;
    integer    mon_h, mon_seen, mon_bad, mon_dir, mon_fast_ok;
    reg [15:0] man_r_q;
    reg        seen [0:800];
    integer    i, hh, step;
    initial begin mon_on = 1'b0; man_r_q = 16'd4096; end
    always @(posedge clk) begin
        if (mon_on && man_r !== man_r_q) begin
            // find the hundredths value of the new gain
            hh = -1;
            for (i = 25; i <= 800; i = i + 1) if (conv(i) == man_r) hh = i;
            if (hh < 0) begin mon_bad = mon_bad + 1; if (mon_bad < 5) $display("MISMATCH sweep: man_r %0d is no rounded hundredths value", man_r); end
            else begin
                step = hh - mon_h;
                if (mon_dir * step <= 0) begin mon_bad = mon_bad + 1; if (mon_bad < 5) $display("MISMATCH sweep: step %0d against the direction", step); end
                else if (!mon_fast_ok && step * mon_dir != 1) begin mon_bad = mon_bad + 1; if (mon_bad < 5) $display("MISMATCH sweep: step %0d before REP_FAST", step); end
                else if (mon_fast_ok && step * mon_dir != 5 && !(hh == 25 || hh == 800)) begin mon_bad = mon_bad + 1; if (mon_bad < 5) $display("MISMATCH sweep: fast step %0d", step); end
                seen[hh] = 1'b1;
                mon_h = hh; mon_seen = mon_seen + 1;
            end
        end
        man_r_q <= man_r;
    end

    // ---------------- display digits
    function [11:0] bcd3;
        input integer v;
        reg [3:0] a, b, c;
        begin a = v / 100; b = (v / 10) % 10; c = v % 10; bcd3 = {a, b, c}; end
    endfunction
    integer seed, n, vr, vg, vb, er, eg, eb;
    task digit_case;
        input integer r, g, b;
        begin
            @(negedge clk); cur_r = r; cur_g = g; cur_b = b;
            repeat (160) @(negedge clk);
            er = hund(r); eg = hund(g); eb = hund(b);
            if (er > 999) er = 999; if (eg > 999) eg = 999; if (eb > 999) eb = 999;
            checks = checks + 1;
            if (digits[71:36] !== {bcd3(er), bcd3(eg), bcd3(eb)}) begin
                errors = errors + 1;
                if (errors < 20) $display("MISMATCH digits for gains %0d %0d %0d: got %h expected %h", r, g, b, digits[71:36], {bcd3(er), bcd3(eg), bcd3(eb)});
            end
        end
    endtask

    initial begin
        errors = 0; checks = 0; seed = 1234;
        active = 1'b0; key_n = 4'b1111; cur_r = 16'd4096; cur_g = 16'd4096; cur_b = 16'd4096; avg_r = 8'd0; avg_g = 8'd0; avg_b = 8'd0;
        mon_h = 100; mon_seen = 0; mon_bad = 0; mon_dir = 1; mon_fast_ok = 0;
        for (i = 0; i <= 800; i = i + 1) seen[i] = 1'b0;
        rst_n = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        expect_state("reset", 2'd0, 2'd0, 100, 100, 100);

        // applied gains R 1.35, G 1.00, B 0.88
        cur_r = 16'd5530; cur_g = 16'd4096; cur_b = 16'd3604;
        repeat (10) @(negedge clk);

        // ---- inactive: nothing happens
        tap(3); tap(2); tap(1); tap(0);
        expect_state("keys while inactive", 2'd0, 2'd0, 100, 100, 100);
        // a press that starts on the page and ends after leaving it
        active = 1'b1; kdown(3); active = 1'b0; kup(3); active = 1'b1; repeat (5) @(negedge clk);
        expect_state("release after leaving the page", 2'd0, 2'd0, 100, 100, 100);
        active = 1'b1; kdown(2); active = 1'b0; kup(2); active = 1'b1; repeat (5) @(negedge clk);
        expect_state("KEY3 released after leaving", 2'd0, 2'd0, 100, 100, 100);
        // presses that start off the page and end on it
        active = 1'b0; kdown(3); active = 1'b1; kup(3); repeat (5) @(negedge clk);
        expect_state("KEY4 pressed before entering", 2'd0, 2'd0, 100, 100, 100);
        active = 1'b0; kdown(2); active = 1'b1; kup(2); repeat (5) @(negedge clk);
        expect_state("KEY3 pressed before entering", 2'd0, 2'd0, 100, 100, 100);
        active = 1'b1;
        // the page goes away exactly between the debounced release and the clock that acts on it
        kdown(3); @(negedge clk); key_n[3] = 1'b1; wait (dut.kd[3] == 1'b0); @(negedge clk); active = 1'b0; repeat (12) @(negedge clk); active = 1'b1;
        expect_state("KEY4 release as the page leaves", 2'd0, 2'd0, 100, 100, 100);
        kdown(2); @(negedge clk); key_n[2] = 1'b1; wait (dut.kd[2] == 1'b0); @(negedge clk); active = 1'b0; repeat (12) @(negedge clk); active = 1'b1;
        expect_state("KEY3 release as the page leaves", 2'd0, 2'd0, 100, 100, 100);

        // ---- KEY4 alone: AUTO -> MAN (one-push: takes over 1.35 / 1.00 / 0.88)
        tap(3);
        expect_state("one-push MAN", 2'd2, 2'd0, 135, 100, 88);
        // ---- KEY2: R + 0.01, KEY3: select G, KEY1: G - 0.01
        tap(1);
        expect_state("R +", 2'd2, 2'd0, 136, 100, 88);
        tap(2);
        expect_state("select G", 2'd2, 2'd1, 136, 100, 88);
        tap(0);
        expect_state("G -", 2'd2, 2'd1, 136, 99, 88);
        tap(2);
        expect_state("select B", 2'd2, 2'd2, 136, 99, 88);
        tap(0); tap(0);
        expect_state("B - -", 2'd2, 2'd2, 136, 99, 86);
        tap(2);
        expect_state("select R again", 2'd2, 2'd0, 136, 99, 86);
        // ---- chords: KEY3 then KEY4, release KEY3 first; KEY4 then KEY3, release KEY4 first; KEY1 + KEY2
        kdown(2); kdown(3); kup(2); kup(3); repeat (5) @(negedge clk);
        expect_state("chord 3-4", 2'd2, 2'd0, 136, 99, 86);
        kdown(3); kdown(2); kup(3); kup(2); repeat (5) @(negedge clk);
        expect_state("chord 4-3", 2'd2, 2'd0, 136, 99, 86);
        kdown(0); kdown(1); repeat (100) @(negedge clk);
        // KEY1 went down first (one step -), then both: no further step; releasing KEY1 leaves KEY2 alone = one step +
        expect_state("KEY1 then KEY1+KEY2", 2'd2, 2'd0, 135, 99, 86);
        kup(0); kup(1); repeat (5) @(negedge clk);
        expect_state("KEY1 then KEY1+KEY2 then KEY2", 2'd2, 2'd0, 136, 99, 86);
        // ---- auto-repeat timing: held shorter than REP_DELAY = one step; REP_DELAY + 3.5 REP_PER = 1 + 3 or 4 steps
        kdown(1); repeat (REP_DELAY - 40) @(negedge clk); kup(1);
        expect_state("hold below REP_DELAY", 2'd2, 2'd0, 137, 99, 86);
        kdown(1); repeat (REP_DELAY + 3 * REP_PER + REP_PER / 2 - 12) @(negedge clk); kup(1); repeat (40) @(negedge clk);
        checks = checks + 1;
        if (man_r !== conv(141) && man_r !== conv(142)) begin errors = errors + 1; $display("MISMATCH repeat timing: man_r %0d, expected %0d or %0d", man_r, conv(141), conv(142)); end
        tap(0); tap(0); tap(0); tap(0); tap(0);
        repeat (40) @(negedge clk); if (man_r === conv(137)) tap(0);
        expect_state("back to 1.36", 2'd2, 2'd0, 136, 99, 86);
        // ---- MAN -> OFF -> AUTO
        tap(3);
        expect_state("OFF", 2'd1, 2'd0, 136, 99, 86);
        tap(3);
        expect_state("AUTO", 2'd0, 2'd0, 136, 99, 86);
        // ---- KEY1 in AUTO: MAN from the applied gains, one step on R
        cur_r = 16'd4710; cur_g = 16'd4219; cur_b = 16'd3277;          // 1.15 / 1.03 / 0.80
        repeat (10) @(negedge clk);
        tap(0);
        expect_state("KEY1 in AUTO", 2'd2, 2'd0, 114, 103, 80);
        // ---- KEY2 in OFF (applied gains 1.00): MAN from 1.00
        tap(3); cur_r = 16'd4096; cur_g = 16'd4096; cur_b = 16'd4096; repeat (10) @(negedge clk);
        expect_state("OFF again", 2'd1, 2'd0, 114, 103, 80);
        tap(2);                                                          // select G
        tap(1);
        expect_state("KEY2 in OFF", 2'd2, 2'd1, 100, 101, 100);
        // ---- clamps of the one-push capture: applied gains beyond the manual range
        tap(3); tap(3);                                                  // OFF, AUTO
        cur_r = 16'd40000; cur_g = 16'd200; cur_b = 16'd16384; repeat (10) @(negedge clk);
        tap(3);
        expect_state("capture clamps", 2'd2, 2'd1, 800, 25, 400);
        // ---- KEY4 long press: all 1.00, the release does nothing
        kdown(3); repeat (LONG_PRESS + 20) @(negedge clk);
        expect_state("long press (held)", 2'd2, 2'd1, 100, 100, 100);
        kup(3); repeat (5) @(negedge clk);
        expect_state("long press (released)", 2'd2, 2'd1, 100, 100, 100);
        // a long press of KEY4 with KEY3 down meanwhile: nothing (G is moved off 1.00 first, so a wrong reset would show)
        tap(1);
        expect_state("G + before the long chord", 2'd2, 2'd1, 100, 101, 100);
        kdown(3); kdown(2); repeat (LONG_PRESS + 20) @(negedge clk); kup(2); kup(3); repeat (5) @(negedge clk);
        expect_state("long chord", 2'd2, 2'd1, 100, 101, 100);
        tap(0);

        // ---- sweep of R: 1.00 -> 0.25 (hold KEY1), -> 4.00 (hold KEY2), single steps; then fast steps down
        tap(2); tap(2);                                                  // G -> B -> R
        expect_state("sweep start", 2'd2, 2'd0, 100, 100, 100);
        seen[100] = 1'b1;
        mon_h = 100; mon_dir = -1; mon_fast_ok = 0; mon_on = 1'b1;
        kdown(0); repeat (REP_DELAY + 80 * REP_PER) @(negedge clk); kup(0);
        expect_state("sweep at 0.25", 2'd2, 2'd0, 25, 100, 100);
        mon_dir = 1;
        kdown(1); repeat (REP_DELAY + 780 * REP_PER) @(negedge clk); kup(1);
        expect_state("sweep at 8.00", 2'd2, 2'd0, 800, 100, 100);
        mon_on = 1'b0;
        n = 0; for (i = 25; i <= 800; i = i + 1) if (seen[i]) n = n + 1;
        if (n != 776) begin errors = errors + 1; $display("MISMATCH sweep covered %0d of the 776 values 25..800", n); end
        if (mon_bad) errors = errors + mon_bad;
        $display("sweep: %0d gain changes, %0d of 776 values seen, final R %0d hundredths", mon_seen, n, mon_h);
        // fast steps: dut2 (REP_FAST2) followed the same keys; it is at 8.00 too. Hold KEY1: single steps, then steps of 5, then the clamp at 0.25
        if (man2_r !== conv(800)) begin errors = errors + 1; $display("MISMATCH dut2 not at 8.00 before the fast test (%0d)", man2_r); end
        f2_on = 1'b1; f2_h = 800; f2_n1 = 0; f2_n5 = 0; f2_t = 0;
        kdown(0); repeat (REP_FAST2 + 200 * REP_PER) @(negedge clk); kup(0); repeat (40) @(negedge clk);
        f2_on = 1'b0;
        $display("fast test: %0d single steps, %0d steps of 5, final %0d hundredths", f2_n1, f2_n5, f2_h);
        if (f2_n1 < 10 || f2_n5 < 10 || f2_h != 25) begin errors = errors + 1; $display("MISMATCH fast steps"); end

        // ---- display digits
        avg_r = 8'd0; avg_g = 8'd99; avg_b = 8'd255;
        digit_case(0, 1, 20); digit_case(21, 4095, 4096); digit_case(4097, 32768, 65535); digit_case(40919, 40940, 40960);
        digit_case(5530, 3604, 1024); digit_case(2047, 2048, 2049);
        for (n = 0; n < 3000; n = n + 1) begin
            vr = $random(seed) & 16'hFFFF; vg = $random(seed) & 16'h7FFF; vb = 1024 + ($random(seed) & 16'h3FFF);
            digit_case(vr, vg, vb);
        end
        for (n = 0; n < 256; n = n + 1) begin
            @(negedge clk); avg_r = n; avg_g = 255 - n; avg_b = (n * 7) & 255;
            repeat (160) @(negedge clk);
            checks = checks + 1;
            if (digits[35:0] !== {bcd3(n), bcd3(255 - n), bcd3((n * 7) & 255)}) begin
                errors = errors + 1;
                if (errors < 20) $display("MISMATCH avg digits %0d: got %h", n, digits[35:0]);
            end
        end

        $display("tb_wb_ctrl: %0d checks, errors=%0d", checks, errors);
        if (errors == 0) $display("TB_RESULT: PASS tb_wb_ctrl");
        else             $display("TB_RESULT: FAIL tb_wb_ctrl errors=%0d", errors);
        $finish;
    end

endmodule
