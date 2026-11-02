// tb_awb_frame.v - self-check of rtl_custom/awb_frame.v (frame-held gray-world AWB) and rtl_custom/div_seq.v
//
// Stream: 64 x 12 pixel frames (16 beats of 4 pixels per line), line blanking 60 clocks, frame blanking 400 clocks, 10 frames:
//   0 colour ramp (normal)      1 all black (sums stay at the initial 1: gains 1.0)      2 all white (every pixel excluded by R+G+B >= 720)
//   3 strongly red (gain R clamped at 0.25)      4 strongly green (gain B clamped at 8.0)      5 normal, other colours
//   6 and 7 truncated: 9 of 12 lines, then the next frame starts (the partial sums of frame 6 are processed at the start of frame 7 but arrive
//     too late for it; with frame 7 truncated as well they are the gains of frame 8)     8 normal      9 normal with noise
//   frame 5 also contains pixels with R+G+B = 720 (excluded) and 719 (counted) at beat-first positions
// Four instances see the same stream: mode 0 (automatic, frame-held gains), mode 1 (unity), mode 2 (manual gains I_man_r/g/b, changed in the
// middle of every frame: the new values must only reach the NEXT frame) and one whose mode is switched in the frame blanking (0 / 1 / 2 / 3 by a
// fixed schedule: every frame must use the gains of its own mode). The readback O_gain_r/g/b is checked at every output beat of every instance.
// The expectation is computed here with integer
// arithmetic from the stream itself: sums over the first pixel of every beat for pixels with 0 <= R+G+B < 720 (plus the initial 1), gain =
// (sum_G << 12) / sum_X clamped to [1024, 32768] (Q4.12), the gains of frame f-1 are applied to frame f (frame 0: 1.0), out = min(255, gain*X >> 12).
// Checks: every output beat of both instances (all 96 bits) against the expectation; valid / tlast exactly DELAY + 2 clocks after the input and
// O_tuser equal to the INPUT tuser (vendor-compatible); the gains never change inside a frame (implied by the beat check); coverage counts.
// A second part tests div_seq against the `/` and `%` operators with 20,000 random and edge operands.
//
// Run: iverilog -g2005 -o sim_awbf.vvp tb_awb_frame.v ../rtl_custom/awb_frame.v ../rtl_custom/div_seq.v ; vvp sim_awbf.vvp
// Final line: TB_RESULT: PASS tb_awb_frame  or  FAIL

