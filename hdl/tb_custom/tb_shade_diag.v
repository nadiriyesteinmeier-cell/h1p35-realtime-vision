// tb_shade_diag.v - self-check of rtl_custom/shade_diag.v (+ flat_stats, shade_report, uart_tx8, video_pos_adapter) on the real 1280x720 timing
//
// A static synthetic frame whose colour depends on the pixel position in a way that makes every cell sum unique and every one-pixel shift
// visible (cell-dependent offsets plus position-dependent ripples) is fed through the UNMODIFIED lab1 uivtc.v (de / user / last, 1650 x 750)
// with the frame-buffer colour lagging de by 2 clocks, as in the real design. The testbench
//   * receives the UART text (8N1, 4 clocks per bit), parses HDR / 144 cell lines / END and compares EVERY R, G and B cell sum with sums computed
//     here by brute force from the same formula, the grid fields, the row-major cell order, the running frame number and the checksum;
//   * presses KEY1 (AWB mode 0 -> 1 -> 2 -> 0) and checks the mode field of the reports that follow (a measurement that spans a mode change
//     is repeated, the first SETTLE reports after a change are discarded) and the awb_mode output;
//   * presses KEY2 (report off, then on again) and checks that the UART is silent while it is off and resumes afterwards;
//   * drops diag_active: the UART must stay silent and KEY1 must not change the mode.
// UART bit time, key debounce, report gap and SETTLE are shortened; the cell geometry and the video timing are the real ones.
//
// Run (ModelSim; about 10 minutes, Icarus needs much longer):
//   F:\medolsim\win64\vsim.exe -c -do "set TBDIR F:/fpga_s2/tb_custom; set ONLY tb_shade_diag; do F:/fpga_s2/tb_custom/run_modelsim.do"
// Final line: TB_RESULT: PASS tb_shade_diag  or  FAIL

