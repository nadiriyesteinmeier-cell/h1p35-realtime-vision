// tb_target_track.v - self-check of rtl_custom/target_track.v (jitter hold, smoothing, snap, short-occlusion hold, lost, re-acquire)
//
// Four instances with different parameters see the same frame samples:
//   A  COAST_MAX = 3, JIT = 2, SNAP = 24, 16-bit counters      (the main configuration, close to the design defaults)
//   B  COAST_MAX = 0, JIT = 1, SNAP = 10, 2-bit counters       (no hold state at all; counters saturate at 3)
//   C  COAST_MAX = 2, JIT = 0, SNAP = 4,  16-bit counters      (no jitter dead band, small snap distance)
//   D  COAST_MAX = 1, JIT = 2, SNAP = 24, 2-bit counters       (one hold frame; every counter saturates at 3)
// Part 1: directed scenario on A with literal expected numbers (written from the specification in the header of target_track.v).
// Part 2: 30,000 random frame samples; every output of all three instances is compared after every sample with a reference model
//         that is written with integer arithmetic (abs / division by 2, written differently from the RTL's bit slicing).
//         The stimulus contains jitter of 0..2 px, steps of 3..24 px, jumps of 25..300 px, absences of 0..(COAST+4) frames, clr_stats
//         pulses (also in the clock of a sample) and boxes close to 0 and to 4095.
//
// Run: iverilog -g2005 -o sim_tt.vvp tb_target_track.v ../rtl_custom/target_track.v ; vvp sim_tt.vvp
//      final line: TB_RESULT: PASS tb_target_track  or  FAIL

