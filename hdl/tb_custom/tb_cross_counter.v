// tb_cross_counter.v - self-checking test of rtl_custom/cross_counter.v
//
// Three DUTs see the same stimulus:
//   A  HYST=12 CONFIRM=2 LOST_MAX=5 CNT_W=16   (defaults)
//   B  HYST=0  CONFIRM=1 LOST_MAX=0 CNT_W=3    (most sensitive, tiny counters -> saturation)
//   C  HYST=20 CONFIRM=3 LOST_MAX=2 CNT_W=16
// Two independent kinds of checks:
//   1. directed scenarios (line_x = 640) whose per-DUT crossing counts were worked out by hand (see the comments);
//      they are compared with the DUT outputs after each scenario;
//   2. a behavioural reference model written here with plain integers (not the structure of the RTL), compared with
//      EVERY output of every DUT (side, evt, evt_dir, cnt_lr, cnt_rl, cnt_total) after EVERY clock, in the directed
//      scenarios and in a long random run (random walks across the line, random lost-target bursts, random line_x
//      incl. 0 / 4095, idle clocks with garbage inputs between samples, back-to-back samples, resets).
// Inputs are changed on the falling clock edge, outputs are compared on the next falling edge (one clock after upd).
// The testbench also checks that the random run really reached the interesting corners (coverage counters).
//
// Build/run (Icarus Verilog), from F:\fpga_s2\tb_custom:
//   iverilog -g2005 -Wall -o sim_cross.vvp tb_cross_counter.v ../rtl_custom/cross_counter.v && vvp sim_cross.vvp
// Final line: "TB_RESULT: PASS tb_cross_counter" or "TB_RESULT: FAIL tb_cross_counter errors=N".

