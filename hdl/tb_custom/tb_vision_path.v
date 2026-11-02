// tb_vision_path.v - integration test of rtl_custom/contest_vision_path.v (the block that is wired into
// the baseline top-level) at the real 1280x720 timing
//
// Environment (emulates what design_top_wrapper.v provides):
//   - the UNMODIFIED lab1 uivtc.v (1650x750) -> vtc_vs / vtc_de / vtc_user / vtc_last
//   - rd_rgb = colour_of(x, y) of the pixel whose de was ACT_SKEW = 2 clocks earlier (the suspected frame-buffer
//     RGB lag), garbage while no pixel is due. colour_of is a position-dependent pseudo-random pattern, so a shift
//     by one pixel or one line changes the colour, and a good share of the pixels are 'red' target pixels
//   - base_* = a stand-in for the hdmi_mixer output (vs/de delayed 3, constant data 0xABCDEF) used for bypass
// The DUT uses its DEFAULT parameters (SKEW = 2), so a wrong default SKEW or a wrong timing delay is caught.
//
// Frames (switches change only at the vsync rising edge, i.e. in blanking; first frame after the first user):
//   f0: processed, view original      f1: processed, gray      f2: processed, colour mask
//   f3: processed, tint               f4: processed, original, SW4 on (counting line must appear)
//   f5: BYPASS (tx_* must equal base_* on every clock)
// Checked, every clock: tx_de == vtc_de delayed N, tx_vs == vtc_vs delayed N (N = SKEW + 7 = 9);
// for processed frames and all pixels outside the OSD regions (x >= 600 or y >= 230): tx_data equals the
// independently computed colour for that pixel in the selected view (the pixel position is the uivtc
// hcnt/vcnt delayed accordingly), i.e. data, de and the frame structure are aligned; led[3] == proc_en,
// led[0] (target found) is 1 from frame 1 on, led[1] (adapter error) stays 0.
//
// Build/run (Icarus Verilog), from F:\fpga_s2\tb_custom:
//   iverilog -g2005 -Wall -o sim_vision.vvp tb_vision_path.v ../rtl_custom/contest_vision_path.v ../rtl_custom/video_pos_adapter.v \
//     ../rtl_custom/rgb_to_gray.v ../rtl_custom/color_segment.v ../rtl_custom/frame_bbox.v ../rtl_custom/view_mux.v \
//     ../rtl_custom/sync_delay.v ../rtl_custom/osd_overlay.v ../rtl_custom/osd_bin2bcd.v ../rtl_custom/osd_font_rom.v \
//     ../rtl_custom/osd_logo_rom.v ../lab1/user_source/hdl_source/vtc/uivtc.v
//   vvp sim_vision.vvp
// Final line: "TB_RESULT: PASS ..." or "TB_RESULT: FAIL ...".

