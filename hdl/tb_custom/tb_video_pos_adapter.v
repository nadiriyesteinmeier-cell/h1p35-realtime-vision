// tb_video_pos_adapter.v - self-checking testbench for rtl_custom/video_pos_adapter.v
//
// Part A  (vtc_chk instances, see tb_vtc_chk.v): the UNMODIFIED lab1 uivtc.v drives the
//         adapter; ground truth = uivtc's own hcnt/vcnt. Seven small geometries and colour
//         delays D = 0..3, several frames each. Also checks that uivtc's user/last really
//         sit on the first pixel of a frame / last pixel of a line (the assumption behind
//         the adapter).
// Part B  (proto_tb instances): the adapter is driven with arbitrary de/user/last patterns.
//         Hand-written expectations (W=8,H=6) for the interesting protocol cases, then random
//         streams (clean frames with bubbles, malformed frames, pure random bits, resets)
//         compared cycle by cycle with a behavioural reference model written in a different
//         style (blocking, integer arithmetic).
//
// Build/run (Icarus Verilog), from F:\fpga_s2\tb_custom:
//   iverilog -g2005 -Wall -o sim_pos.vvp tb_video_pos_adapter.v tb_vtc_chk.v ../rtl_custom/video_pos_adapter.v ../lab1/user_source/hdl_source/vtc/uivtc.v
//   vvp sim_pos.vvp
// Final line: "TB_RESULT: PASS ..." or "TB_RESULT: FAIL ...".

