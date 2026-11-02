// tb_hdmi_testpat.v - self-check of rtl_custom/hdmi_testpat.v on the real 1280x720 timing (unmodified lab1 uivtc.v)
//
// For every one of the 16 patterns one full frame is generated and EVERY active pixel of the output is compared with an
// expectation computed here with integer arithmetic from the true pixel coordinates (taken from uivtc's own counters),
// vs / de must be the input delayed by exactly 1 clock, the output must be 0 in blanking and while enable = 0, and the
// push buttons must behave as documented (KEY3 next, KEY4 previous with wrap, KEY1 load_sel cycle, KEY2 reset, nothing
// while enable = 0). The seven-segment digit codes are checked too.
//
// Run: iverilog -g2005 -o sim_tp.vvp tb_hdmi_testpat.v ../rtl_custom/hdmi_testpat.v ../rtl_custom/key_debounce.v ../lab1/user_source/hdl_source/vtc/uivtc.v
//      vvp sim_tp.vvp          final line: TB_RESULT: PASS tb_hdmi_testpat  or  FAIL

`timescale 1ns / 1ps

module tb_hdmi_testpat;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    wire vs, hs, de, user, last;
    uivtc #(.H_ActiveSize(1280), .H_FrameSize(1650), .H_SyncStart(1390), .H_SyncEnd(1430),
            .V_ActiveSize(720),  .V_FrameSize(750),  .V_SyncStart(725),  .V_SyncEnd(730)) u_vtc (
        .I_vtc_rstn(rst_n), .I_vtc_clk(clk),
        .O_vtc_vs(vs), .O_vtc_hs(hs), .O_vtc_de_valid(de), .O_vtc_user(user), .O_vtc_last(last)
    );

    reg         enable;
    reg  [3:0]  key_n;
    wire        o_vs, o_de;
    wire [23:0] o_data;
    wire [3:0]  pat_id;
    wire [1:0]  load_sel;
    wire [31:0] digits;
    hdmi_testpat #(.DEB(20)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .key_n(key_n),
        .in_vs(vs), .in_de(de), .out_vs(o_vs), .out_de(o_de), .out_data(o_data),
        .pat_id(pat_id), .load_sel(load_sel), .digits(digits)
    );

    // true coordinates of the pixel on the input (uivtc counters delayed by its 2-clock output stage), then 1 more for the output
    reg [11:0] hq1, hq2, hq3, vq1, vq2, vq3;
    reg        de_q, vs_q;
    always @(posedge clk) begin
        hq1 <= u_vtc.hcnt; hq2 <= hq1; hq3 <= hq2;
        vq1 <= u_vtc.vcnt; vq2 <= vq1; vq3 <= vq2;
        de_q <= de; vs_q <= vs;
    end

    // ---------------- expectation (integer arithmetic, written independently of the RTL structure)
    function [23:0] expect_pix;
        input integer pat;
        input integer x;
        input integer y;
        integer v, s;
        begin
            expect_pix = 24'd0;
            case (pat)
                0: expect_pix = 24'h808080;
                1: expect_pix = 24'hFFFFFF;
                2: expect_pix = 24'h000000;
                3: expect_pix = 24'hFF0000;
                4: expect_pix = 24'h00FF00;
                5: expect_pix = 24'h0000FF;
                6: begin
                       s = x / 160;
                       case (s)
                           0: expect_pix = 24'hFFFFFF; 1: expect_pix = 24'hFFFF00; 2: expect_pix = 24'h00FFFF; 3: expect_pix = 24'h00FF00;
                           4: expect_pix = 24'hFF00FF; 5: expect_pix = 24'hFF0000; 6: expect_pix = 24'h0000FF; default: expect_pix = 24'h000000;
                       endcase
                   end
                7: begin v = (x * 205) / 1024; if (v > 255) v = 255; expect_pix = {v[7:0], v[7:0], v[7:0]}; end
                8: begin v = (y * 91) / 256;  if (v > 255) v = 255; expect_pix = {v[7:0], v[7:0], v[7:0]}; end
                9: expect_pix = ((x % 64) < 2 || (y % 64) < 2 || x >= 1278 || y >= 718) ? 24'hFFFFFF : 24'h000000;
                10: expect_pix = ((x % 2) == 1) ? 24'hFFFFFF : 24'h000000;
                11: expect_pix = (((x / 2) % 2) == 1) ? 24'hFFFFFF : 24'h000000;
                12: begin
                        if (x < 16)         expect_pix = 24'hFF0000;
                        else if (x >= 1264) expect_pix = 24'h00FF00;
                        else if (y < 8)     expect_pix = 24'h0000FF;
                        else if (y >= 712)  expect_pix = 24'hFFFF00;
                        else                expect_pix = 24'h404040;
                    end
                13: expect_pix = ((((x / 8) % 2) + ((y / 8) % 2)) == 1) ? 24'hFFFFFF : 24'h000000;
                14: begin s = (x * 205) / 16384; if (s > 15) s = 15; v = s * 17; expect_pix = {v[7:0], v[7:0], v[7:0]}; end
                default: begin
                        if (y == 360 || y == 361)      expect_pix = 24'hFFFFFF;
                        else if ((x % 32) < 2) begin
                            s = (x / 32) % 4;
                            expect_pix = (s == 0) ? 24'hFFFFFF : (s == 1) ? 24'hFF0000 : (s == 2) ? 24'h00FF00 : 24'h0000FF;
                        end
                        else                           expect_pix = 24'h000000;
                    end
            endcase
        end
    endfunction

    // ---------------- checking
    integer errors, npix, nfr, pat_cur;
    integer x, y;
    reg     check_en;
    task bad;
        input [8*40-1:0] what;
        input integer e;
        input integer a;
        begin
            errors = errors + 1;
            if (errors <= 15) $display("MISMATCH t=%0t pat=%0d %0s expected=%0h actual=%0h (x=%0d y=%0d)", $time, pat_cur, what, e, a, hq3, vq3);
            if (errors >= 100) begin $display("TB_RESULT: FAIL tb_hdmi_testpat aborted after %0d mismatches", errors); $finish; end
        end
    endtask

    always @(negedge clk) begin
        if (check_en) begin
            // vs / de pass through with exactly one clock of delay
            if (o_vs !== vs_q) bad("vs delay", vs_q, o_vs);
            if (o_de !== de_q) bad("de delay", de_q, o_de);
            if (!de_q && o_data !== 24'd0) bad("data in blanking", 0, o_data);
            if (de_q && enable) begin
                npix = npix + 1;
                if (o_data !== expect_pix(pat_id, hq3, vq3)) bad("pixel", expect_pix(pat_id, hq3, vq3), o_data);
            end
            if (de_q && !enable && o_data !== 24'd0) bad("data while disabled", 0, o_data);
        end
    end

    // ---------------- key helper
    task press;
        input integer i;
        begin
            key_n[i] = 1'b0;
            repeat (60) @(posedge clk);
            key_n[i] = 1'b1;
            repeat (60) @(posedge clk);
        end
    endtask

    task wait_vsync;                 // returns just after the next vsync rising edge (blanking)
        begin
            @(posedge vs);
            repeat (4) @(posedge clk);
        end
    endtask

    integer p, k;
    initial begin
        errors = 0; npix = 0; check_en = 1'b0; pat_cur = 0; enable = 1'b0; key_n = 4'b1111;
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        #2 rst_n = 1'b1;
        repeat (60) @(negedge clk);

        // --- disabled: keys do nothing, output is black
        press(2); press(0);
        if (pat_id !== 4'd0 || load_sel !== 2'd0) bad("keys must be ignored while disabled", 0, {pat_id, load_sel});
        wait_vsync;
        check_en = 1'b1;
        wait_vsync;                                     // one frame with enable = 0
        wait_vsync;
        enable = 1'b1;
        repeat (20) @(posedge clk);

        // --- all 16 patterns, a full frame each, selected with KEY3
        for (p = 0; p < 16; p = p + 1) begin
            pat_cur = p;
            if (pat_id !== p[3:0]) bad("pattern id", p, pat_id);
            if (digits[3:0] !== ((p >= 10) ? 4'd1 : 4'd0) || digits[7:4] !== ((p >= 10) ? p - 10 : p)) bad("digits of the pattern id", p, digits[7:0]);
            wait_vsync;                                  // frame boundary
            wait_vsync;                                  // one full frame with this pattern
            press(2);                                    // next pattern, in blanking after the vsync
        end
        // wrapped back to 0 after KEY3 on 15
        if (pat_id !== 4'd0) bad("KEY3 wrap 15 -> 0", 0, pat_id);
        press(3);                                        // KEY4 on 0 -> 15
        if (pat_id !== 4'd15) bad("KEY4 wrap 0 -> 15", 15, pat_id);
        press(3);
        if (pat_id !== 4'd14) bad("KEY4 14", 14, pat_id);

        // --- load_sel cycle and reset key
        if (load_sel !== 2'd0) bad("load_sel initial", 0, load_sel);
        press(0); if (load_sel !== 2'd1) bad("load_sel 1", 1, load_sel);
        if (digits[15:12] !== 4'd1) bad("digit 3 shows load_sel", 1, digits[15:12]);
        press(0); if (load_sel !== 2'd2) bad("load_sel 2", 2, load_sel);
        press(0); if (load_sel !== 2'd0) bad("load_sel wrap", 0, load_sel);
        press(0); press(2);
        press(1);
        if (pat_id !== 4'd0 || load_sel !== 2'd0) bad("KEY2 reset", 0, {pat_id, load_sel});

        // --- disabling returns to pattern 0 / load_sel 0
        press(2); press(0);
        if (pat_id !== 4'd1 || load_sel !== 2'd1) bad("state before disable", 5, {pat_id, load_sel});
        enable = 1'b0;
        repeat (4) @(posedge clk);
        if (pat_id !== 4'd0 || load_sel !== 2'd0) bad("state after disable", 0, {pat_id, load_sel});
        wait_vsync;
        wait_vsync;
        check_en = 1'b0;

        $display("tb_hdmi_testpat: active pixels compared=%0d errors=%0d", npix, errors);
        if (npix < 16 * 921600) begin errors = errors + 1; $display("COVERAGE too low: %0d pixels", npix); end
        if (errors == 0) $display("TB_RESULT: PASS tb_hdmi_testpat");
        else             $display("TB_RESULT: FAIL tb_hdmi_testpat errors=%0d", errors);
        $finish;
    end

endmodule