`timescale 1ns / 1ps

module tb_vision_path;

    localparam integer ACT_SKEW = 2;
    localparam integer N        = 9;            // contract: SKEW + 7
    localparam integer NFR      = 6;

    reg clk;
    reg rst_n;
    reg check_en;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- baseline timing generator (unmodified source)
    wire vvs, vhs, vde, vuser, vlast;
    uivtc #(.H_ActiveSize(1280), .H_FrameSize(1650), .H_SyncStart(1390), .H_SyncEnd(1430),
            .V_ActiveSize(720),  .V_FrameSize(750),  .V_SyncStart(725),  .V_SyncEnd(730)) u_vtc (
        .I_vtc_rstn(rst_n), .I_vtc_clk(clk),
        .O_vtc_vs(vvs), .O_vtc_hs(vhs), .O_vtc_de_valid(vde), .O_vtc_user(vuser), .O_vtc_last(vlast)
    );

    // ground truth coordinates (generator counters delayed by the 2 clocks of its output stage)
    reg [11:0] hq1, hq2, vq1, vq2;
    always @(posedge clk) begin
        hq1 <= u_vtc.hcnt; hq2 <= hq1;
        vq1 <= u_vtc.vcnt; vq2 <= vq1;
    end

    // histories: index k = value k clocks ago
    reg        vde_h  [1:16];
    reg        vvs_h  [1:16];
    reg        vuser_h[1:16];
    reg [11:0] px_h   [1:16];
    reg [11:0] py_h   [1:16];
    integer k;
    always @(posedge clk) begin
        vde_h[1] <= vde;  vvs_h[1] <= vvs;  vuser_h[1] <= vuser;  px_h[1] <= hq2;  py_h[1] <= vq2;
        for (k = 2; k <= 16; k = k + 1) begin
            vde_h[k] <= vde_h[k-1];  vvs_h[k] <= vvs_h[k-1];  vuser_h[k] <= vuser_h[k-1];
            px_h[k] <= px_h[k-1];    py_h[k] <= py_h[k-1];
        end
    end

    // position-dependent colour pattern (integer arithmetic; ~1/6 of the pixels satisfy the 'red' rule)
    function [23:0] colour_of;
        input [11:0] x;
        input [11:0] y;
        integer r, g, b;
        begin
            r = x * 7 + y * 3;
            g = x * 5 + y * 11 + 17;
            b = x * 13 + y * 2 + 101;
            colour_of = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    // frame-buffer RGB with the injected lag
    reg [23:0] gcnt;
    initial gcnt = 24'd0;
    always @(posedge clk) gcnt <= gcnt + 24'h010101;
    wire [23:0] rd_rgb = vde_h[ACT_SKEW] ? colour_of(px_h[ACT_SKEW], py_h[ACT_SKEW]) : (24'hC0FFEE ^ gcnt);

    // baseline mixer stand-in
    wire        base_vs   = vvs_h[3];
    wire        base_de   = vde_h[3];
    wire [23:0] base_data = vde_h[3] ? 24'hABCDEF : 24'd0;

    // ---------------- DUT
    reg  [3:0]  sw;
    wire        tx_vs, tx_de;
    wire [23:0] tx_data;
    wire [3:0]  led;
    contest_vision_path dut (
        .clk(clk), .rst_n_async(rst_n),
        .vtc_vs(vvs), .vtc_de(vde), .vtc_user(vuser), .vtc_last(vlast), .rd_rgb(rd_rgb),
        .base_vs(base_vs), .base_de(base_de), .base_data(base_data),
        .sw(sw),
        .tx_vs(tx_vs), .tx_de(tx_de), .tx_data(tx_data), .led(led)
    );

    // ---------------- independent expectation functions (integer arithmetic)
    function [23:0] view_px;
        input [1:0]  mode;
        input [11:0] x;
        input [11:0] y;
        integer r, g, b, yy;
        reg [23:0] c;
        reg        hit;
        begin
            c = colour_of(x, y);
            r = c[23:16]; g = c[15:8]; b = c[7:0];
            yy = (77 * r + 150 * g + 29 * b) / 256;
            hit = (r >= 80) && ((r - g) >= 30) && ((r - b) >= 30);
            case (mode)
                2'd0: view_px = c;
                2'd1: view_px = {yy[7:0], yy[7:0], yy[7:0]};
                2'd2: view_px = hit ? 24'hFFFFFF : 24'h000000;
                default: view_px = hit ? 24'hFF00FF : c;
            endcase
        end
    endfunction

    // switch table per frame: {sw3, sw2, sw1, sw0}
    function [3:0] sw_of_frame;
        input integer f;
        begin
            case (f)
                0: sw_of_frame = 4'b0001;       // processed, original
                1: sw_of_frame = 4'b0011;       // gray        (sw[2:1] = 01)
                2: sw_of_frame = 4'b0101;       // colour mask (sw[2:1] = 10)
                3: sw_of_frame = 4'b0111;       // tint        (sw[2:1] = 11)
                4: sw_of_frame = 4'b1001;       // processed, original, counting line / box / cross on
                5: sw_of_frame = 4'b0000;       // bypass
                default: sw_of_frame = 4'b0001;
            endcase
        end
    endfunction

    // ---------------- frame sequencing: change the switches at the vsync rising edge after the first user
    integer fr;
    reg     seen_user;
    reg     vvs_q;
    initial begin fr = 0; seen_user = 1'b0; vvs_q = 1'b0; end
    always @(posedge clk) begin
        vvs_q <= vvs;
        if (vuser) seen_user <= 1'b1;
        if (seen_user && vvs && !vvs_q) begin
            fr <= fr + 1;
            sw <= sw_of_frame(fr + 1);
        end
    end

    // ---------------- checks
    // the DUT samples the async switches with 2 flip-flops: the effective switch value lags 2 clocks
    reg [3:0] sw_m1, sw_m2;
    always @(posedge clk) begin sw_m1 <= sw; sw_m2 <= sw_m1; end
    integer errors, chk, data_chk, byp_chk, line_chk;
        reg     data_en;                        // first user has reached the output
    reg [3:0] sw_cur;
    reg [11:0] ex_x, ex_y;
    reg [23:0] ex_c;

    task bad;
        input [127:0] what;
        input [31:0]  e;
        input [31:0]  a;
        begin
            errors = errors + 1;
            if (errors <= 12)
                $display("MISMATCH t=%0t frame=%0d %0s expected=%h actual=%h (x=%0d y=%0d sw=%b)",
                         $time, fr, what, e, a, px_h[N], py_h[N], sw);
            if (errors >= 100) begin
                $display("TB_RESULT: FAIL tb_vision_path aborted after %0d mismatches", errors);
                $finish;
            end
        end
    endtask

    always @(negedge clk) begin
        if (check_en) begin
            chk = chk + 1;
            if (vuser_h[N] === 1'b1) data_en = 1'b1;
            sw_cur = sw_m2;
            if (sw_cur[0] === 1'b1) begin
                // processed path: timing signals are the generator's, delayed N
                if (tx_de !== vde_h[N]) bad("tx_de", vde_h[N], tx_de);
                if (tx_vs !== vvs_h[N]) bad("tx_vs", vvs_h[N], tx_vs);
                if (led[3] !== 1'b1)    bad("led3", 1, led[3]);
                if (led[1] !== 1'b0)    bad("LED2_geom_err", 0, led[1]);
                if (led[2] !== 1'b0)    bad("LED3_frame_id4", 0, led[2]);
                if (data_en && vde_h[N] === 1'b1) begin
                    ex_x = px_h[N]; ex_y = py_h[N];
                    if (fr >= 1 && led[0] !== 1'b1) bad("led0_found", 1, led[0]);
                    if (sw_cur[3]) begin
                        // counting line (x = 640, 641, LINE_COLOR) must be drawn; the box (outside the image) and
                        // the crosshair (around the middle) are not predicted, so those places are not compared
                        if ((ex_x == 640 || ex_x == 641) && ex_y >= 230 && (ex_y < 340 || ex_y > 380)) begin
                            line_chk = line_chk + 1;
                            if (tx_data !== 24'h00E5FF) bad("line_pixel", 24'h00E5FF, tx_data);
                        end
                        else if (!(ex_x >= 620 && ex_x <= 660) && !(ex_y >= 340 && ex_y <= 380) &&
                                 ex_x >= 4 && ex_x <= 1275 && ex_y >= 4 && ex_y <= 715 && (ex_x >= 600 || ex_y >= 230)) begin
                            ex_c = view_px(sw_cur[2:1], ex_x, ex_y);
                            data_chk = data_chk + 1;
                            if (tx_data !== ex_c) bad("tx_data_extra", ex_c, tx_data);
                        end
                    end
                    else if (ex_x >= 600 || ex_y >= 230) begin
                        ex_c = view_px(sw_cur[2:1], ex_x, ex_y);
                        data_chk = data_chk + 1;
                        if (tx_data !== ex_c) bad("tx_data", ex_c, tx_data);
                    end
                end
                if (vde_h[N] !== 1'b1 && tx_data !== 24'd0) bad("tx_data_in_blanking", 0, tx_data);
            end
            else begin
                // bypass: the baseline signals, untouched
                byp_chk = byp_chk + 1;
                if (tx_vs !== base_vs || tx_de !== base_de || tx_data !== base_data)
                    bad("bypass", {6'd0, base_vs, base_de, base_data}, {6'd0, tx_vs, tx_de, tx_data});
                if (led[3] !== 1'b0) bad("led3_bypass", 0, led[3]);
            end
        end
    end

    integer guard, total_err;
`ifdef NEG_SKEW
    defparam dut.SKEW = `NEG_SKEW;          // negative control: a wrong SKEW must be detected
`endif

    initial begin
        errors = 0; chk = 0; data_chk = 0; byp_chk = 0; line_chk = 0; guard = 0; data_en = 1'b0;
        check_en = 1'b0;
        sw = sw_of_frame(0); sw_m1 = sw_of_frame(0); sw_m2 = sw_of_frame(0);
        rst_n = 1'b0;
        $display("tb_vision_path: uivtc 1280x720 -> contest_vision_path (default SKEW=2, N=%0d), frames: orig, gray, mask, tint, bypass", N);
        repeat (4) @(negedge clk);
        #2 rst_n = 1'b1;
        repeat (60) @(negedge clk);
        check_en = 1'b1;
        while (fr < NFR && guard < 12000000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        repeat (20) @(negedge clk);
        check_en = 1'b0;

        total_err = errors;
        $display("tb_vision_path: clocks=%0d data pixels checked=%0d line pixels checked=%0d bypass clocks checked=%0d errors=%0d",
                 chk, data_chk, line_chk, byp_chk, errors);
        if (guard >= 12000000 || data_chk < 3500000 || line_chk < 800 || byp_chk < 800000) begin
            total_err = total_err + 1;
            $display("COVERAGE too low (or timeout): test would be vacuous");
        end
        if (total_err == 0) $display("TB_RESULT: PASS tb_vision_path");
        else                $display("TB_RESULT: FAIL tb_vision_path errors=%0d", total_err);
        $finish;
    end

endmodule