`timescale 1ns / 1ps

module tb_awb_frame;

    localparam integer W = 64;
    localparam integer H = 12;
    localparam integer BPL = W / 4;
    localparam integer NFR = 10;
    localparam integer DELAY = 24;

    reg clk, rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg         i_tlast, i_tuser, i_tvalid;
    reg  [95:0] i_tdata;
    wire        a_tlast, a_tuser, a_tvalid;  wire [95:0] a_tdata;  wire a_rdy;
    wire        u_tlast, u_tuser, u_tvalid;  wire [95:0] u_tdata;  wire u_rdy;

    wire        m_tlast, m_tuser, m_tvalid;  wire [95:0] m_tdata;  wire m_rdy;
    wire        s_tlast, s_tuser, s_tvalid;  wire [95:0] s_tdata;  wire s_rdy;
    wire [15:0] a_gr, a_gg, a_gb, u_gr, u_gg, u_gb, m_gr, m_gg, m_gb, s_gr, s_gg, s_gb;
    reg  [15:0] man_r, man_g, man_b;
    reg  [1:0]  mode_s;

    awb_frame #(.IMG_HEIGHT(H), .IMG_WIDTH(W), .DELAY(DELAY)) dut_a (
        .I_clk(clk), .I_rst_n(rst_n), .I_mode(2'd0), .I_man_r(man_r), .I_man_g(man_g), .I_man_b(man_b), .O_gain_r(a_gr), .O_gain_g(a_gg), .O_gain_b(a_gb),
        .I_tlast(i_tlast), .I_tuser(i_tuser), .I_tdata(i_tdata), .I_tvalid(i_tvalid), .I_tready(a_rdy),
        .O_tlast(a_tlast), .O_tuser(a_tuser), .O_tdata(a_tdata), .O_tvalid(a_tvalid), .O_tready(1'b1));
    awb_frame #(.IMG_HEIGHT(H), .IMG_WIDTH(W), .DELAY(DELAY)) dut_u (
        .I_clk(clk), .I_rst_n(rst_n), .I_mode(2'd1), .I_man_r(man_r), .I_man_g(man_g), .I_man_b(man_b), .O_gain_r(u_gr), .O_gain_g(u_gg), .O_gain_b(u_gb),
        .I_tlast(i_tlast), .I_tuser(i_tuser), .I_tdata(i_tdata), .I_tvalid(i_tvalid), .I_tready(u_rdy),
        .O_tlast(u_tlast), .O_tuser(u_tuser), .O_tdata(u_tdata), .O_tvalid(u_tvalid), .O_tready(1'b1));
    awb_frame #(.IMG_HEIGHT(H), .IMG_WIDTH(W), .DELAY(DELAY)) dut_m (
        .I_clk(clk), .I_rst_n(rst_n), .I_mode(2'd2), .I_man_r(man_r), .I_man_g(man_g), .I_man_b(man_b), .O_gain_r(m_gr), .O_gain_g(m_gg), .O_gain_b(m_gb),
        .I_tlast(i_tlast), .I_tuser(i_tuser), .I_tdata(i_tdata), .I_tvalid(i_tvalid), .I_tready(m_rdy),
        .O_tlast(m_tlast), .O_tuser(m_tuser), .O_tdata(m_tdata), .O_tvalid(m_tvalid), .O_tready(1'b1));
    awb_frame #(.IMG_HEIGHT(H), .IMG_WIDTH(W), .DELAY(DELAY)) dut_s (
        .I_clk(clk), .I_rst_n(rst_n), .I_mode(mode_s), .I_man_r(man_r), .I_man_g(man_g), .I_man_b(man_b), .O_gain_r(s_gr), .O_gain_g(s_gg), .O_gain_b(s_gb),
        .I_tlast(i_tlast), .I_tuser(i_tuser), .I_tdata(i_tdata), .I_tvalid(i_tvalid), .I_tready(s_rdy),
        .O_tlast(s_tlast), .O_tuser(s_tuser), .O_tdata(s_tdata), .O_tvalid(s_tvalid), .O_tready(1'b1));

    // manual gains of frame f (set in the middle of frame f-1) and the mode schedule of dut_s (set in the blanking before frame f)
    reg [15:0] mr [0:NFR];
    reg [15:0] mg [0:NFR];
    reg [15:0] mb [0:NFR];
    reg [1:0]  ms [0:NFR];

    // ---------------- scenes
    integer seed;
    function [23:0] pix;
        input integer x;
        input integer y;
        input integer f;
        integer r, g, b;
        begin
            case (f)
                0: begin r = 60 + y * 10 + (x % 5);  g = 110 + y * 3 + (x % 7); b = 150 - y * 8 + (x % 3); end
                1: begin r = 0; g = 0; b = 0; end
                2: begin r = 255; g = 255; b = 255; end
                3: begin r = 190 + (x % 9); g = 20 + (y % 5); b = 25 + (x % 4); end
                4: begin                                                    // the statistics (first pixel of a beat) see a green scene, the other pixels carry large R / B
                       g = 200 + (y % 7);
                       if ((x % 4) == 0) begin r = 15 + (x % 3); b = 4 + (x % 2); end
                       else              begin r = 150 + (x % 9); b = 120 + (x % 5); end
                   end
                5: begin
                       r = 120 + (x % 11); g = 90 + (y % 13); b = 70 + ((x + y) % 17);
                       if ((x % 8) == 0 && (y % 3) == 0) begin r = 240; g = 240; b = 240; end        // R+G+B = 720: excluded
                       if ((x % 8) == 4 && (y % 3) == 1) begin r = 239; g = 240; b = 240; end        // R+G+B = 719: counted
                       if ((x % 8) == 2) begin r = 40 + (y % 20); b = 45 + (y % 15); end             // 40..59 / 45..59: x 8.0 gives 320..472 (bit 20 of the product)
                   end
                6: begin r = 80 + y * 7 + (x % 6); g = 120 + (x % 8); b = 100 + y * 2; end
                7: begin r = 140 + y; g = 100 + (x % 10); b = 60 + ((x * 3) % 16); end
                8: begin r = 70 + y * 5 + (x % 4); g = 100 + y * 6 + (x % 9); b = 90 + (x % 6); end
                default: begin r = 100 + ($random(seed) & 63); g = 100 + ($random(seed) & 63); b = 100 + ($random(seed) & 63); end
            endcase
            pix = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    reg [23:0] inpix [0:NFR*H*W-1];
    integer    lines_of [0:NFR];                // lines actually sent in each frame

    // ---------------- expectation
    reg [63:0] e_sum_r, e_sum_g, e_sum_b;
    reg [15:0] gr [0:NFR];                       // gains applied to frame f
    reg [15:0] gb [0:NFR];

    function [15:0] clampg;
        input [63:0] q;
        begin
            if (q > 64'd32768)      clampg = 16'd32768;
            else if (q < 64'd1024)  clampg = 16'd1024;
            else                    clampg = q[15:0];
        end
    endfunction

    integer ef, ey, ex, ep;
    reg [23:0] pv;
    reg [9:0]  ps;
    reg [15:0] cr [0:NFR];                       // gains computed from frame f (full or partial sums)
    reg [15:0] cb [0:NFR];
    task compute_expectation;
        begin
            for (ef = 0; ef < NFR; ef = ef + 1) begin
                e_sum_r = 1; e_sum_g = 1; e_sum_b = 1;
                for (ey = 0; ey < lines_of[ef]; ey = ey + 1)
                    for (ex = 0; ex < W; ex = ex + 4) begin
                        pv = inpix[(ef * H + ey) * W + ex];
                        ps = pv[23:16] + pv[15:8] + pv[7:0];
                        if (ps < 720) begin e_sum_r = e_sum_r + pv[23:16]; e_sum_g = e_sum_g + pv[15:8]; e_sum_b = e_sum_b + pv[7:0]; end
                    end
                cr[ef] = clampg((e_sum_g * 4096) / e_sum_r);
                cb[ef] = clampg((e_sum_g * 4096) / e_sum_b);
            end
            // gains applied to frame k: those computed from frame k-1 if it was complete (they are ready long before frame k starts);
            // if frame k-1 was truncated its own division only finishes ~95 clocks into frame k, too late for frame k, so frame k uses
            // the gains computed from frame k-2 (1.0 before the first frame)
            for (ef = 0; ef <= NFR; ef = ef + 1) begin
                if (ef == 0)                    begin gr[ef] = 16'd4096; gb[ef] = 16'd4096; end
                else if (lines_of[ef-1] == H)   begin gr[ef] = cr[ef-1]; gb[ef] = cb[ef-1]; end
                else if (ef == 1)               begin gr[ef] = 16'd4096; gb[ef] = 16'd4096; end
                else                            begin gr[ef] = cr[ef-2]; gb[ef] = cb[ef-2]; end
            end
        end
    endtask

    function [7:0] apply;
        input [15:0] g;
        input [7:0]  v;
        reg [23:0] p;
        begin
            p = g * v;
            apply = (|p[23:20]) ? 8'd255 : p[19:12];
        end
    endfunction

    // ---------------- driver
    integer errors, nbeat_in;
    integer bf, by_, bx_;
    task build_frames;
        begin
            for (bf = 0; bf < NFR; bf = bf + 1)
                for (by_ = 0; by_ < lines_of[bf]; by_ = by_ + 1)
                    for (bx_ = 0; bx_ < W; bx_ = bx_ + 1)
                        inpix[(bf * H + by_) * W + bx_] = pix(bx_, by_, bf);
        end
    endtask

    task send_frame;
        input integer f;
        integer y, bt, k;
        reg [95:0] d;
        begin
            for (y = 0; y < lines_of[f]; y = y + 1) begin
                if (y == 3) begin man_r = mr[f + 1]; man_g = mg[f + 1]; man_b = mb[f + 1]; end     // well after the first output beat of frame f
                for (bt = 0; bt < BPL; bt = bt + 1) begin
                    for (k = 0; k < 4; k = k + 1) d[24*k +: 24] = inpix[(f * H + y) * W + bt * 4 + k];
                    @(negedge clk);
                    i_tdata = d; i_tvalid = 1'b1; i_tuser = (y == 0 && bt == 0); i_tlast = (bt == BPL - 1);
                end
                @(negedge clk);
                i_tvalid = 1'b0; i_tuser = 1'b0; i_tlast = 1'b0; i_tdata = 96'd0;
                repeat (60) @(negedge clk);
            end
            repeat (100) @(negedge clk);                     // the last output beat of frame f has left (DELAY + 2 < 100)
            mode_s = ms[f + 1];
            repeat (300) @(negedge clk);
        end
    endtask

    // ---------------- timing reference: input valid / tlast / tuser delayed by DELAY + 2 clocks
    reg [DELAY+2:0] pv_v, pv_l;
    reg             tu_chk;
    integer         ck;
    initial begin pv_v = 0; pv_l = 0; ck = 0; end
    always @(posedge clk) begin
        pv_v <= {pv_v[DELAY+1:0], i_tvalid};
        pv_l <= {pv_l[DELAY+1:0], i_tvalid & i_tlast};
    end

    // ---------------- output check
    integer of_a, ol_a, ob_a, of_u, ol_u, ob_u, of_m, ol_m, ob_m, of_s, ol_s, ob_s;
    reg     pfa, pfu, va_q, vu_q, pfm, vm_q, pfs, vs_q;
    integer n_a, n_u, n_m, n_s, kk, n_rb;
    reg [95:0] din_e, exp_a, exp_u, exp_m, exp_s;
    reg [15:0] eg_r, eg_g, eg_b;
    initial begin of_a = -1; ol_a = 0; ob_a = 0; of_u = -1; ol_u = 0; ob_u = 0; pfa = 0; pfu = 0; va_q = 0; vu_q = 0; n_a = 0; n_u = 0; end
    initial begin of_m = -1; ol_m = 0; ob_m = 0; of_s = -1; ol_s = 0; ob_s = 0; pfm = 0; pfs = 0; vm_q = 0; vs_q = 0; n_m = 0; n_s = 0; n_rb = 0; end

    // gains of frame f for a given mode
    task mode_gains;
        input [1:0] md;
        input integer f;
        begin
            if (md[1])            begin eg_r = mr[f]; eg_g = mg[f]; eg_b = mb[f]; end
            else if (md == 2'd1)  begin eg_r = 16'd4096; eg_g = 16'd4096; eg_b = 16'd4096; end
            else                  begin eg_r = gr[f]; eg_g = 16'd4096; eg_b = gb[f]; end
        end
    endtask
    task check_rb;
        input [8*6-1:0] nm;
        input [15:0] r, g, b;
        begin
            n_rb = n_rb + 1;
            if (r !== eg_r || g !== eg_g || b !== eg_b) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH t=%0t %0s readback gains %0d %0d %0d expected %0d %0d %0d", $time, nm, r, g, b, eg_r, eg_g, eg_b);
            end
        end
    endtask

    integer t_since_rst;
    initial t_since_rst = 0;
    always @(posedge clk) begin
        if (rst_n) t_since_rst = t_since_rst + 1;
        // vendor-compatible O_tuser, latency of valid / tlast
        if (a_tuser !== i_tuser || u_tuser !== i_tuser) begin errors = errors + 1; if (errors < 10) $display("MISMATCH t=%0t O_tuser must equal the input tuser", $time); end
        if (t_since_rst > 3) begin                                              // right after reset the RAM content is garbage: it must not leak out
            if (a_tvalid !== pv_v[DELAY+1] || u_tvalid !== pv_v[DELAY+1]) begin errors = errors + 1; if (errors < 10) $display("MISMATCH t=%0t O_tvalid latency (want DELAY+2 = %0d clocks)", $time, DELAY + 2); end
            if (a_tlast !== pv_l[DELAY+1] || u_tlast !== pv_l[DELAY+1]) begin errors = errors + 1; if (errors < 10) $display("MISMATCH t=%0t O_tlast latency", $time); end
        end
        // mode 0
        if (a_tuser) pfa = 1'b1;
        if (a_tvalid) begin
            if (pfa) begin of_a = of_a + 1; ol_a = 0; ob_a = 0; pfa = 1'b0; end
            else if (!va_q) begin ol_a = ol_a + 1; ob_a = 0; end
            if (of_a >= 0 && of_a < NFR && ol_a < lines_of[of_a]) begin
                for (kk = 0; kk < 4; kk = kk + 1) begin
                    din_e[24*kk +: 24] = inpix[(of_a * H + ol_a) * W + ob_a * 4 + kk];
                    exp_a[24*kk +: 24] = {apply(gr[of_a], din_e[24*kk+16 +: 8]), din_e[24*kk+8 +: 8], apply(gb[of_a], din_e[24*kk +: 8])};
                end
                n_a = n_a + 1;
                if (a_tdata !== exp_a) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH t=%0t mode 0 frame %0d line %0d beat %0d got %h expected %h (gains %0d %0d)", $time, of_a, ol_a, ob_a, a_tdata, exp_a, gr[of_a], gb[of_a]);
                end
            end
            ob_a = ob_a + 1;
        end
        va_q = a_tvalid;
        // mode 1: unity
        if (u_tuser) pfu = 1'b1;
        if (u_tvalid) begin
            if (pfu) begin of_u = of_u + 1; ol_u = 0; ob_u = 0; pfu = 1'b0; end
            else if (!vu_q) begin ol_u = ol_u + 1; ob_u = 0; end
            if (of_u >= 0 && of_u < NFR && ol_u < lines_of[of_u]) begin
                for (kk = 0; kk < 4; kk = kk + 1) exp_u[24*kk +: 24] = inpix[(of_u * H + ol_u) * W + ob_u * 4 + kk];
                n_u = n_u + 1;
                if (u_tdata !== exp_u) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH t=%0t mode 1 frame %0d line %0d beat %0d got %h expected %h", $time, of_u, ol_u, ob_u, u_tdata, exp_u);
                end
            end
            ob_u = ob_u + 1;
        end
        vu_q = u_tvalid;
        // readback of the automatic and unity instances
        if (a_tvalid && of_a >= 0 && of_a < NFR) begin mode_gains(2'd0, of_a); check_rb("auto  ", a_gr, a_gg, a_gb); end
        if (u_tvalid && of_u >= 0 && of_u < NFR) begin mode_gains(2'd1, of_u); check_rb("unity ", u_gr, u_gg, u_gb); end
        // mode 2: manual gains, R, G and B
        if (m_tuser !== i_tuser || s_tuser !== i_tuser) begin errors = errors + 1; if (errors < 10) $display("MISMATCH t=%0t O_tuser (manual / switched)", $time); end
        if (t_since_rst > 3 && (m_tvalid !== pv_v[DELAY+1] || s_tvalid !== pv_v[DELAY+1] || m_tlast !== pv_l[DELAY+1] || s_tlast !== pv_l[DELAY+1])) begin
            errors = errors + 1; if (errors < 10) $display("MISMATCH t=%0t valid / last latency (manual / switched)", $time);
        end
        if (m_tuser) pfm = 1'b1;
        if (m_tvalid) begin
            if (pfm) begin of_m = of_m + 1; ol_m = 0; ob_m = 0; pfm = 1'b0; end
            else if (!vm_q) begin ol_m = ol_m + 1; ob_m = 0; end
            if (of_m >= 0 && of_m < NFR && ol_m < lines_of[of_m]) begin
                mode_gains(2'd2, of_m);
                for (kk = 0; kk < 4; kk = kk + 1) begin
                    din_e[24*kk +: 24] = inpix[(of_m * H + ol_m) * W + ob_m * 4 + kk];
                    exp_m[24*kk +: 24] = {apply(eg_r, din_e[24*kk+16 +: 8]), apply(eg_g, din_e[24*kk+8 +: 8]), apply(eg_b, din_e[24*kk +: 8])};
                end
                n_m = n_m + 1;
                if (m_tdata !== exp_m) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH t=%0t mode 2 frame %0d line %0d beat %0d got %h expected %h (gains %0d %0d %0d)", $time, of_m, ol_m, ob_m, m_tdata, exp_m, eg_r, eg_g, eg_b);
                end
                check_rb("manual", m_gr, m_gg, m_gb);
            end
            ob_m = ob_m + 1;
        end
        vm_q = m_tvalid;
        // switched mode
        if (s_tuser) pfs = 1'b1;
        if (s_tvalid) begin
            if (pfs) begin of_s = of_s + 1; ol_s = 0; ob_s = 0; pfs = 1'b0; end
            else if (!vs_q) begin ol_s = ol_s + 1; ob_s = 0; end
            if (of_s >= 0 && of_s < NFR && ol_s < lines_of[of_s]) begin
                mode_gains(ms[of_s], of_s);
                for (kk = 0; kk < 4; kk = kk + 1) begin
                    din_e[24*kk +: 24] = inpix[(of_s * H + ol_s) * W + ob_s * 4 + kk];
                    exp_s[24*kk +: 24] = {apply(eg_r, din_e[24*kk+16 +: 8]), apply(eg_g, din_e[24*kk+8 +: 8]), apply(eg_b, din_e[24*kk +: 8])};
                end
                n_s = n_s + 1;
                if (s_tdata !== exp_s) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH t=%0t switched (mode %0d) frame %0d line %0d beat %0d got %h expected %h", $time, ms[of_s], of_s, ol_s, ob_s, s_tdata, exp_s);
                end
                check_rb("switch", s_gr, s_gg, s_gb);
            end
            ob_s = ob_s + 1;
        end
        vs_q = s_tvalid;
    end

    // ---------------- divider test
    reg          d_start;
    reg  [43:0]  d_num;
    reg  [31:0]  d_den;
    wire         d_busy, d_done;
    wire [43:0]  d_quo;
    wire [31:0]  d_rem;
    div_seq #(.NW(44), .WD(32)) u_dv (.clk(clk), .rst_n(rst_n), .start(d_start), .num(d_num), .den(d_den), .busy(d_busy), .done(d_done), .quo(d_quo), .rem(d_rem));
    integer dtests, dbad;
    reg [63:0] qn, qd;
    task div_case;
        input [43:0] n;
        input [31:0] d;
        integer w;
        begin
            @(negedge clk);
            d_num = n; d_den = d; d_start = 1'b1;
            @(negedge clk);
            d_start = 1'b0;
            w = 0;
            while (!d_done && w < 100) begin @(negedge clk); w = w + 1; end
            qn = n; qd = d;
            dtests = dtests + 1;
            if (!d_done || d_quo !== (qn / qd) || d_rem !== (qn % qd) || w != 45) begin
                dbad = dbad + 1;
                if (dbad < 10) $display("MISMATCH divider %0d / %0d: got q=%0d r=%0d expected q=%0d r=%0d (done after %0d clocks)", n, d, d_quo, d_rem, qn / qd, qn % qd, w);
            end
            @(negedge clk);
        end
    endtask

    integer f, i;
    reg [43:0] rn;
    reg [31:0] rd;
    initial begin
        errors = 0; seed = 4711; dtests = 0; dbad = 0; nbeat_in = 0;
        i_tlast = 0; i_tuser = 0; i_tvalid = 0; i_tdata = 0; d_start = 0; d_num = 0; d_den = 1;
        for (f = 0; f < NFR; f = f + 1) lines_of[f] = H;
        lines_of[6] = 9; lines_of[7] = 9;                       // two truncated frames in a row
        // manual gains per frame: 1.0, mixed, G only, saturating (x 8 and x 15.99), zero, small, typical white-balance values
        mr[0] = 16'd4096;  mg[0] = 16'd4096;  mb[0] = 16'd4096;
        mr[1] = 16'd5120;  mg[1] = 16'd3277;  mb[1] = 16'd2867;
        mr[2] = 16'd4096;  mg[2] = 16'd6144;  mb[2] = 16'd4096;
        mr[3] = 16'd32768; mg[3] = 16'd65535; mb[3] = 16'd16384;
        mr[4] = 16'd0;     mg[4] = 16'd1;     mb[4] = 16'd4095;
        mr[5] = 16'd1024;  mg[5] = 16'd2048;  mb[5] = 16'd12288;
        mr[6] = 16'd4710;  mg[6] = 16'd4219;  mb[6] = 16'd3604;
        mr[7] = 16'd16384; mg[7] = 16'd16384; mb[7] = 16'd16384;
        mr[8] = 16'd4505;  mg[8] = 16'd3891;  mb[8] = 16'd5325;
        mr[9] = 16'd4301;  mg[9] = 16'd4096;  mb[9] = 16'd3482;
        mr[10] = 16'd4096; mg[10] = 16'd4096; mb[10] = 16'd4096;
        ms[0] = 2'd0; ms[1] = 2'd2; ms[2] = 2'd1; ms[3] = 2'd0; ms[4] = 2'd3; ms[5] = 2'd2; ms[6] = 2'd0; ms[7] = 2'd2; ms[8] = 2'd1; ms[9] = 2'd2; ms[10] = 2'd0;
        man_r = mr[0]; man_g = mg[0]; man_b = mb[0]; mode_s = ms[0];
        rst_n = 1'b0;
        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (80) @(negedge clk);

        // ---- divider
        div_case(44'd0, 32'd1); div_case(44'd1, 32'd1); div_case(44'd12345678901, 32'd1); div_case(44'hFFFFFFFFFFF, 32'd1);
        div_case(44'hFFFFFFFFFFF, 32'hFFFFFFFF); div_case(44'd4096, 32'd4096); div_case(44'd4095, 32'd4096); div_case(44'd1, 32'd2);
        div_case({32'd7, 12'd0}, 32'd3); div_case({32'hFFFFFFFF, 12'd0}, 32'd1); div_case({32'd1, 12'd0}, 32'hFFFFFFFF);
        for (i = 0; i < 20000; i = i + 1) begin
            rn = {$random(seed), $random(seed)};
            rd = $random(seed);
            if (i % 5 == 0) rd = rd >> ($random(seed) & 31);
            if (rd == 0) rd = 1;
            div_case(rn, rd);
        end

        // ---- frames
        build_frames;
        compute_expectation;
        for (f = 0; f < NFR; f = f + 1) send_frame(f);
        repeat (600) @(negedge clk);

        $display("tb_awb_frame: beats compared: auto=%0d unity=%0d manual=%0d switched=%0d, readback checks=%0d, divider tests=%0d bad=%0d, errors=%0d", n_a, n_u, n_m, n_s, n_rb, dtests, dbad, errors);
        $display("tb_awb_frame: gains applied to frames 1..9 (Q4.12): R %0d %0d %0d %0d %0d %0d %0d %0d %0d   B %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 gr[1], gr[2], gr[3], gr[4], gr[5], gr[6], gr[7], gr[8], gr[9], gb[1], gb[2], gb[3], gb[4], gb[5], gb[6], gb[7], gb[8], gb[9]);
        errors = errors + dbad;
        if (n_a < 6 * H * BPL || n_u < 6 * H * BPL || n_m < 6 * H * BPL || n_s < 6 * H * BPL || n_rb < 24 * H * BPL) begin errors = errors + 1; $display("COVERAGE too low"); end
        if (gr[4] !== 16'd1024 || gb[5] !== 16'd32768) begin errors = errors + 1; $display("the clamp cases were not reached (gain R of frame 3 -> %0d, gain B of frame 4 -> %0d)", gr[4], gb[5]); end
        if (errors == 0) $display("TB_RESULT: PASS tb_awb_frame");
        else             $display("TB_RESULT: FAIL tb_awb_frame errors=%0d", errors);
        $finish;
    end

endmodule