`timescale 1ns / 1ps

module proto_tb #(
    parameter [31:0]  NAME  = "?",
    parameter integer W     = 8,
    parameter integer H     = 6,
    parameter integer D     = 0,
    parameter integer NRAND = 30000,
    parameter integer SEED  = 1
)(
    input  wire        clk,
    output reg         done,
    output reg  [31:0] err_cnt,
    output reg  [31:0] chk_cnt,
    output reg  [31:0] n_pass,
    output reg  [31:0] n_err,
    output reg  [31:0] n_eof
);

    reg         rst_n;
    reg         vde, vuser, vlast;
    reg  [23:0] c_cur;
    reg  [23:0] c_seq;
    reg  [23:0] cq [1:4];
    integer     seed;
    reg         chk_en;

    localparam integer DI = (D == 0) ? 1 : D;
    always @(posedge clk) begin
        cq[1] <= c_cur;
        cq[2] <= cq[1];
        cq[3] <= cq[2];
        cq[4] <= cq[3];
    end
    wire [23:0] rgb_in = (D == 0) ? c_cur : cq[DI];     // colour lags de by D clocks

    wire        o_de, o_sof, o_eol, o_eof, o_fa, o_err;
    wire [23:0] o_rgb;
    wire [11:0] o_x, o_y;

    video_pos_adapter #(.WIDTH(W), .HEIGHT(H), .SYNC_DELAY(D)) dut (
        .clk(clk), .rst_n(rst_n),
        .vid_de(vde), .vid_user(vuser), .vid_last(vlast), .vid_rgb(rgb_in),
        .out_de(o_de), .out_rgb(o_rgb), .out_x(o_x), .out_y(o_y),
        .out_sof(o_sof), .out_eol(o_eol), .out_eof(o_eof),
        .frame_active(o_fa), .geom_err(o_err)
    );

    // ---------------- expected record pipeline (D+1 clocks)
    // {pass[53], x[52:41], y[40:29], sof[28], eol[27], eof[26], rgb[25:2], err[1], frame_active[0]}
    reg [53:0] rq0;
    reg [53:0] rq [1:6];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq[1] <= 54'd0; rq[2] <= 54'd0; rq[3] <= 54'd0;
            rq[4] <= 54'd0; rq[5] <= 54'd0; rq[6] <= 54'd0;
        end
        else begin
            rq[1] <= rq0;
            rq[2] <= rq[1];
            rq[3] <= rq[2];
            rq[4] <= rq[3];
            rq[5] <= rq[4];
            rq[6] <= rq[5];
        end
    end
    wire [53:0] ex = rq[D + 1];

    task bad;
        input [127:0] what;
        input [31:0]  exp_v;
        input [31:0]  act_v;
        begin
            err_cnt = err_cnt + 1;
            if (err_cnt <= 12)
                $display("MISMATCH[%0s] t=%0t %0s expected=%0d actual=%0d (input de=%b user=%b last=%b)",
                         NAME, $time, what, exp_v, act_v, vde, vuser, vlast);
            if (err_cnt >= 100) begin
                $display("TB_RESULT: FAIL tb_video_pos_adapter[%0s] aborted after %0d mismatches", NAME, err_cnt);
                $finish;
            end
        end
    endtask

    always @(negedge clk) begin
        if (chk_en) begin
            chk_cnt = chk_cnt + 1;
            if (ex[53]) n_pass = n_pass + 1;
            if (ex[1])  n_err  = n_err + 1;
            if (ex[26]) n_eof  = n_eof + 1;
            if (o_de  !== ex[53])    bad("out_de",   ex[53],    o_de);
            if (o_x   !== ex[52:41]) bad("out_x",    ex[52:41], o_x);
            if (o_y   !== ex[40:29]) bad("out_y",    ex[40:29], o_y);
            if (o_sof !== ex[28])    bad("out_sof",  ex[28],    o_sof);
            if (o_eol !== ex[27])    bad("out_eol",  ex[27],    o_eol);
            if (o_eof !== ex[26])    bad("out_eof",  ex[26],    o_eof);
            if (o_rgb !== ex[25:2])  bad("out_rgb",  ex[25:2],  o_rgb);
            if (o_err !== ex[1])     bad("geom_err", ex[1],     o_err);
            if (o_fa  !== ex[0])     bad("frame_active", ex[0], o_fa);
        end
    end

    // ---------------- behavioural reference model (blocking, integers)
    integer r_active, r_x, r_y;
    reg     re_pass, re_sof, re_eol, re_eof, re_err;
    integer re_x, re_y;

    task ref_step;
        input de;
        input user;
        input last;
        integer cx, cy;
        reg     viol;
        begin
            re_pass = 0; re_sof = 0; re_eol = 0; re_eof = 0; re_err = 0; re_x = 0; re_y = 0;
            if (de) begin
                if (user && r_active) re_err = 1;
                if (user) begin cx = 0;   cy = 0;   end
                else      begin cx = r_x; cy = r_y; end
                if (user || r_active) begin
                    viol = (cx >= W) || (last && (cx != W - 1));
                    if (viol) begin
                        re_err   = 1;
                        r_active = 0;
                    end
                    else begin
                        re_pass = 1; re_x = cx; re_y = cy; re_sof = user; re_eol = last;
                        if (last) begin
                            re_eof   = (cy == H - 1);
                            r_x      = 0;
                            r_y      = cy + 1;
                            r_active = (cy == H - 1) ? 0 : 1;
                        end
                        else begin
                            r_x      = cx + 1;
                            r_y      = cy;
                            r_active = 1;
                        end
                    end
                end
            end
        end
    endtask

    // ---------------- stimulus primitives (inputs change at negedge)
    task set_bus;
        input de;
        input user;
        input last;
        begin
            @(negedge clk);
            vde = de; vuser = user; vlast = last;
            if (de) begin
                c_seq = c_seq + 24'h000103;
                c_cur = {1'b1, c_seq[22:0]};
            end
            else begin
                c_cur = $random(seed);
            end
        end
    endtask

    // pixel with expectation from the reference model
    task px;
        input de;
        input user;
        input last;
        begin
            set_bus(de, user, last);
            ref_step(de, user, last);
            rq0 = {re_pass, re_x[11:0], re_y[11:0], re_sof, re_eol, re_eof,
                   (re_pass ? c_cur : 24'd0), re_err, (r_active != 0)};
        end
    endtask

    // pixel with hand-written expectation
    task pxe;
        input        de;
        input        user;
        input        last;
        input        e_pass;
        input [11:0] e_x;
        input [11:0] e_y;
        input        e_sof;
        input        e_eol;
        input        e_eof;
        input        e_err;
        input        e_fa;
        begin
            set_bus(de, user, last);
            rq0 = {e_pass, e_x, e_y, e_sof, e_eol, e_eof, (e_pass ? c_cur : 24'd0), e_err, e_fa};
        end
    endtask

    task do_reset;                      // asynchronous reset away from clock edges, bus idle before release
        begin
            @(negedge clk);
            #2 rst_n = 1'b0;
            vde = 1'b1; vuser = 1'b1; vlast = 1'b1; c_cur = 24'hFFFFFF;
            rq0 = 54'd0;
            r_active = 0; r_x = 0; r_y = 0;
            @(negedge clk);
            @(negedge clk);
            vde = 1'b0; vuser = 1'b0; vlast = 1'b0; c_cur = 24'h123456;
            #2 rst_n = 1'b1;
        end
    endtask

    task idle_px;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) px(1'b0, ($random(seed) & 1), ($random(seed) & 1));
        end
    endtask

    // ---------------- hand-written scenarios (W = 8, H = 6)
    integer x, y, k;

    task d_clean_frame;                 // a well-formed 8x6 frame, hand-computed expectations
        begin
            for (y = 0; y < 6; y = y + 1)
                for (x = 0; x < 8; x = x + 1)
                    pxe(1'b1, (x == 0 && y == 0), (x == 7), 1'b1, x, y,
                        (x == 0 && y == 0), (x == 7), (x == 7 && y == 5), 1'b0, !(x == 7 && y == 5));
        end
    endtask

    task d_stray;                       // pixels with no running frame: dropped silently
        input integer n;
        begin
            for (k = 0; k < n; k = k + 1)
                pxe(1'b1, 1'b0, (k == 3), 1'b0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
        end
    endtask

    task directed;
        begin
            // 1. pixels before the first user are dropped silently
            d_stray(6);
            // 2. clean frame, blanking with garbage user/last afterwards
            d_clean_frame;
            for (k = 0; k < 3; k = k + 1) pxe(1'b0, 1'b1, 1'b1, 1'b0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
            // 3. frame with de bubbles (garbage user/last while de = 0) between every two pixels
            pxe(1'b0, 1'b1, 1'b1, 1'b0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
            for (y = 0; y < 6; y = y + 1)
                for (x = 0; x < 8; x = x + 1) begin
                    pxe(1'b1, (x == 0 && y == 0), (x == 7), 1'b1, x, y,
                        (x == 0 && y == 0), (x == 7), (x == 7 && y == 5), 1'b0, !(x == 7 && y == 5));
                    pxe(1'b0, 1'b1, 1'b1, 1'b0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0, 1'b0, !(x == 7 && y == 5));
                end
            // 4. line too long: row 0 fine, row 1 has no last at x = 7, the 9th pixel is a violation
            for (x = 0; x < 8; x = x + 1)
                pxe(1'b1, (x == 0), (x == 7), 1'b1, x, 12'd0, (x == 0), (x == 7), 1'b0, 1'b0, 1'b1);
            for (x = 0; x < 8; x = x + 1)
                pxe(1'b1, 1'b0, 1'b0, 1'b1, x, 12'd1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
            pxe(1'b1, 1'b0, 1'b0, 1'b0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);   // violation: dropped, err, frame aborted
            d_stray(5);                                                                  // rest of the dead frame: dropped silently
            d_clean_frame;                                                               // recovers on the next user
            // 5. line too short: last arrives at x = 4
            for (x = 0; x < 4; x = x + 1)
                pxe(1'b1, (x == 0), 1'b0, 1'b1, x, 12'd0, (x == 0), 1'b0, 1'b0, 1'b0, 1'b1);
            pxe(1'b1, 1'b0, 1'b1, 1'b0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);   // last at x=4: violation
            d_stray(4);
            d_clean_frame;
            // 6. extra line after the frame: stray pixels, dropped silently, no error
            d_stray(9);
            // 7. user in the middle of a frame: restart at that pixel, error pulse
            for (x = 0; x < 8; x = x + 1)
                pxe(1'b1, (x == 0), (x == 7), 1'b1, x, 12'd0, (x == 0), (x == 7), 1'b0, 1'b0, 1'b1);
            for (x = 0; x < 3; x = x + 1)
                pxe(1'b1, 1'b0, 1'b0, 1'b1, x, 12'd1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
            pxe(1'b1, 1'b1, 1'b0, 1'b1, 12'd0, 12'd0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1);   // restart pixel (0,0)
            for (x = 1; x < 8; x = x + 1)
                pxe(1'b1, 1'b0, (x == 7), 1'b1, x, 12'd0, 1'b0, (x == 7), 1'b0, 1'b0, 1'b1);
            for (y = 1; y < 6; y = y + 1)
                for (x = 0; x < 8; x = x + 1)
                    pxe(1'b1, 1'b0, (x == 7), 1'b1, x, y, 1'b0, (x == 7), (x == 7 && y == 5), 1'b0, !(x == 7 && y == 5));
            // 8. user together with last on the first pixel of a W = 8 frame: violation, frame never starts
            pxe(1'b1, 1'b1, 1'b1, 1'b0, 12'd0, 12'd0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
            d_stray(3);
            // 9. reset in the middle of a frame, the rest of the frame (no user) is dropped
            for (x = 0; x < 8; x = x + 1)
                pxe(1'b1, (x == 0), (x == 7), 1'b1, x, 12'd0, (x == 0), (x == 7), 1'b0, 1'b0, 1'b1);
            for (x = 0; x < 3; x = x + 1)
                pxe(1'b1, 1'b0, 1'b0, 1'b1, x, 12'd1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
            do_reset;                                                                    // also resets the reference model
            d_stray(8);
            d_clean_frame;
            idle_px(3);
        end
    endtask

    // ---------------- random streams
    integer f, nl, wl, ln, i2, kind;
    reg     u, l;

    task rand_frame;                    // may be malformed depending on 'kind'
        input integer kd;
        begin
            nl = H;
            if (kd >= 2) nl = H + ({$random(seed)} % 5) - 2;
            if (nl < 1) nl = 1;
            for (ln = 0; ln < nl; ln = ln + 1) begin
                wl = W;
                if (kd >= 2 && ({$random(seed)} % 4) == 0) wl = W + ({$random(seed)} % 5) - 2;
                if (wl < 1) wl = 1;
                for (i2 = 0; i2 < wl; i2 = i2 + 1) begin
                    u = (ln == 0 && i2 == 0);
                    l = (i2 == wl - 1);
                    if (kd >= 3) begin
                        if (({$random(seed)} % 29) == 0) u = !u;
                        if (({$random(seed)} % 29) == 0) l = !l;
                    end
                    if (({$random(seed)} % 4) == 0)
                        px(1'b0, ({$random(seed)} % 2), ({$random(seed)} % 2));   // bubble with garbage user/last
                    px(1'b1, u, l);
                end
                if (({$random(seed)} % 3) == 0) idle_px({$random(seed)} % 4);
            end
            idle_px({$random(seed)} % 4);
        end
    endtask

    initial begin
        done = 1'b0; err_cnt = 0; chk_cnt = 0; n_pass = 0; n_err = 0; n_eof = 0;
        chk_en = 1'b0; seed = SEED; c_seq = 24'd0; c_cur = 24'd0;
        rst_n = 1'b0; vde = 1'b0; vuser = 1'b0; vlast = 1'b0; rq0 = 54'd0;
        r_active = 0; r_x = 0; r_y = 0;
        repeat (3) @(negedge clk);
        #2 rst_n = 1'b1;
        chk_en = 1'b1;
        idle_px(3);

        if (W == 8 && H == 6) begin
            directed;
            do_reset;
        end

        // random: well-formed frames with bubbles, then malformed ones, then pure random bits with resets
        for (f = 0; f < 60; f = f + 1)  rand_frame(1);
        for (f = 0; f < 120; f = f + 1) rand_frame(2);
        for (f = 0; f < 120; f = f + 1) rand_frame(3);
        for (f = 0; f < NRAND; f = f + 1) begin
            kind = {$random(seed)} % 100;
            if (kind == 0 && f > 100 && ({$random(seed)} % 8) == 0) do_reset;
            else px((({$random(seed)} % 8) != 0), (({$random(seed)} % 24) == 0),
                    (({$random(seed)} % (W + 2)) == 0));
        end
        idle_px(D + 6);
        chk_en = 1'b0;
        done = 1'b1;
    end

endmodule


module tb_video_pos_adapter;

    reg clk;
    reg rst_n;
    reg check_en;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- Part A: uivtc-driven checks (small geometries)
    wire [31:0] ea0, ea1, ea2, ea3, ea4, ea5, ea6;
    wire [31:0] ca0, ca1, ca2, ca3, ca4, ca5, ca6;
    wire [31:0] fa0, fa1, fa2, fa3, fa4, fa5, fa6;

    // a0..a3: 8x6 active in a 14x10 frame, colour lag D = 0..3
    vtc_chk #(.NAME("a0"), .H_ACT(8), .H_FRM(14), .H_SS(10), .H_SE(12), .V_ACT(6), .V_FRM(10), .V_SS(7), .V_SE(9), .D(0))
        a0 (.clk(clk), .rst_n(rst_n), .check_en(check_en), .a_de(), .a_rgb(), .a_x(), .a_y(), .a_sof(), .a_eol(), .a_eof(),
            .a_geom_err(), .x_eof(), .x_fidx(), .err_cnt(ea0), .chk_cnt(ca0), .eof_cnt(fa0));
    vtc_chk #(.NAME("a1"), .H_ACT(8), .H_FRM(14), .H_SS(10), .H_SE(12), .V_ACT(6), .V_FRM(10), .V_SS(7), .V_SE(9), .D(1))
        a1 (.clk(clk), .rst_n(rst_n), .check_en(check_en), .a_de(), .a_rgb(), .a_x(), .a_y(), .a_sof(), .a_eol(), .a_eof(),
            .a_geom_err(), .x_eof(), .x_fidx(), .err_cnt(ea1), .chk_cnt(ca1), .eof_cnt(fa1));
    vtc_chk #(.NAME("a2"), .H_ACT(8), .H_FRM(14), .H_SS(10), .H_SE(12), .V_ACT(6), .V_FRM(10), .V_SS(7), .V_SE(9), .D(2))
        a2 (.clk(clk), .rst_n(rst_n), .check_en(check_en), .a_de(), .a_rgb(), .a_x(), .a_y(), .a_sof(), .a_eol(), .a_eof(),
            .a_geom_err(), .x_eof(), .x_fidx(), .err_cnt(ea2), .chk_cnt(ca2), .eof_cnt(fa2));
    vtc_chk #(.NAME("a3"), .H_ACT(8), .H_FRM(14), .H_SS(10), .H_SE(12), .V_ACT(6), .V_FRM(10), .V_SS(7), .V_SE(9), .D(3))
        a3 (.clk(clk), .rst_n(rst_n), .check_en(check_en), .a_de(), .a_rgb(), .a_x(), .a_y(), .a_sof(), .a_eol(), .a_eof(),
            .a_geom_err(), .x_eof(), .x_fidx(), .err_cnt(ea3), .chk_cnt(ca3), .eof_cnt(fa3));
    // a4: another geometry
    vtc_chk #(.NAME("a4"), .H_ACT(5), .H_FRM(9), .H_SS(6), .H_SE(7), .V_ACT(3), .V_FRM(7), .V_SS(4), .V_SE(6), .D(2))
        a4 (.clk(clk), .rst_n(rst_n), .check_en(check_en), .a_de(), .a_rgb(), .a_x(), .a_y(), .a_sof(), .a_eol(), .a_eof(),
            .a_geom_err(), .x_eof(), .x_fidx(), .err_cnt(ea4), .chk_cnt(ca4), .eof_cnt(fa4));
    // a5: one pixel per line
    vtc_chk #(.NAME("a5"), .H_ACT(1), .H_FRM(5), .H_SS(2), .H_SE(3), .V_ACT(2), .V_FRM(6), .V_SS(3), .V_SE(5), .D(0))
        a5 (.clk(clk), .rst_n(rst_n), .check_en(check_en), .a_de(), .a_rgb(), .a_x(), .a_y(), .a_sof(), .a_eol(), .a_eof(),
            .a_geom_err(), .x_eof(), .x_fidx(), .err_cnt(ea5), .chk_cnt(ca5), .eof_cnt(fa5));
    // a6: only one blanking clock between lines
    vtc_chk #(.NAME("a6"), .H_ACT(2), .H_FRM(3), .H_SS(2), .H_SE(3), .V_ACT(2), .V_FRM(4), .V_SS(2), .V_SE(3), .D(1))
        a6 (.clk(clk), .rst_n(rst_n), .check_en(check_en), .a_de(), .a_rgb(), .a_x(), .a_y(), .a_sof(), .a_eol(), .a_eof(),
            .a_geom_err(), .x_eof(), .x_fidx(), .err_cnt(ea6), .chk_cnt(ca6), .eof_cnt(fa6));

    // ---------------- Part B: protocol tests, different geometries and colour lags
    wire        pd0, pd1, pd2, pd3, pd4, pd5;
    wire [31:0] pe0, pe1, pe2, pe3, pe4, pe5;
    wire [31:0] pc0, pc1, pc2, pc3, pc4, pc5;
    wire [31:0] pp0, pp1, pp2, pp3, pp4, pp5;
    wire [31:0] pr0, pr1, pr2, pr3, pr4, pr5;
    wire [31:0] pf0, pf1, pf2, pf3, pf4, pf5;

    proto_tb #(.NAME("p0"), .W(8), .H(6), .D(0), .SEED(11)) p0 (.clk(clk), .done(pd0), .err_cnt(pe0), .chk_cnt(pc0), .n_pass(pp0), .n_err(pr0), .n_eof(pf0));
    proto_tb #(.NAME("p1"), .W(8), .H(6), .D(2), .SEED(12)) p1 (.clk(clk), .done(pd1), .err_cnt(pe1), .chk_cnt(pc1), .n_pass(pp1), .n_err(pr1), .n_eof(pf1));
    proto_tb #(.NAME("p2"), .W(1), .H(1), .D(0), .SEED(13)) p2 (.clk(clk), .done(pd2), .err_cnt(pe2), .chk_cnt(pc2), .n_pass(pp2), .n_err(pr2), .n_eof(pf2));
    proto_tb #(.NAME("p3"), .W(1), .H(3), .D(1), .SEED(14)) p3 (.clk(clk), .done(pd3), .err_cnt(pe3), .chk_cnt(pc3), .n_pass(pp3), .n_err(pr3), .n_eof(pf3));
    proto_tb #(.NAME("p4"), .W(3), .H(1), .D(3), .SEED(15)) p4 (.clk(clk), .done(pd4), .err_cnt(pe4), .chk_cnt(pc4), .n_pass(pp4), .n_err(pr4), .n_eof(pf4));
    proto_tb #(.NAME("p5"), .W(5), .H(4), .D(4), .SEED(16)) p5 (.clk(clk), .done(pd5), .err_cnt(pe5), .chk_cnt(pc5), .n_pass(pp5), .n_err(pr5), .n_eof(pf5));

    integer total_err;
    integer guard;
    reg     cov_ok;

    initial begin
        check_en = 1'b0;
        rst_n    = 1'b0;
        $display("tb_video_pos_adapter: Part A (uivtc) 7 geometries, Part B (protocol) 6 geometries");
        repeat (4) @(negedge clk);
        #2 rst_n = 1'b1;
        repeat (60) @(negedge clk);
        check_en = 1'b1;

        // wait until every uivtc instance has completed 50 frames and all protocol tests are done
        guard = 0;
        while (!(fa0 >= 50 && fa1 >= 50 && fa2 >= 50 && fa3 >= 50 && fa4 >= 50 && fa5 >= 50 && fa6 >= 50 &&
                 pd0 && pd1 && pd2 && pd3 && pd4 && pd5) && guard < 20000000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        repeat (5) @(negedge clk);
        check_en = 1'b0;

        total_err = ea0 + ea1 + ea2 + ea3 + ea4 + ea5 + ea6 + pe0 + pe1 + pe2 + pe3 + pe4 + pe5;
        $display("tb_video_pos_adapter: Part A clocks=%0d frames a0..a6=%0d/%0d/%0d/%0d/%0d/%0d/%0d errors=%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                 ca0, fa0, fa1, fa2, fa3, fa4, fa5, fa6, ea0, ea1, ea2, ea3, ea4, ea5, ea6);
        $display("tb_video_pos_adapter: Part B compared p0..p5=%0d/%0d/%0d/%0d/%0d/%0d errors=%0d/%0d/%0d/%0d/%0d/%0d",
                 pc0, pc1, pc2, pc3, pc4, pc5, pe0, pe1, pe2, pe3, pe4, pe5);
        $display("tb_video_pos_adapter: Part B passed pixels=%0d/%0d/%0d/%0d/%0d/%0d geom_err pulses=%0d/%0d/%0d/%0d/%0d/%0d eofs=%0d/%0d/%0d/%0d/%0d/%0d",
                 pp0, pp1, pp2, pp3, pp4, pp5, pr0, pr1, pr2, pr3, pr4, pr5, pf0, pf1, pf2, pf3, pf4, pf5);

        cov_ok = (guard < 20000000) &&
                 (ca0 > 5000) && (ca5 > 1000) && (ca6 > 1000) &&
                 (pp0 > 2000) && (pp1 > 2000) && (pp2 > 500) && (pp3 > 500) && (pp4 > 500) && (pp5 > 500) &&
                 (pr0 > 100)  && (pr1 > 100)  && (pr2 > 20)  && (pr3 > 50)  && (pr4 > 50)  && (pr5 > 50)  &&
                 (pf0 > 50)   && (pf1 > 50)   && (pf2 > 50)  && (pf3 > 20)  && (pf4 > 50)  && (pf5 > 20);
        if (!cov_ok) begin
            total_err = total_err + 1;
            $display("COVERAGE too low (or timeout): test would be vacuous");
        end
        if (total_err == 0) $display("TB_RESULT: PASS tb_video_pos_adapter");
        else                $display("TB_RESULT: FAIL tb_video_pos_adapter errors=%0d", total_err);
        $finish;
    end

endmodule