`timescale 1ns / 1ps

module tb_target_track;

    reg clk, rst_n, clr, upd, valid;
    reg [11:0] xmin, xmax, ymin, ymax;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    wire [1:0]  stA, stB, stC, stD;
    wire [11:0] axmin, axmax, aymin, aymax, acx, acy;
    wire [11:0] bxmin, bxmax, bymin, bymax, bcx, bcy;
    wire [11:0] cxmin, cxmax, cymin, cymax, ccx, ccy;
    wire [11:0] dxmin, dxmax, dymin, dymax, dcx, dcy;
    wire [7:0]  ageA, ageB, ageC, ageD;
    wire [15:0] A_acq, A_hold, A_reacq, A_lost, A_jit;
    wire [1:0]  B_acq, B_hold, B_reacq, B_lost, B_jit;
    wire [15:0] C_acq, C_hold, C_reacq, C_lost, C_jit;
    wire [1:0]  D_acq, D_hold, D_reacq, D_lost, D_jit;

    target_track #(.COAST_MAX(3), .JIT(2), .SNAP(24), .CNT_W(16)) uA (
        .clk(clk), .rst_n(rst_n), .clr_stats(clr), .upd(upd), .valid(valid), .xmin(xmin), .xmax(xmax), .ymin(ymin), .ymax(ymax),
        .state(stA), .t_xmin(axmin), .t_xmax(axmax), .t_ymin(aymin), .t_ymax(aymax), .t_cx(acx), .t_cy(acy), .age(ageA),
        .n_acq(A_acq), .n_hold(A_hold), .n_reacq(A_reacq), .n_lost(A_lost), .n_jit(A_jit));
    target_track #(.COAST_MAX(0), .JIT(1), .SNAP(10), .CNT_W(2)) uB (
        .clk(clk), .rst_n(rst_n), .clr_stats(clr), .upd(upd), .valid(valid), .xmin(xmin), .xmax(xmax), .ymin(ymin), .ymax(ymax),
        .state(stB), .t_xmin(bxmin), .t_xmax(bxmax), .t_ymin(bymin), .t_ymax(bymax), .t_cx(bcx), .t_cy(bcy), .age(ageB),
        .n_acq(B_acq), .n_hold(B_hold), .n_reacq(B_reacq), .n_lost(B_lost), .n_jit(B_jit));
    target_track #(.COAST_MAX(2), .JIT(0), .SNAP(4), .CNT_W(16)) uC (
        .clk(clk), .rst_n(rst_n), .clr_stats(clr), .upd(upd), .valid(valid), .xmin(xmin), .xmax(xmax), .ymin(ymin), .ymax(ymax),
        .state(stC), .t_xmin(cxmin), .t_xmax(cxmax), .t_ymin(cymin), .t_ymax(cymax), .t_cx(ccx), .t_cy(ccy), .age(ageC),
        .n_acq(C_acq), .n_hold(C_hold), .n_reacq(C_reacq), .n_lost(C_lost), .n_jit(C_jit));
    target_track #(.COAST_MAX(1), .JIT(2), .SNAP(24), .CNT_W(2)) uD (
        .clk(clk), .rst_n(rst_n), .clr_stats(clr), .upd(upd), .valid(valid), .xmin(xmin), .xmax(xmax), .ymin(ymin), .ymax(ymax),
        .state(stD), .t_xmin(dxmin), .t_xmax(dxmax), .t_ymin(dymin), .t_ymax(dymax), .t_cx(dcx), .t_cy(dcy), .age(ageD),
        .n_acq(D_acq), .n_hold(D_hold), .n_reacq(D_reacq), .n_lost(D_lost), .n_jit(D_jit));

    integer errors;
    task bad;
        input [8*40-1:0] what;
        input integer e;
        input integer a;
        begin
            errors = errors + 1;
            if (errors <= 25) $display("MISMATCH t=%0t %0s expected=%0d actual=%0d", $time, what, e, a);
        end
    endtask

    // ---------------- reference model (integer arithmetic, written from the specification)
    integer m_state [0:3];           // 0 LOST 1 TRACK 2 HOLD
    integer m_box   [0:15];          // 4 coordinates per instance: xmin xmax ymin ymax
    integer m_age   [0:3];
    integer m_acq [0:3];
    integer m_hold[0:3];
    integer m_reacq[0:3];
    integer m_lost[0:3];
    integer m_jit [0:3];
    integer p_coast [0:3];
    integer p_jit   [0:3];
    integer p_snap  [0:3];
    integer p_cmax  [0:3];

    function integer iabs;
        input integer v;
        begin iabs = (v < 0) ? -v : v; end
    endfunction

    function integer sat;
        input integer v;
        input integer mx;
        begin sat = (v > mx) ? mx : v; end
    endfunction

    task model_reset;
        integer n, q;
        begin
            for (n = 0; n < 4; n = n + 1) begin
                m_state[n] = 0; m_age[n] = 255;
                for (q = 0; q < 4; q = q + 1) m_box[4*n+q] = 0;
                m_acq[n] = 0; m_hold[n] = 0; m_reacq[n] = 0; m_lost[n] = 0; m_jit[n] = 0;
            end
        end
    endtask

    integer md [0:3];
    integer cov_snap, cov_smooth, cov_jit, cov_acq, cov_hold, cov_reacq, cov_lost, cov_clr_with_event;   // coverage of instance A, never cleared
    integer mm [0:3];
    task model_sample;                  // one upd of instance n with (valid, mm[0..3]) ; clr = clr_stats of this clock
        input integer n;
        input integer v;
        input integer c;
        integer q, snap, anyd, allj, ad, step;
        begin
            if (c) begin m_acq[n] = 0; m_hold[n] = 0; m_reacq[n] = 0; m_lost[n] = 0; m_jit[n] = 0; end
            if (v) begin
                if (m_state[n] == 1) begin
                    snap = 0; anyd = 0; allj = 1;
                    for (q = 0; q < 4; q = q + 1) begin
                        md[q] = mm[q] - m_box[4*n+q];
                        if (iabs(md[q]) > p_snap[n]) snap = 1;
                        if (md[q] != 0) anyd = 1;
                        if (iabs(md[q]) > p_jit[n]) allj = 0;
                    end
                    if (snap) begin
                        if (n == 0) cov_snap = cov_snap + 1;
                        for (q = 0; q < 4; q = q + 1) m_box[4*n+q] = mm[q];
                    end
                    else begin
                        for (q = 0; q < 4; q = q + 1) begin
                            ad = iabs(md[q]);
                            if (ad > p_jit[n]) begin
                                step = ad / 2;
                                if (md[q] > 0) m_box[4*n+q] = m_box[4*n+q] + step;
                                else           m_box[4*n+q] = m_box[4*n+q] - step;
                            end
                        end
                        if (anyd && allj && !c) m_jit[n] = sat(m_jit[n] + 1, p_cmax[n]);
                        if (n == 0 && anyd && allj) cov_jit = cov_jit + 1;
                        if (n == 0 && !allj) cov_smooth = cov_smooth + 1;
                    end
                end
                else begin
                    for (q = 0; q < 4; q = q + 1) m_box[4*n+q] = mm[q];
                    if (n == 0) begin if (m_state[n] == 2) cov_reacq = cov_reacq + 1; else cov_acq = cov_acq + 1; if (c) cov_clr_with_event = cov_clr_with_event + 1; end
                    if (!c) begin
                        if (m_state[n] == 2) m_reacq[n] = sat(m_reacq[n] + 1, p_cmax[n]);
                        else                 m_acq[n]   = sat(m_acq[n] + 1, p_cmax[n]);
                    end
                    m_state[n] = 1;
                end
                m_age[n] = 0;
            end
            else begin
                if (m_state[n] == 1) begin
                    m_age[n] = 1;
                    if (n == 0) cov_hold = cov_hold + 1;
                    if (p_coast[n] >= 1) begin
                        m_state[n] = 2;
                        if (!c) m_hold[n] = sat(m_hold[n] + 1, p_cmax[n]);
                    end
                    else begin
                        m_state[n] = 0;
                        if (!c) m_lost[n] = sat(m_lost[n] + 1, p_cmax[n]);
                    end
                end
                else if (m_state[n] == 2) begin
                    if (m_age[n] + 1 > p_coast[n]) begin
                        if (n == 0) cov_lost = cov_lost + 1;
                        m_state[n] = 0;
                        if (!c) m_lost[n] = sat(m_lost[n] + 1, p_cmax[n]);
                    end
                    m_age[n] = sat(m_age[n] + 1, 255);
                end
                else m_age[n] = sat(m_age[n] + 1, 255);
            end
        end
    endtask

    task compare_one;
        input integer n;
        input integer st;
        input integer x0;
        input integer x1;
        input integer y0;
        input integer y1;
        input integer cx;
        input integer cy;
        input integer ag;
        input integer k0;
        input integer k1;
        input integer k2;
        input integer k3;
        input integer k4;
        begin
            if (st !== m_state[n])       bad("state", m_state[n], st);
            if (x0 !== m_box[4*n+0])     bad("t_xmin", m_box[4*n+0], x0);
            if (x1 !== m_box[4*n+1])     bad("t_xmax", m_box[4*n+1], x1);
            if (y0 !== m_box[4*n+2])     bad("t_ymin", m_box[4*n+2], y0);
            if (y1 !== m_box[4*n+3])     bad("t_ymax", m_box[4*n+3], y1);
            if (cx !== ((m_box[4*n+0] + m_box[4*n+1]) / 2)) bad("t_cx", (m_box[4*n+0] + m_box[4*n+1]) / 2, cx);
            if (cy !== ((m_box[4*n+2] + m_box[4*n+3]) / 2)) bad("t_cy", (m_box[4*n+2] + m_box[4*n+3]) / 2, cy);
            if (ag !== m_age[n])         bad("age", m_age[n], ag);
            if (k0 !== m_acq[n])         bad("n_acq", m_acq[n], k0);
            if (k1 !== m_hold[n])        bad("n_hold", m_hold[n], k1);
            if (k2 !== m_reacq[n])       bad("n_reacq", m_reacq[n], k2);
            if (k3 !== m_lost[n])        bad("n_lost", m_lost[n], k3);
            if (k4 !== m_jit[n])         bad("n_jit", m_jit[n], k4);
        end
    endtask

    task compare_all;
        begin
            compare_one(0, stA, axmin, axmax, aymin, aymax, acx, acy, ageA, A_acq, A_hold, A_reacq, A_lost, A_jit);
            compare_one(1, stB, bxmin, bxmax, bymin, bymax, bcx, bcy, ageB, B_acq, B_hold, B_reacq, B_lost, B_jit);
            compare_one(2, stC, cxmin, cxmax, cymin, cymax, ccx, ccy, ageC, C_acq, C_hold, C_reacq, C_lost, C_jit);
            compare_one(3, stD, dxmin, dxmax, dymin, dymax, dcx, dcy, ageD, D_acq, D_hold, D_reacq, D_lost, D_jit);
        end
    endtask

    // ---------------- driver
    task tick; begin @(negedge clk); #1; end endtask

    integer n_samples;
    task sample;                        // drive one frame sample (one clock of upd), compare after the registers settled
        input integer v;
        input integer x0;
        input integer x1;
        input integer y0;
        input integer y1;
        input integer c;
        begin
            valid = v[0]; xmin = x0; xmax = x1; ymin = y0; ymax = y1; upd = 1'b1; clr = c[0];
            mm[0] = x0; mm[1] = x1; mm[2] = y0; mm[3] = y1;
            model_sample(0, v, c); model_sample(1, v, c); model_sample(2, v, c); model_sample(3, v, c);
            tick;
            upd = 1'b0; clr = 1'b0;
            compare_all;
            n_samples = n_samples + 1;
            tick;                       // idle clock between samples (the inputs must be ignored while upd = 0)
            valid = ~valid; xmin = xmin + 12'd7; ymax = ymax + 12'd3;
            tick;
            compare_all;
        end
    endtask

    // ---------------- part 1: directed scenario on instance A with literal numbers
    task expectA;
        input integer st;
        input integer x0;
        input integer x1;
        input integer y0;
        input integer y1;
        input integer ag;
        begin
            if (stA !== st[1:0]) bad("A state", st, stA);
            if (axmin !== x0) bad("A xmin", x0, axmin);
            if (axmax !== x1) bad("A xmax", x1, axmax);
            if (aymin !== y0) bad("A ymin", y0, aymin);
            if (aymax !== y1) bad("A ymax", y1, aymax);
            if (ageA !== ag)  bad("A age", ag, ageA);
        end
    endtask

    integer seed, r, i, bx, by, bw, bh, gap, hidden, vv, cc;
    integer d;
    initial begin
        errors = 0; n_samples = 0;
        cov_snap = 0; cov_smooth = 0; cov_jit = 0; cov_acq = 0; cov_hold = 0; cov_reacq = 0; cov_lost = 0; cov_clr_with_event = 0;
        p_coast[0] = 3; p_jit[0] = 2; p_snap[0] = 24; p_cmax[0] = 65535;
        p_coast[1] = 0; p_jit[1] = 1; p_snap[1] = 10; p_cmax[1] = 3;
        p_coast[2] = 2; p_jit[2] = 0; p_snap[2] = 4;  p_cmax[2] = 65535;
        p_coast[3] = 1; p_jit[3] = 2; p_snap[3] = 24; p_cmax[3] = 3;
        model_reset;
        rst_n = 1'b0; clr = 1'b0; upd = 1'b0; valid = 1'b0; xmin = 0; xmax = 0; ymin = 0; ymax = 0;
        repeat (3) tick;
        // reset state
        expectA(0, 0, 0, 0, 0, 255);
        rst_n = 1'b1; tick; tick;
        compare_all;

        // first measurement: acquired as it is
        sample(1, 100, 160, 200, 250, 0);
        expectA(1, 100, 160, 200, 250, 0);
        if (A_acq !== 16'd1) bad("A n_acq after acquisition", 1, A_acq);
        // identical: nothing moves, no jitter counted
        sample(1, 100, 160, 200, 250, 0);
        expectA(1, 100, 160, 200, 250, 0);
        if (A_jit !== 16'd0) bad("A n_jit for an identical sample", 0, A_jit);
        // +1 / +2 pixels on some edges: absorbed (JIT = 2), counted as jitter
        sample(1, 101, 162, 199, 250, 0);
        expectA(1, 100, 160, 200, 250, 0);
        if (A_jit !== 16'd1) bad("A n_jit after jitter", 1, A_jit);
        // 3 pixels: moves by 3/2 = 1, other coordinates unchanged
        sample(1, 103, 160, 200, 250, 0);
        expectA(1, 101, 160, 200, 250, 0);
        // tracked (101,160): 7 and 8 pixels to the right on the two x edges: moves by 7/2 = 3 and 8/2 = 4
        sample(1, 108, 168, 200, 250, 0);
        expectA(1, 104, 164, 200, 250, 0);
        // negative direction, 4 pixels on both x edges: moves by 2 towards the measurement
        sample(1, 100, 160, 200, 250, 0);
        expectA(1, 102, 162, 200, 250, 0);
        // a step of exactly SNAP (24) is smoothed (12), one pixel more (25) snaps
        sample(1, 126, 162, 200, 250, 0);
        expectA(1, 114, 162, 200, 250, 0);
        sample(1, 139, 162, 200, 250, 0);               // |139 - 114| = 25 > 24
        expectA(1, 139, 162, 200, 250, 0);
        // not found: HOLD, box kept, age counts
        sample(0, 0, 0, 0, 0, 0);
        expectA(2, 139, 162, 200, 250, 1);
        if (A_hold !== 16'd1) bad("A n_hold", 1, A_hold);
        sample(0, 0, 0, 0, 0, 0);
        expectA(2, 139, 162, 200, 250, 2);
        sample(0, 0, 0, 0, 0, 0);
        expectA(2, 139, 162, 200, 250, 3);              // COAST_MAX = 3: still HOLD at age 3
        sample(0, 0, 0, 0, 0, 0);
        expectA(0, 139, 162, 200, 250, 4);              // age 4 > 3: LOST, last box register kept
        if (A_lost !== 16'd1) bad("A n_lost", 1, A_lost);
        sample(0, 0, 0, 0, 0, 0);
        expectA(0, 139, 162, 200, 250, 5);
        // re-acquired from LOST: n_acq, box taken over unsmoothed
        sample(1, 300, 360, 100, 150, 0);
        expectA(1, 300, 360, 100, 150, 0);
        if (A_acq !== 16'd2) bad("A n_acq after the second acquisition", 2, A_acq);
        // missing for 2 frames, then back: HOLD -> TRACK counts as a re-acquisition and takes the measurement unsmoothed (small step!)
        sample(0, 0, 0, 0, 0, 0);
        sample(0, 0, 0, 0, 0, 0);
        expectA(2, 300, 360, 100, 150, 2);
        sample(1, 310, 370, 100, 150, 0);
        expectA(1, 310, 370, 100, 150, 0);
        if (A_reacq !== 16'd1) bad("A n_reacq", 1, A_reacq);
        // clear: counters 0, state kept; a clear in the clock of a sample suppresses that sample's count
        sample(1, 310, 370, 100, 150, 1);
        if (A_acq !== 16'd0 || A_hold !== 16'd0 || A_reacq !== 16'd0 || A_lost !== 16'd0 || A_jit !== 16'd0) bad("A counters after clr_stats", 0, A_acq + A_hold + A_reacq + A_lost + A_jit);
        expectA(1, 310, 370, 100, 150, 0);
        // (instances B, C and D are compared with the reference model after every sample, see compare_all)
        // age saturates at 255 in LOST (300 missing frames), then a measurement is acquired again
        for (i = 0; i < 300; i = i + 1) sample(0, 0, 0, 0, 0, 0);
        expectA(0, 310, 370, 100, 150, 255);
        sample(1, 50, 90, 60, 100, 0);
        expectA(1, 50, 90, 60, 100, 0);

        // ---- part 2: random
        seed = 987654;
        bx = 500; by = 300; bw = 60; bh = 50; hidden = 0;
        for (i = 0; i < 30000; i = i + 1) begin
            r = $random(seed);
            // position process
            case (r[3:0])
                4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5: d = 0;
                4'd6, 4'd7, 4'd8, 4'd9:             d = (r[5:4] % 5) - 2;            // -2..2
                4'd10, 4'd11, 4'd12:                d = 3 + (r[11:6] % 22);          // 3..24
                default:                            d = 25 + (r[15:6] % 276);        // 25..300
            endcase
            if (r[16]) d = -d;
            bx = bx + d;
            if (r[20:17] == 4'd0) by = by + ((r[24:21] % 7) - 3);
            if (r[27:25] == 3'd0) bw = 20 + (r[31:28] % 70);
            if (r[31:29] == 3'd0) bh = 20 + (r[10:7] % 60);
            if (bx < 0) bx = 0;
            if (bx > 3900) bx = 3900;
            if (by < 0) by = 0;
            if (by > 3900) by = 3900;
            if (r[9:8] == 2'd3 && r[30:28] == 3'd0) begin bx = (r[11] ? 0 : 4000); end        // near the ends of the 12-bit range
            // absence process
            if (hidden > 0) begin hidden = hidden - 1; vv = 0; end
            else if (r[14:12] == 3'd0) begin hidden = (r[17:15] % 8); vv = 0; end
            else vv = 1;
            cc = (r[29:24] == 6'd5) ? 1 : 0;
            sample(vv, bx, bx + bw, by, by + bh, cc);
        end
        // reset in the middle: everything back to the reset state
        rst_n = 1'b0; tick; tick;
        model_reset;
        compare_all;
        rst_n = 1'b1; tick;

        $display("tb_target_track: samples=%0d errors=%0d; instance A coverage: snap=%0d smooth=%0d jitter-only=%0d acq=%0d hold=%0d reacq=%0d lost=%0d clr-with-event=%0d",
                 n_samples, errors, cov_snap, cov_smooth, cov_jit, cov_acq, cov_hold, cov_reacq, cov_lost, cov_clr_with_event);
        if (n_samples < 30000 || cov_snap < 300 || cov_smooth < 1000 || cov_jit < 1000 || cov_acq < 100 || cov_hold < 300 || cov_reacq < 100 || cov_lost < 100 || cov_clr_with_event < 5) begin
            errors = errors + 1; $display("COVERAGE: too low, the random part would not exercise every branch");
        end
        if (errors == 0) $display("TB_RESULT: PASS tb_target_track");
        else             $display("TB_RESULT: FAIL tb_target_track errors=%0d", errors);
        $finish;
    end

endmodule