`timescale 1ns / 1ps

module tb_shade_diag;

    localparam integer GW = 16, GH = 9, CW = 80, CH = 80;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    wire vvs, vhs, vde, vuser, vlast;
    uivtc #(.H_ActiveSize(1280), .H_FrameSize(1650), .H_SyncStart(1390), .H_SyncEnd(1430),
            .V_ActiveSize(720),  .V_FrameSize(750),  .V_SyncStart(725),  .V_SyncEnd(730)) u_vtc (
        .I_vtc_rstn(rst_n), .I_vtc_clk(clk),
        .O_vtc_vs(vvs), .O_vtc_hs(vhs), .O_vtc_de_valid(vde), .O_vtc_user(vuser), .O_vtc_last(vlast)
    );

    // ---------------- scene
    function [23:0] scene;
        input integer x;
        input integer y;
        integer cx, cy, r, g, b;
        begin
            cx = x / 80;
            cy = y / 80;
            r = 40 + cx * 10 + ((x * 5 + y * 3) % 23);
            g = 60 + cy * 12 + ((x * 11 + y * 7) % 29);
            b = 30 + ((cx * cy * 7) % 90) + ((x + 2 * y) % 31);
            scene = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    // coordinates of the pixel on the current de (the TB's own counters)
    integer xi, yi;
    reg        c0_v, c1_v;
    integer    c0_x, c0_y, c1_x, c1_y;
    reg [23:0] gcnt;
    initial begin xi = 0; yi = 0; c0_v = 1'b0; c1_v = 1'b0; gcnt = 24'd0; c0_x = 0; c0_y = 0; c1_x = 0; c1_y = 0; end
    always @(posedge clk) begin
        gcnt <= gcnt + 24'h010203;
        if (vde) begin
            if (vuser) begin xi = 0; yi = 0; end
            c0_x <= xi; c0_y <= yi; c0_v <= 1'b1;
            if (vlast) begin xi = 0; yi = yi + 1; end
            else       xi = xi + 1;
        end
        else c0_v <= 1'b0;
        c1_x <= c0_x; c1_y <= c0_y; c1_v <= c0_v;
    end
    wire [23:0] vid_rgb = c1_v ? scene(c1_x, c1_y) : (24'hA5C3E1 ^ gcnt);        // colour lags de by 2 clocks

    // ---------------- DUT
    reg        diag_active;
    reg  [1:0] key_n;
    wire [1:0] awb_mode;
    wire       rep_en, rep_busy, uart_tx;
    wire [7:0] rep_count;
    shade_diag #(.SKEW(2), .KEY_DEB(20), .UART_CLKDIV(4), .GAP_CLKS(3000), .SETTLE(1)) dut (
        .clk(clk), .rst_n(rst_n),
        .vid_de(vde), .vid_user(vuser), .vid_last(vlast), .vid_rgb(vid_rgb),
        .diag_active(diag_active), .key_n(key_n),
        .awb_mode(awb_mode), .rep_en(rep_en), .rep_busy(rep_busy), .rep_count(rep_count), .uart_tx(uart_tx)
    );

    // ---------------- expected sums (brute force, from the formula above)
    integer exp_r [0:143];
    integer exp_g [0:143];
    integer exp_b [0:143];
    integer ex, ey, ec;
    reg [23:0] pv;
    initial begin
        for (ec = 0; ec < 144; ec = ec + 1) begin exp_r[ec] = 0; exp_g[ec] = 0; exp_b[ec] = 0; end
        for (ey = 0; ey < 720; ey = ey + 1)
            for (ex = 0; ex < 1280; ex = ex + 1) begin
                pv = scene(ex, ey);
                ec = (ey / 80) * 16 + (ex / 80);
                exp_r[ec] = exp_r[ec] + pv[23:16];
                exp_g[ec] = exp_g[ec] + pv[15:8];
                exp_b[ec] = exp_b[ec] + pv[7:0];
            end
    end

    // ---------------- UART receiver and parser
    integer errors;
    integer rx_bytes, rep_n, rep_good;
    reg [7:0] rxb;
    integer bi;
    reg [7:0] lbuf [0:63];
    integer   ll;
    integer   state_rx;                    // 0 expect HDR, 1 cells, 2 expect END
    integer   cells_seen, last_row, last_col;
    integer   rep_mode_arr [0:63];
    integer   rep_fno_arr  [0:63];
    integer   chk_calc, chk_rx;
    integer   t_last_rx;                   // time of the last received byte
    integer   cell_bad;

    function integer hv;
        input [7:0] c;
        begin
            if (c >= "0" && c <= "9")      hv = c - "0";
            else if (c >= "A" && c <= "F") hv = c - "A" + 10;
            else                           hv = -1;
        end
    endfunction

    function integer hex_n;                // n hex digits starting at lbuf[p]
        input integer p;
        input integer n;
        integer k, v, d;
        begin
            v = 0;
            for (k = 0; k < n; k = k + 1) begin
                d = hv(lbuf[p + k]);
                if (d < 0) v = -1000000000; else if (v >= 0) v = v * 16 + d;
            end
            hex_n = v;
        end
    endfunction

    task bad;
        input [8*64-1:0] what;
        input integer e;
        input integer a;
        begin
            errors = errors + 1;
            if (errors <= 25) $display("MISMATCH t=%0t %0s expected=%0d actual=%0d (report %0d)", $time, what, e, a, rep_n);
        end
    endtask

    integer rr, rg, rb, rrow, rcol, cidx;
    task parse_line;
        begin
            if (ll == 17 && lbuf[0] == "H" && lbuf[1] == "D" && lbuf[2] == "R") begin
                if (state_rx != 0) bad("HDR while a report was in progress", 0, state_rx);
                if (hex_n(9, 2) != GW || hex_n(12, 2) != GH || hex_n(15, 2) != CW) bad("HDR grid fields", GW * 65536 + GH * 256 + CW, hex_n(9, 2) * 65536 + hex_n(12, 2) * 256 + hex_n(15, 2));
                rep_mode_arr[rep_n] = hex_n(7, 1);
                rep_fno_arr[rep_n]  = hex_n(4, 2);
                chk_calc = 0; cells_seen = 0; cell_bad = 0;
                state_rx = 1;
            end
            else if (ll == 26 && lbuf[0] == "C") begin
                if (state_rx != 1) bad("cell line outside a report", 1, state_rx);
                rrow = hex_n(1, 2); rcol = hex_n(3, 2);
                rr = hex_n(6, 6); rg = hex_n(13, 6); rb = hex_n(20, 6);
                cidx = rrow * 16 + rcol;
                if (rrow < 0 || rrow >= GH || rcol < 0 || rcol >= GW) bad("cell index range", 0, cidx);
                else begin
                    if (cidx != cells_seen) bad("cells must come in row-major order", cells_seen, cidx);
                    if (rr != exp_r[cidx]) begin cell_bad = cell_bad + 1; bad("R sum of the cell", exp_r[cidx], rr); end
                    if (rg != exp_g[cidx]) begin cell_bad = cell_bad + 1; bad("G sum of the cell", exp_g[cidx], rg); end
                    if (rb != exp_b[cidx]) begin cell_bad = cell_bad + 1; bad("B sum of the cell", exp_b[cidx], rb); end
                end
                chk_calc = (chk_calc + (rr % 65536) + (rg % 65536) + (rb % 65536)) % 65536;
                cells_seen = cells_seen + 1;
            end
            else if (ll == 8 && lbuf[0] == "E" && lbuf[1] == "N" && lbuf[2] == "D") begin
                if (state_rx != 1) bad("END outside a report", 1, state_rx);
                if (cells_seen != GW * GH) bad("number of cell lines", GW * GH, cells_seen);
                chk_rx = hex_n(4, 4);
                if (chk_rx != chk_calc) bad("checksum", chk_calc, chk_rx);
                if (cells_seen == GW * GH && chk_rx == chk_calc && cell_bad == 0) rep_good = rep_good + 1;
                rep_n = rep_n + 1;
                state_rx = 0;
            end
            else bad("unrecognized line (length)", 0, ll);
        end
    endtask

    initial begin rx_bytes = 0; rep_n = 0; rep_good = 0; ll = 0; state_rx = 0; cells_seen = 0; t_last_rx = 0; cell_bad = 0; chk_calc = 0; end
    always begin
        @(negedge uart_tx);
        repeat (6) @(posedge clk);
        for (bi = 0; bi < 8; bi = bi + 1) begin
            rxb[bi] = uart_tx;
            repeat (4) @(posedge clk);
        end
        if (uart_tx !== 1'b1) bad("stop bit (the line must be high in the middle of the stop bit)", 1, uart_tx);
        @(posedge clk);                                                  // one clock later: still inside the stop bit (it lasts 4 clocks)
        if (uart_tx !== 1'b1) bad("the stop bit must last the full bit time", 1, uart_tx);
        rx_bytes = rx_bytes + 1;
        t_last_rx = $time;
        if (rxb == 8'h0A) begin
            parse_line;
            ll = 0;
        end
        else if (rxb != 8'h0D) begin
            if (ll < 64) lbuf[ll] = rxb;
            ll = ll + 1;
        end
    end

    // ---------------- sequence
    task press;
        input integer k;
        begin
            key_n[k] = 1'b0;
            repeat (60) @(posedge clk);
            key_n[k] = 1'b1;
            repeat (60) @(posedge clk);
        end
    endtask

    task wait_reports;                    // until n reports have been completely received
        input integer n;
        integer guard;
        begin
            guard = 0;
            while (rep_n < n && guard < 30000000) begin @(posedge clk); guard = guard + 1; end
            if (guard >= 30000000) bad("timeout waiting for report", n, rep_n);
        end
    endtask

    task wait_quiet;                      // no UART byte for 'frames' video frames
        input integer frames;
        integer b0, g;
        begin
            b0 = rx_bytes;
            repeat (frames * 1237500) @(posedge clk);
            if (rx_bytes != b0) bad("the UART must be silent", 0, rx_bytes - b0);
        end
    endtask

    integer b_before, n0;
    initial begin
        errors = 0;
        rst_n = 1'b0; key_n = 2'b11; diag_active = 1'b1;
        repeat (4) @(negedge clk);
        #2 rst_n = 1'b1;
        repeat (60) @(negedge clk);

        // ---- reports in mode 0
        wait_reports(2);
        if (rep_mode_arr[0] != 0 || rep_mode_arr[1] != 0) bad("mode field of the first reports", 0, rep_mode_arr[0] + rep_mode_arr[1]);
        if (rep_fno_arr[0] != 0 || rep_fno_arr[1] != 1) bad("running frame number", 1, rep_fno_arr[1]);
        if (awb_mode !== 2'd0) bad("awb_mode at power-up", 0, awb_mode);

        // ---- KEY1: mode 1, then 2, then back to 0
        n0 = rep_n;
        press(0);
        if (awb_mode !== 2'd1) bad("awb_mode after the first KEY1", 1, awb_mode);
        wait_reports(n0 + 2);                        // one report may still carry the old mode (it was started before the press)
        if (rep_mode_arr[n0 + 1] != 1) bad("mode field after KEY1 (mode 1)", 1, rep_mode_arr[n0 + 1]);
        n0 = rep_n;
        press(0);
        if (awb_mode !== 2'd2) bad("awb_mode after the second KEY1", 2, awb_mode);
        wait_reports(n0 + 2);
        if (rep_mode_arr[n0 + 1] != 2) bad("mode field after KEY1 (mode 2)", 2, rep_mode_arr[n0 + 1]);
        n0 = rep_n;
        press(0);
        if (awb_mode !== 2'd0) bad("awb_mode wraps to 0", 0, awb_mode);
        wait_reports(n0 + 2);
        if (rep_mode_arr[n0 + 1] != 0) bad("mode field after the wrap", 0, rep_mode_arr[n0 + 1]);

        // ---- KEY2: report off -> silent, on -> resumes
        press(1);
        if (rep_en !== 1'b0) bad("report off after KEY2", 0, rep_en);
        while (dut.rep_busy) @(posedge clk);               // a report that was already running is finished
        repeat (2 * 1237500) @(posedge clk);               // a capture that was already running ends without printing
        wait_quiet(3);
        n0 = rep_n;
        press(1);
        if (rep_en !== 1'b1) bad("report on after the second KEY2", 1, rep_en);
        wait_reports(n0 + 1);

        // ---- diag_active = 0: silent, keys without effect
        while (dut.rep_busy) @(posedge clk);
        repeat (5000) @(posedge clk);
        diag_active = 1'b0;
        repeat (200000) @(posedge clk);                    // a capture that was already running may end here, it prints nothing
        b_before = rx_bytes;
        press(0);
        if (awb_mode !== 2'd0) bad("KEY1 must not change the mode while diag_active = 0", 0, awb_mode);
        press(1);
        if (rep_en !== 1'b1) bad("KEY2 must not change the report flag while diag_active = 0", 1, rep_en);
        wait_quiet(3);
        if (rx_bytes != b_before) bad("UART activity while diag_active = 0", 0, rx_bytes - b_before);
        diag_active = 1'b1;
        n0 = rep_n;
        wait_reports(n0 + 1);

        $display("tb_shade_diag: reports received=%0d fully correct=%0d bytes=%0d errors=%0d", rep_n, rep_good, rx_bytes, errors);
        if (rep_n < 8 || rep_good != rep_n) begin errors = errors + 1; $display("COVERAGE/CONTENT: %0d reports, %0d good", rep_n, rep_good); end
        if (errors == 0) $display("TB_RESULT: PASS tb_shade_diag");
        else             $display("TB_RESULT: FAIL tb_shade_diag errors=%0d", errors);
        $finish;
    end

endmodule