`timescale 1ns / 1ps

module tb_cross_counter;

    reg         clk;
    reg         rst_n;
    reg         upd;
    reg         valid;
    reg  [11:0] cx;
    reg  [11:0] line_x;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    wire        evtA, evtB, evtC, dirA, dirB, dirC;
    wire [15:0] lrA, rlA, totA, lrC, rlC, totC;
    wire [2:0]  lrB, rlB, totB;
    wire [1:0]  sdA, sdB, sdC;

    cross_counter #(.HYST(12), .CONFIRM(2), .LOST_MAX(5), .CNT_W(16)) dutA (
        .clk(clk), .rst_n(rst_n), .upd(upd), .valid(valid), .cx(cx), .line_x(line_x),
        .evt(evtA), .evt_dir(dirA), .cnt_lr(lrA), .cnt_rl(rlA), .cnt_total(totA), .side(sdA));
    cross_counter #(.HYST(0), .CONFIRM(1), .LOST_MAX(0), .CNT_W(3)) dutB (
        .clk(clk), .rst_n(rst_n), .upd(upd), .valid(valid), .cx(cx), .line_x(line_x),
        .evt(evtB), .evt_dir(dirB), .cnt_lr(lrB), .cnt_rl(rlB), .cnt_total(totB), .side(sdB));
    cross_counter #(.HYST(20), .CONFIRM(3), .LOST_MAX(2), .CNT_W(16)) dutC (
        .clk(clk), .rst_n(rst_n), .upd(upd), .valid(valid), .cx(cx), .line_x(line_x),
        .evt(evtC), .evt_dir(dirC), .cnt_lr(lrC), .cnt_rl(rlC), .cnt_total(totC), .side(sdC));

    // ---------------------------------------------------------------- reference model (plain integers)
    integer H  [0:2];
    integer CF [0:2];
    integer LM [0:2];
    integer CMAX [0:2];
    integer r_side [0:2];       // 0 unknown, 1 left, 2 right
    integer r_cand [0:2];       // 0 none, 1 left, 2 right
    integer r_cc   [0:2];
    integer r_lost [0:2];
    integer r_lr   [0:2];
    integer r_rl   [0:2];
    integer r_tot  [0:2];
    integer r_evt  [0:2];
    integer r_dir  [0:2];

    // coverage of the corner cases in the random run
    integer cov_event, cov_forget, cov_candreset, cov_mid, cov_sat, cov_confirm_new, cov_lostzone, cov_lostresume;

    task ref_reset;
        integer i;
        begin
            for (i = 0; i < 3; i = i + 1) begin
                r_side[i] = 0; r_cand[i] = 0; r_cc[i] = 0; r_lost[i] = 0;
                r_lr[i] = 0; r_rl[i] = 0; r_tot[i] = 0; r_evt[i] = 0; r_dir[i] = 0;
            end
        end
    endtask

    // one clock of the reference: u = upd, v = valid, c = cx, ln = line_x
    task ref_clock;
        input integer u;
        input integer v;
        input integer c;
        input integer ln;
        integer i, zone, n, oldside;
        begin
            for (i = 0; i < 3; i = i + 1) begin
                r_evt[i] = 0;
                if (u) begin
                    if (!v)                    zone = 0;       // lost
                    else if (c < ln - H[i])    zone = 1;       // left
                    else if (c > ln + H[i])    zone = 3;       // right
                    else                       zone = 2;       // dead band
                    if (zone == 0) begin
                        if (r_lost[i] <= LM[i]) r_lost[i] = r_lost[i] + 1;
                        r_cand[i] = 0; r_cc[i] = 0;
                        if (r_lost[i] > LM[i]) begin
                            if (r_side[i] != 0) cov_forget = cov_forget + 1;
                            r_side[i] = 0;
                        end
                    end
                    else begin
                        if (r_lost[i] > 0 && r_lost[i] <= LM[i]) cov_lostresume = cov_lostresume + 1;
                        r_lost[i] = 0;
                        if (zone == 2) begin
                            if (r_cand[i] != 0) cov_candreset = cov_candreset + 1;
                            r_cand[i] = 0; r_cc[i] = 0; cov_mid = cov_mid + 1;
                        end
                        else begin
                            n = (zone == 1) ? 1 : 2;                // side code of this zone
                            if (n == r_side[i]) begin
                                if (r_cand[i] != 0) cov_candreset = cov_candreset + 1;
                                r_cand[i] = 0; r_cc[i] = 0;
                            end
                            else begin
                                if (r_cand[i] == n) r_cc[i] = r_cc[i] + 1;
                                else begin r_cand[i] = n; r_cc[i] = 1; end
                                if (r_cc[i] >= CF[i]) begin
                                    oldside = r_side[i];
                                    r_side[i] = n; r_cand[i] = 0; r_cc[i] = 0;
                                    if (oldside != 0) begin
                                        r_evt[i] = 1; cov_event = cov_event + 1;
                                        r_dir[i] = (oldside == 2) ? 1 : 0;
                                        if (r_tot[i] < CMAX[i]) r_tot[i] = r_tot[i] + 1; else cov_sat = cov_sat + 1;
                                        if (oldside == 2) begin if (r_rl[i] < CMAX[i]) r_rl[i] = r_rl[i] + 1; end
                                        else              begin if (r_lr[i] < CMAX[i]) r_lr[i] = r_lr[i] + 1; end
                                    end
                                    else cov_confirm_new = cov_confirm_new + 1;
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    // ---------------------------------------------------------------- checking
    integer errors;
    integer nchk;
    reg     chk_en;

    task bad;
        input [127:0] what;
        input integer inst;
        input integer e;
        input integer a;
        begin
            errors = errors + 1;
            if (errors <= 12)
                $display("MISMATCH t=%0t %0s dut=%0d expected=%0d actual=%0d", $time, what, inst, e, a);
            if (errors >= 100) begin
                $display("TB_RESULT: FAIL tb_cross_counter aborted after %0d mismatches", errors);
                $finish;
            end
        end
    endtask

    task compare_all;
        begin
            nchk = nchk + 1;
            if (evtA !== r_evt[0]) bad("evt", 0, r_evt[0], evtA);
            if (evtB !== r_evt[1]) bad("evt", 1, r_evt[1], evtB);
            if (evtC !== r_evt[2]) bad("evt", 2, r_evt[2], evtC);
            if (r_evt[0] && dirA !== r_dir[0]) bad("evt_dir", 0, r_dir[0], dirA);
            if (r_evt[1] && dirB !== r_dir[1]) bad("evt_dir", 1, r_dir[1], dirB);
            if (r_evt[2] && dirC !== r_dir[2]) bad("evt_dir", 2, r_dir[2], dirC);
            if (lrA !== r_lr[0]) bad("cnt_lr", 0, r_lr[0], lrA);
            if (lrB !== r_lr[1]) bad("cnt_lr", 1, r_lr[1], lrB);
            if (lrC !== r_lr[2]) bad("cnt_lr", 2, r_lr[2], lrC);
            if (rlA !== r_rl[0]) bad("cnt_rl", 0, r_rl[0], rlA);
            if (rlB !== r_rl[1]) bad("cnt_rl", 1, r_rl[1], rlB);
            if (rlC !== r_rl[2]) bad("cnt_rl", 2, r_rl[2], rlC);
            if (totA !== r_tot[0]) bad("cnt_total", 0, r_tot[0], totA);
            if (totB !== r_tot[1]) bad("cnt_total", 1, r_tot[1], totB);
            if (totC !== r_tot[2]) bad("cnt_total", 2, r_tot[2], totC);
            if (sdA !== r_side[0]) bad("side", 0, r_side[0], sdA);
            if (sdB !== r_side[1]) bad("side", 1, r_side[1], sdB);
            if (sdC !== r_side[2]) bad("side", 2, r_side[2], sdC);
        end
    endtask

    // one clock: compare the result of the previous clock, then apply new inputs and advance the reference.
    // u = upd, v = valid, c = cx, ln = line_x; when u = 0 the data inputs are driven with garbage by the caller
    task clock;
        input integer u;
        input integer v;
        input integer c;
        input integer ln;
        begin
            @(negedge clk);
            if (chk_en) compare_all;
            upd = u; valid = v; cx = c; line_x = ln;
            ref_clock(u, v, c, ln);
        end
    endtask

    // one frame sample, followed by n idle clocks with garbage data
    integer seed;
    task frame;
        input integer v;
        input integer c;
        input integer ln;
        input integer idle;
        integer k;
        begin
            clock(1, v, c, ln);
            for (k = 0; k < idle; k = k + 1) clock(0, $random(seed), $random(seed) & 4095, $random(seed) & 4095);
        end
    endtask

    task rep;                       // n identical samples back to back
        input integer n;
        input integer v;
        input integer c;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) frame(v, c, 640, 0);
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            if (chk_en) compare_all;
            rst_n = 1'b0; upd = 1'b0;
            ref_reset;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            r_evt[0] = 0; r_evt[1] = 0; r_evt[2] = 0;
        end
    endtask

    // directed expectation: per DUT {lr, rl}, called after the scenario (one extra clock lets the outputs settle)
    task expect3;
        input integer a_lr, a_rl, b_lr, b_rl, c_lr, c_rl;
        begin
            clock(0, 0, 0, 640);
            clock(0, 0, 0, 640);
            if (lrA !== a_lr || rlA !== a_rl) bad("directed A lr/rl", 0, a_lr * 100 + a_rl, lrA * 100 + rlA);
            if (lrB !== b_lr || rlB !== b_rl) bad("directed B lr/rl", 1, b_lr * 100 + b_rl, lrB * 100 + rlB);
            if (lrC !== c_lr || rlC !== c_rl) bad("directed C lr/rl", 2, c_lr * 100 + c_rl, lrC * 100 + rlC);
        end
    endtask

    // ---------------------------------------------------------------- stimulus
    integer i, j, pos, step, lostburst, lnv, r;
    integer total_frames;

    initial begin
        errors = 0; nchk = 0; chk_en = 1'b0; seed = 32'h5EED0009; total_frames = 0;
        cov_event = 0; cov_forget = 0; cov_candreset = 0; cov_mid = 0; cov_sat = 0; cov_confirm_new = 0;
        cov_lostzone = 0; cov_lostresume = 0;
        H[0] = 12; CF[0] = 2; LM[0] = 5; CMAX[0] = 65535;
        H[1] = 0;  CF[1] = 1; LM[1] = 0; CMAX[1] = 7;
        H[2] = 20; CF[2] = 3; LM[2] = 2; CMAX[2] = 65535;
        ref_reset;
        upd = 1'b0; valid = 1'b0; cx = 12'd0; line_x = 12'd640;
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        chk_en = 1'b1;

        // ---- S1 clean left-to-right: 100..900 step 100, line 640
        //  A: 100..600 left (side L after 2), 700 right, 800 right -> count (1,0);  B: counts at 700 (1,0);
        //  C: needs 3 right frames: 700,800,900 -> (1,0)
        for (i = 1; i <= 9; i = i + 1) frame(1, i * 100, 640, 0);
        expect3(1, 0, 1, 0, 1, 0);
        do_reset;

        // ---- S2 jitter in the dead band: left side first, then 630 650 630 650
        //  A (H=12): 630 and 650 are both inside 640+-12 -> nothing;  C (H=20): nothing;  B (H=0): 630 left, 650 right:
        //  after 300 (left): 630 same side, 650 -> LR, 630 -> RL, 650 -> LR  => (2,1)
        rep(3, 1, 300);
        rep(1, 1, 630); rep(1, 1, 650); rep(1, 1, 630); rep(1, 1, 650);
        expect3(0, 0, 2, 1, 0, 0);
        do_reset;

        // ---- S3 one-frame spike: 300 x3, 800, 300 x3 -> A and C ignore it; B (confirm 1) counts both ways
        rep(3, 1, 300); rep(1, 1, 800); rep(3, 1, 300);
        expect3(0, 0, 1, 1, 0, 0);
        do_reset;

        // ---- S4 round trip 300 x3, 800 x3, 300 x3 -> everybody (1,1)
        rep(3, 1, 300); rep(3, 1, 800); rep(3, 1, 300);
        expect3(1, 1, 1, 1, 1, 1);
        do_reset;

        // ---- S5 short loss: 300 x3, lost x2, 800 x3
        //  A (LOST_MAX 5) keeps the side -> (1,0);  B (LOST_MAX 0) forgets at once, 800 only learns -> (0,0);
        //  C (LOST_MAX 2, confirm 3) keeps the side, 800 x3 -> (1,0)
        rep(3, 1, 300); rep(2, 0, 0); rep(3, 1, 800);
        expect3(1, 0, 0, 0, 1, 0);
        do_reset;

        // ---- S6 long loss: 300 x3, lost x6, 800 x3 -> all forget the side, nothing counted; then 300 x3 -> RL
        rep(3, 1, 300); rep(6, 0, 0); rep(3, 1, 800);
        expect3(0, 0, 0, 0, 0, 0);
        rep(3, 1, 300);
        expect3(0, 1, 0, 1, 0, 1);
        do_reset;

        // ---- S7 start on the right: nothing counted, side learned
        rep(4, 1, 800);
        expect3(0, 0, 0, 0, 0, 0);
        do_reset;

        // ---- S8 saturation of B (3-bit counters, max 7): 300,800,300,... 21 frames -> 20 crossings, 10 each way
        //  B saturates at 7 / 7 (total 7); A and C (confirm >= 2) never confirm a single-frame alternation
        for (i = 0; i < 21; i = i + 1) frame(1, (i % 2) ? 800 : 300, 640, 0);
        expect3(0, 0, 7, 7, 0, 0);
        if (totB !== 3'd7) bad("directed B total saturated", 1, 7, totB);
        do_reset;

        // ---- S9 reset clears the half-confirmed candidate: 300 x3, 800 (candidate), reset, 800 -> A still unknown
        rep(3, 1, 300); rep(1, 1, 800);
        do_reset;
        rep(1, 1, 800);
        clock(0, 0, 0, 640);
        clock(0, 0, 0, 640);
        if (sdA !== 2'd0) bad("directed side after reset", 0, 0, sdA);
        do_reset;

        // ---- S10 line at the borders and 12-bit extremes (no wrap in the zone arithmetic)
        frame(1, 0, 0, 0); frame(1, 0, 0, 0); frame(1, 0, 0, 0);          // cx = line = 0 -> dead band (A), right-of for B? (cx > 0 false)
        frame(1, 4095, 4095, 0); frame(1, 4095, 4095, 0); frame(1, 4095, 4095, 0);
        frame(1, 4095, 0, 0); frame(1, 4095, 0, 0); frame(1, 4095, 0, 0);  // far right of line 0
        frame(1, 0, 4095, 0); frame(1, 0, 4095, 0); frame(1, 0, 4095, 0);  // far left of line 4095 -> crossing
        clock(0, 0, 0, 640); clock(0, 0, 0, 640);
        do_reset;

        // ---- random run: reference compared with every output after every clock
        pos = 640; lnv = 640; lostburst = 0;
        for (j = 0; j < 400000; j = j + 1) begin
            // line_x changes now and then (and sits on extreme values for a while)
            if (($random(seed) & 1023) == 0) begin
                r = $random(seed) & 7;
                case (r)
                    0: lnv = 0;
                    1: lnv = 4095;
                    2: lnv = 1;
                    3: lnv = 4094;
                    default: lnv = 100 + (($random(seed) & 32'h7fffffff) % 1000);
                endcase
            end
            // target walk: small steps, occasional jumps across the line, occasional teleport to the extremes
            r = $random(seed) & 255;
            if (r < 200)      step = (($random(seed) & 32'h7fffffff) % 121) - 60;
            else if (r < 240) step = (($random(seed) & 32'h7fffffff) % 41) - 20;
            else if (r < 252) step = (($random(seed) & 32'h7fffffff) % 1601) - 800;
            else              step = 0;
            pos = pos + step;
            if (r == 255) pos = 0; else if (r == 254) pos = 4095;
            if (pos < 0) pos = 0;
            if (pos > 4095) pos = 4095;
            // lost bursts
            if (lostburst > 0) lostburst = lostburst - 1;
            else if (($random(seed) & 31) == 0) lostburst = ($random(seed) & 7);
            // tracks near the line more often: pull towards it occasionally
            if (($random(seed) & 15) == 0) pos = lnv + (($random(seed) & 32'h7fffffff) % 81) - 40;
            if (pos < 0) pos = 0;
            if (pos > 4095) pos = 4095;
            if (lostburst > 0) cov_lostzone = cov_lostzone + 1;
            frame((lostburst > 0) ? 0 : 1, pos, lnv, ($random(seed) & 7) == 0 ? ($random(seed) & 3) : 0);
            total_frames = total_frames + 1;
            if (($random(seed) & 8191) == 0) do_reset;
        end
        clock(0, 0, 0, 640);
        clock(0, 0, 0, 640);
        chk_en = 1'b0;

        $display("tb_cross_counter: clocks compared=%0d random frames=%0d errors=%0d", nchk, total_frames, errors);
        $display("tb_cross_counter: coverage events=%0d forget=%0d candidate-resets=%0d dead-band=%0d new-side-learned=%0d saturated-adds=%0d lost-bursts=%0d resume-after-short-loss=%0d",
                 cov_event, cov_forget, cov_candreset, cov_mid, cov_confirm_new, cov_sat, cov_lostzone, cov_lostresume);
        if (cov_event < 2000 || cov_forget < 200 || cov_candreset < 2000 || cov_mid < 20000 || cov_confirm_new < 200 ||
            cov_sat < 50 || cov_lostzone < 5000 || cov_lostresume < 200 || nchk < 400000) begin
            errors = errors + 1;
            $display("COVERAGE too low: the random run would be vacuous");
        end
        if (errors == 0) $display("TB_RESULT: PASS tb_cross_counter");
        else             $display("TB_RESULT: FAIL tb_cross_counter errors=%0d", errors);
        $finish;
    end

endmodule
