#!/usr/bin/env python3
"""wb_mutants.py - mutation test of the white-balance page RTL (rtl_custom/awb_frame.v, wb_ctrl.v, wb_osd.v) and of isp_color.v

Every mutant is one small text substitution in a copy of the module (logs_custom/wb_mut/<id>/); the matching testbench
(tb_awb_frame / tb_wb_ctrl / tb_wb_osd) must FAIL on it. First the unmodified RTL is run as the control (must PASS), and every
mutant text is checked to occur exactly once before anything runs. Icarus Verilog.

    python tools/wb/wb_mutants.py [--only awb|ctrl|osd|isp|motion|lat|top] [-j N]

Exit code 0 only if the controls pass and every mutant is killed.
"""
import argparse
import concurrent.futures as cf
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
IV = os.path.join(ROOT, 'tools', 'iverilog', 'ucrt64', 'bin')
RTL = os.path.join(ROOT, 'rtl_custom')
TB = os.path.join(ROOT, 'tb_custom')
WORK = os.path.join(ROOT, 'logs_custom', 'wb_mut')

SUITES = {
    'awb': ('awb_frame.v', 'tb_awb_frame.v', ['div_seq.v'], 'tb_awb_frame'),
    'ctrl': ('wb_ctrl.v', 'tb_wb_ctrl.v', ['key_debounce.v'], 'tb_wb_ctrl'),
    'osd': ('wb_osd.v', 'tb_wb_osd.v', [], 'tb_wb_osd'),
    'isp': ('isp_color.v', 'tb_isp_color.v', ['div_seq.v'], 'tb_isp_color'),
    # contest_work_v3_adv (docs/ADV_2026-10-26.md)
    'motion': ('motion_det.v', 'tb_motion_det.v', [], 'tb_motion_det'),
    'lat': ('lat_probe.v', 'tb_lat_probe.v', [], 'tb_lat_probe'),
    'top': ('top_osd.v', 'tb_top_osd.v', ['osd_logo_rom.v', 'osd_bin2bcd.v'], 'tb_top_osd'),
    'he': ('he_eq.v', 'tb_he_eq.v', [], 'tb_he_eq'),
    'ispg': ('isp_color.v', 'tb_isp_color.v', ['div_seq.v'], 'tb_isp_color'),       # isp_color with the grey gate and the neutral initial gains
}
# extra sources (absolute) and simulator arguments per suite; the isp suite needs the generated LSC ROM and the reference-model vectors
# (python tools/shade/isp_color_ref.py --table logs_custom/lsc/lsc_table.hex --out logs_custom/isp_color_vec)
EXTRA_SRC = {'isp': [os.path.join(ROOT, 'logs_custom', 'lsc', 'lsc_rom.v')],
             'ispg': [os.path.join(ROOT, 'logs_custom', 'lsc', 'lsc_rom.v')]}
EXTRA_ARGS = {'isp': ['+VEC=' + os.path.join(ROOT, 'logs_custom', 'isp_color_vec').replace(os.sep, '/')],
              # grey gate on (python tools/shade/isp_color_ref.py ... --out logs_custom/isp_color_vec_g --gray-sh 1 --init 13107 8192 16384)
              'ispg': ['+VEC=' + os.path.join(ROOT, 'logs_custom', 'isp_color_vec_g').replace(os.sep, '/')]}
# compile-time parameter overrides per suite
EXTRA_CARGS = {'ispg': ['-P', 'tb_isp_color.GRAY_SH=1', '-P', 'tb_isp_color.INIT_R=13107', '-P', 'tb_isp_color.INIT_G=8192', '-P', 'tb_isp_color.INIT_B=16384']}

MUTANTS = {
    'ispg': [
        ("wire [8:0]  otl = og >> GRAY_SH;", "wire [8:0]  otl = og >> (GRAY_SH + 1);"),
        ("({1'b0, o_data[23:16]} + otl >= og) && ", ""),
        ("({1'b0, o_data[23:16]} <= og + otl) &&", "({1'b0, o_data[23:16]} <= og + otl + 9'd8) &&"),
        ("({1'b0, o_data[7:0]}   + otl >= og) && ", "({1'b0, o_data[7:0]}   + otl > og) && "),
        ("({1'b0, o_data[7:0]}   <= og + otl));", "({1'b0, o_data[7:0]}   <= og + otl + 9'd1));"),
        ("wire        o_st = o_s && o_gray;", "wire        o_st = o_s;"),
        ("wire [25:0] v_n = o_st ? TARGET : 26'd0;", "wire [25:0] v_n = o_s ? TARGET : 26'd0;"),
        ("a_r <= INIT_R; a_g <= INIT_G; a_b <= INIT_B;", "a_r <= INIT_R; a_g <= INIT_G; a_b <= INIT_R;"),
        ("wire [8:0]  og  = {1'b0, o_data[15:8]};", "wire [8:0]  og  = {1'b0, o_data[23:16]};"),
    ],
    'he': [
        ("wire        samp  = s_de && !s_x[0] && !s_y[0] && (bst == 2'd0);", "wire        samp  = s_de && !s_x[0] && (bst == 2'd0);"),
        ("s = {2'b00, p[23:16]} + {1'b0, p[15:8], 1'b0} + {2'b00, p[7:0]};", "s = {2'b00, p[23:16]} + {2'b00, p[15:8]} + {2'b00, p[7:0]};"),
        ("hist[haddr] <= hq + 18'd1;", "hist[haddr] <= hq + 18'd2;"),
        ("else if (bst != 2'd0 && !bv[8])    hist[haddr] <= 18'd0;", "else if (1'b0)    hist[haddr] <= 18'd0;"),
        ("wire [17:0] cdf_n = cdf + hq;", "wire [17:0] cdf_n = hq;"),
        ("p2_prod <= p1_cdf * K + 35'd33554432;", "p2_prod <= p1_cdf * K;"),
        ("p1_bar <= (hq[17:12] != 6'd0) ? 7'd127 : hq[11:5];", "p1_bar <= hq[11:5];"),
        ("lut_ok <= first_done;", "lut_ok <= 1'b1;"),
        ("else if (in_vs != vs_q) en_f <= enable && lut_ok;", "else if (in_vs != vs_q) en_f <= enable;"),
        ("addc = t[9] ? 8'd0 : t[8] ? 8'd255 : t[7:0];", "addc = t[8] ? 8'd255 : t[7:0];"),
        ("addc = t[9] ? 8'd0 : t[8] ? 8'd255 : t[7:0];", "addc = t[9] ? 8'd0 : t[7:0];"),
        ("s1_dy <= {1'b0, ly} - {1'b0, yv};", "s1_dy <= {1'b0, ly} - {1'b0, yv} + 9'd1;"),
        ("wire [6:0]  hgt  = 7'd127 - gdy[6:0];", "wire [6:0]  hgt  = 7'd126 - gdy[6:0];"),
        ("s1_cur <= (hgt == gc) || ({1'b0, hgt} == {1'b0, gc} + 8'd1);", "s1_cur <= (hgt == gc);"),
        ("{1'b0, hgt} == {1'b0, gc} + 8'd1", "hgt == gc + 7'd1"),
        ("(y >= GY) && (gdy < 12'd128);", "(y >= GY) && (gdy < 12'd127);"),
        ("else if (s1_g)           out_data <= {1'b0, v_eq[23:17], 1'b0, v_eq[15:9], 1'b0, v_eq[7:1]};", "else if (s1_g)           out_data <= v_eq;"),
        ("wire        eof   = s_de && (s_x == 12'd1279) && (s_y == 12'd719);", "wire        eof   = s_de && (s_x == 12'd1279) && (s_y == 12'd716);"),
        ("wire [7:0]  haddr = (bst != 2'd0) ? bv[7:0] : ybin;", "wire [7:0]  haddr = bv[7:0];"),
        ("if (p1_v) bar[p1_a] <= p1_bar;", "if (p1_v) bar[p2_a] <= p1_bar;"),
        ("wire [6:0]  gc   = gl[7:1];", "wire [6:0]  gc   = gl[6:0];"),
    ],
    'motion': [
        ("wire       eol = de && (x == 12'd1279);", "wire       eol = de && (x == 12'd1278);"),
        ("if (xc == 6'd39) begin xc_n <= 6'd0; bx_n <= bx + 5'd1; end", "if (xc == 6'd38) begin xc_n <= 6'd0; bx_n <= bx + 5'd1; end"),
        ("{1'b0, rgb[15:8], 1'b0}", "{2'b00, rgb[15:8]}"),
        ("wire        sline = (y[1:0] == 2'd2);", "wire        sline = (y[1:0] == 2'd1);"),
        ("((yc == 6'd2) ? 15'd0 : ring[0])", "ring[0]"),
        ("wire [7:0]  cur   = ring[0][14:7];", "wire [7:0]  cur   = ring[0][13:6];"),
        ("wire        mbit  = ready && (adif >= THR);", "wire        mbit  = ready && (adif > THR);"),
        ("wire        mbit  = ready && (adif >= THR);", "wire        mbit  = (adif >= THR);"),
        ("wire [7:0]  adif  = dif[8] ? (8'd0 - dif[7:0]) : dif[7:0];", "wire [7:0]  adif  = dif[7:0];"),
        ("2'd0: if (eol && yc == 6'd38)", "2'd0: if (eol && yc == 6'd37)"),
        ("if (ci < f_bx0) f_bx0 <= ci;", "if (ci > f_bx0) f_bx0 <= ci;"),
        ("if (crow > f_by1) f_by1 <= crow;", "if (crow > f_by1) f_by1 <= ci;"),
        ("map_wd <= {mbit, mrow[31:1]};", "map_wd <= mrow;"),
        ("                f_cnt <= 10'd0;", "                f_cnt <= f_cnt;"),
        ("ring[31] <= (st == 2'd2) ? ring[0] : ring_new;", "ring[31] <= ring_new;"),
        ("always @(posedge clk) if (st == 2'd2) prev_mem[paddr] <= cur;", "always @(posedge clk) if (st == 2'd1) prev_mem[paddr] <= cur;"),
        ("else begin ci <= ci + 5'd1; st <= 2'd1; end", "else begin ci <= ci + 5'd1; st <= 2'd2; end"),
        ("if (de && sline && xc[1:0] == 2'd2)", "if (de && sline && xc[1:0] == 2'd1)"),
        ("wire [9:0]  paddr = {crow, ci};", "wire [9:0]  paddr = {ci, crow};"),
        ("acc <= ((xc == 6'd2) ? 12'd0 : acc)", "acc <= acc"),
    ],
    'lat': [
        ("gray <= bin ^ (bin >> 1);", "gray <= bin;"),
        ("for (i = W - 2; i >= 0; i = i - 1) b[i] = b[i+1] ^ s2[i];", "for (i = W - 2; i >= 0; i = i - 1) b[i] = s2[i];"),
        ("wire [19:0] tnow = tuser ? ts : ts_l;", "wire [19:0] tnow = ts_l;"),
        ("wire        hit  = tvalid & (armed | tuser);", "wire        hit  = tvalid & armed;"),
        ("if (tvalid)     armed <= 1'b0;", "if (tvalid & ~tuser) armed <= 1'b0;"),
        ("{p_ts, p_ts, p_fc, p_fc, p_ts, din[7:0]}", "{p_ts, p_fc, p_ts, p_fc, p_ts, din[7:0]}"),
        ("wire [15:0] fnum = tuser ? fcount + 16'd1 : fcount;", "wire [15:0] fnum = fcount;"),
        ("fc_gray <= fcount ^ (fcount >> 1);", "fc_gray <= fcount;"),
        ("wire [16:0] dcap = (d > 20'd99999) ? 17'd99999 : d[16:0];", "wire [16:0] dcap = d[16:0];"),
        ("wire [15:0] fd   = f0 - p2[15:0];", "wire [15:0] fd   = f0 - p1[15:0];"),
        ("wire        ok   = (p0 == p1) && ", "wire        ok   = "),
        (" && (p2 == rgb) && ", " && "),
        ("if (nh == HOLD - 1) begin", "if (nh == HOLD) begin"),
        ("max_us <= (dcap > wmax) ? dcap : wmax;", "max_us <= wmax;"),
        ("t0 <= ts; f0 <= fc_cam;", "t0 <= ts + 20'd1; f0 <= fc_cam;"),
        ("lat_fr <= (fd > 16'd9) ? 4'd9 : fd[3:0];", "lat_fr <= fd[3:0];"),
        ("                if (ok) begin", "                if (1'b1) begin"),
        ("if (pre == DIV - 1) begin pre <= 7'd0;", "if (pre == DIV) begin pre <= 7'd0;"),
    ],
    'top': [
        ("wire        hide = (y == 12'd0) && (x < 12'd8);", "wire        hide = (y == 12'd0) && (x < 12'd4);"),
        ("else if (t_col == 4'd11) begin t_k <= t_k + 4'd1; t_col <= 4'd0; end", "else if (t_col == 4'd10) begin t_k <= t_k + 4'd1; t_col <= 4'd0; end"),
        ("if (x == TX - 12'd1)     begin t_k <= 4'd0; t_col <= 4'd0; end", "if (x == TX)     begin t_k <= 4'd0; t_col <= 4'd0; end"),
        ("wire [9:0]  pr = {2'b00, v_dark[23:16]} + 10'd765;", "wire [9:0]  pr = {2'b00, v_dark[23:16]} + 10'd764;"),
        ("wire        logo_in  = (x >= LOGO_X) && (ldx < LOGO_W)", "wire        logo_in  = (x >= LOGO_X) && (ldx <= LOGO_W)"),
        ("{ldy[6:0], 7'd0} + {2'd0, ldy[6:0], 5'd0} + {2'd0, ldx}", "{ldy[6:0], 7'd0} + {2'd0, ldx}"),
        ("s2_cls <= logo_q[5];", "s2_cls <= 1'b0;"),
        ("{1'b1, s1_d[23:17], 1'b0, s1_d[15:9], 1'b0, s1_d[7:1]} : s1_d;", "{1'b1, s1_d[22:16], 1'b0, s1_d[15:9], 1'b0, s1_d[7:1]} : s1_d;"),
        ("if (yc == 6'd39) begin yc <= 6'd0; by <= by + 5'd1; end", "if (yc == 6'd38) begin yc <= 6'd0; by <= by + 5'd1; end"),
        ("(x < f_x1 + 12'd4)", "(x < f_x1 + 12'd3)"),
        ("(y < TY + ((f_mot || f_he) ? 12'd60 : 12'd40))", "(y < TY + 12'd60)"),
        ("(t_ln != 2'd2 || f_mot || f_he)", "(1'b1)"),
        ("out_data <= s2_hide ? 24'h000000 : s2_on ? 24'hFFFFFF : v_logo;", "out_data <= s2_on ? 24'hFFFFFF : v_logo;"),
        ("+ {4'd0, mot_bx1, 3'd0} + 12'd39;", "+ {4'd0, mot_bx1, 3'd0} + 12'd40;"),
        ("4'd6: tchar = 6'd41; 4'd7: tchar = dg(v, l[3:0]);", "4'd6: tchar = 6'd42; 4'd7: tchar = dg(v, l[3:0]);"),
        ("4'd4: tchar = dg(v, m[11:8]); 4'd5: tchar = dg(v, m[7:4]);", "4'd4: tchar = dg(v, m[7:4]); 4'd5: tchar = dg(v, m[11:8]);"),
        ("f_l <= lat_bcd[19:8];", "f_l <= lat_bcd[15:4];"),
        ("wire        g_on   = (s1_col >= 4'd1 && s1_col <= 4'd10)", "wire        g_on   = (s1_col >= 4'd0 && s1_col <= 4'd10)"),
        ("if (xc == 6'd39) begin xc_n <= 6'd0; bx_n <= bx + 5'd1; end", "if (xc == 6'd38) begin xc_n <= 6'd0; bx_n <= bx + 5'd1; end"),
    ],
    'awb': [
        ("nf_g = man ? I_man_g : 16'd4096", "nf_g = 16'd4096"),
        ("nf_r = man ? I_man_r :", "nf_r = man ? I_man_b :"),
        ("gu_g = d_user ? nf_g : g_g", "gu_g = nf_g"),
        ("gu_r = d_user ? nf_r : g_r", "gu_r = nf_r"),
        ("g_g <= nf_g; g_b <= nf_b; end", "g_g <= g_g; g_b <= nf_b; end"),
        ("(n[3] ? {1'd0, g, 3'b0} : 20'd0)", "(n[3] ? {2'd0, g, 2'b0} : 20'd0)"),
        ("(n[0] ? {4'd0, g} : 20'd0)", "(n[1] ? {4'd0, g} : 20'd0)"),
        ("{m_gh[k2], 4'd0}", "{1'b0, m_gh[k2], 3'd0}"),
        ("d_data[24*k+12 +: 4]", "d_data[24*k+11 +: 4]"),
        ("wire        man  = I_mode[1];", "wire        man  = (I_mode == 2'd2);"),
        ("assign O_gain_g = g_g;", "assign O_gain_g = g_r;"),
        ("assign O_gain_r = g_r;", "assign O_gain_r = nf_r;"),
        ("(I_mode == 2'd1) ? 16'd4096 : nx_r;", "nx_r;"),
        ("sat12({4'd0, m_gl[k2]} + {m_gh[k2], 4'd0})", "({4'd0, m_gl[k2]} + {m_gh[k2], 4'd0}) >> 12"),
        ("nf_b = man ? I_man_b : (I_mode == 2'd1) ? 16'd4096 : nx_b;", "nf_b = man ? I_man_b : nx_b;"),
    ],
    'isp': [
        ("begin blc = (p > b) ? p - b : 8'd0; end", "begin blc = p - b; end"),
        ("wire [7:0]  kg = raw_u ? 8'd0 : BLK_G;", "wire [7:0]  kg = raw_u ? 8'd0 : BLK_R;"),
        ("wire [7:0]  kr = raw_u ? 8'd0 : BLK_R;", "wire [7:0]  kr = BLK_R;"),
        ("wire        lsc_on = (LSC_EN != 0) && !raw_u;", "wire        lsc_on = (LSC_EN != 0);"),
        ("effg = (|p[27:26]) ? 16'hFFFF : p[25:10];", "effg = p[25:10];"),
        # (p >>> 6 -> p >> 6 is equivalent: the two differ by 2^14, a multiple of 2^12, and only the low 12 bits are kept)
        ("(fy[0] ? d : 13'sd0)", "(fy[1] ? d : 13'sd0)"),
        ("(fy[5] ? d <<< 5 : 13'sd0)", "(fy[5] ? d <<< 4 : 13'sd0)"),
        ("rom_a = (f_st == 2'd1) ? {5'd0, f_row} * NX + {4'd0, f_node} : ({5'd0, f_row} + 9'd1) * NX + {4'd0, f_node};",
         "rom_a = (f_st == 2'd1) ? ({5'd0, f_row} + 9'd1) * NX + {4'd0, f_node} : {5'd0, f_row} * NX + {4'd0, f_node};"),
        ("wire [4:0]  seg_n3    = (bx[8:4] + 5'd3 > 5'd20) ? 5'd20 : bx[8:4] + 5'd3;", "wire [4:0]  seg_n3    = (bx[8:4] + 5'd2 > 5'd20) ? 5'd20 : bx[8:4] + 5'd2;"),
        ("acc_r <= {rt_r, 4'd0}; acc_g <= {rt_g, 4'd0};", "acc_r <= {nx_r, 4'd0}; acc_g <= {rt_g, 4'd0};"),
        ("sl_g <= $signed({2'b00, nx_g}) - $signed({2'b00, rt_g});", "sl_g <= $signed({2'b00, rt_g}) - $signed({2'b00, nx_g});"),
        ("acc_b <= {ls0[11:0], 4'd0};", "acc_b <= {ls1[11:0], 4'd0};"),
        ("wire [9:0]  ly_next   = (ly == IMG_HEIGHT - 1) ? 10'd0 : ly + 10'd1;", "wire [9:0]  ly_next   = ly + 10'd1;"),
        ("wire [31:0] v_g = o_s ? {24'd0, o_data[15:8]}  : 32'd0;", "wire [31:0] v_g = o_s ? {24'd0, o_data[23:16]}  : 32'd0;"),
        ("if (o_u ? 1'b0 : (oy == IMG_HEIGHT - 1))", "if (o_u ? 1'b0 : (oy == IMG_HEIGHT - 2))"),
        ("wire [16:0] avg    = {1'b0, c_g[c_ch]} + {1'b0, est} + 17'd1;", "wire [16:0] avg    = {1'b0, c_g[c_ch]} + {1'b0, est};"),
        ("wire        c_lim = (c_m > GAIN_MAX);", "wire        c_lim = 1'b0;"),
        ("wire [15:0] c_m   = (c_m01 > c_er[2]) ? c_m01 : c_er[2];", "wire [15:0] c_m   = c_m01;"),
        ("wire [15:0] c_m01 = (c_er[0] > c_er[1]) ? c_er[0] : c_er[1];", "wire [15:0] c_m01 = c_er[0];"),
        ("wire [15:0] est    = (est_l < GAIN_MIN) ? GAIN_MIN : est_l;", "wire [15:0] est    = est_l;"),
        ("wire [43:0] c_k   = c_p ? {28'd0, GAIN_MAX} : {18'd0, c_tn};", "wire [43:0] c_k   = c_p ? {29'd0, GAIN_MAX[15:1]} : {18'd0, c_tn};"),
        ("wire [15:0] er_new = ((c_sum[c_ch] == 32'd0) || (|dv_q[43:16])) ? 16'hFFFF : dv_q[15:0];", "wire [15:0] er_new = (c_sum[c_ch] == 32'd0) ? 16'hFFFF : dv_q[15:0];"),
        ("s1 <= (d_data[15:8] >= BLK_G + V_LO)", "s1 <= (d_data[15:8] >= BLK_G)"),
        ("&& (d_data[7:0] < V_HI);", ";"),
        ("3'd0: if (fe && s_n >= TNMIN) begin", "3'd0: if (fe) begin"),
        ("wire [25:0] v_n = o_s ? TARGET : 26'd0;", "wire [25:0] v_n = TARGET;"),
        ("if (c_i == 5'd15) c_st <= 3'd2;", "if (c_i == 5'd14) c_st <= 3'd2;"),
        ("wire [15:0] nf_g = m_man ? I_man_g : m_off ? 16'd4096 : a_g;", "wire [15:0] nf_g = m_man ? I_man_g : m_off ? 16'd4096 : a_r;"),
        ("wire [15:0] gu_b = first ? nf_b : g_b;", "wire [15:0] gu_b = g_b;"),
        ("s_r <= v_r; s_g <= v_g; s_b <= v_b; s_n <= v_n;", "s_r <= 32'd0; s_g <= v_g; s_b <= v_b; s_n <= v_n;"),
        ("wire [31:0] v_r = o_s ? {24'd0, o_data[23:16]} : 32'd0;", "wire [31:0] v_r = o_s ? {24'd0, o_data[47:40]} : 32'd0;"),
        ("else if (first) begin g_r <= nf_r; g_g <= nf_g; g_b <= nf_b; raw_f <= m_off; end", "else if (first) begin g_r <= nf_r; g_g <= nf_g; g_b <= nf_b; raw_f <= 1'b0; end"),
        ("c_mul <= (c_ch == 2'd0) ? c_g[1] : c_g[2];", "c_mul <= (c_ch == 2'd0) ? c_g[2] : c_g[1];"),
        ("{sat12(m_r[k2]), sat12({4'd0, m_gl[k2]} + {m_gh[k2], 4'd0}), sat12(m_b[k2])}", "{sat12(m_r[k2]), sat12({4'd0, m_gl[k2]} + {m_gh[k2], 3'd0}), sat12(m_b[k2])}"),
    ],
    'ctrl': [
        ("wire [9:0] st  = ev_big ? 10'd5 : 10'd1;", "wire [9:0] st  = 10'd1;"),
        ("wire [9:0] st  = ev_big ? 10'd5 : 10'd1;", "wire [9:0] st  = ev_big ? 10'd4 : 10'd1;"),
        ("clamp_h = (v < {1'b0, H_MIN}) ? H_MIN :", "clamp_h = (v < {1'b0, H_MIN}) ? v[9:0] :"),
        ("(v > {1'b0, H_MAX}) ? H_MAX : v[9:0]", "(v > {1'b0, H_MAX}) ? v[9:0] : v[9:0]"),
        ("else if (kd[2]) begin if (kd[3]) o3 <= 1'b1; end", "else if (kd[2]) begin end"),
        ("if (kd[2]) o4 <= 1'b1;", ""),
        ("sel_ev <= a3 & ~o3 & active;", "sel_ev <= ~o3 & active;"),
        ("mode_ev <= a4 & ~o4 & active;", "mode_ev <= a4 & ~o4;"),
        ("if (!active) begin a3 <= 1'b0; a4 <= 1'b0; end", "if (!active) begin a3 <= 1'b0; end"),
        ("if (!active) begin a3 <= 1'b0; a4 <= 1'b0; end", "if (!active) begin a4 <= 1'b0; end"),
        ("sel_ev <= a3 & ~o3 & active;", "sel_ev <= a3 & ~o3;"),
        ("M_MAN:   wb_mode <= M_OFF;", "M_MAN:   wb_mode <= M_AUTO;"),
        ("M_AUTO:  begin wb_mode <= M_MAN; h_r <= clamp_h(ch_r);", "M_AUTO:  begin wb_mode <= M_MAN; h_r <= 10'd100;"),
        ("wire [9:0] b_g = is_man ? h_g : clamp_h(ch_g);", "wire [9:0] b_g = h_g;"),
        ("lc4 == LONG_PRESS - 1", "lc4 == LONG_PRESS + 100"),
        ("lc4 == LONG_PRESS - 1 && a4 && !o4)", "lc4 == LONG_PRESS - 1 && a4)"),
        ("localparam [30:0] KQ = 31'd1342177;", "localparam [30:0] KQ = 31'd1342176;"),
        ("wire [30:0] q_rnd = q_acc + 31'd16384;", "wire [30:0] q_rnd = q_acc;"),
        ("if (q_h[0]) q_acc <= q_acc + q_k;", "if (q_h[1]) q_acc <= q_acc + q_k;"),
        ("2'd1: man_g <= q_rnd[30:15];", "2'd1: man_g <= q_rnd[29:14];"),
        ("else if (q_i <= 4'd10) begin", "else if (q_i <= 4'd9) begin"),
        ("t_r  <= {5'd0, cur_r} + {2'd0, cur_r, 3'd0} + {1'd0, cur_r, 4'd0};", "t_r  <= {5'd0, cur_r} + {2'd0, cur_r, 3'd0} + {2'd0, cur_r, 3'd0};"),
        ("ch_b <= (t_b + 21'd512) >> 10;", "ch_b <= t_b >> 10;"),
        ("2'd1: if (bv >= 10'd100)", "2'd1: if (bv > 10'd100)"),
        ("2'd2: if (bv >= 10'd10)", "2'd2: if (bv > 10'd10)"),
        ("disp_h = (v > 11'd999) ? 10'd999 : v[9:0];", "disp_h = v[9:0];"),
        ("if (hold_c >= REP_DELAY) begin", "if (hold_c >= REP_DELAY / 2) begin"),
        ("wire       adj    = active & (kd[0] ^ kd[1]);", "wire       adj    = active & (kd[0] | kd[1]);"),
        ("wire       adj    = active & (kd[0] ^ kd[1]);", "wire       adj    = (kd[0] ^ kd[1]);"),
        ("ev_big <= (hold_c >= REP_FAST);", "ev_big <= (hold_c >= REP_FAST / 2);"),
        ("if (rep_c >= REP_PER - 1) begin", "if (rep_c >= REP_PER / 2) begin"),
        ("3'd4: bv <= {2'd0, avg_g};", "3'd4: bv <= {2'd0, avg_b};"),
        ("default: digits[11:0] <= {bd2, bd1, bv[3:0]};", "default: digits[11:0] <= {bd1, bd2, bv[3:0]};"),
        ("if (sel_ev) sel <= (sel == 2'd2) ? 2'd0 : sel + 2'd1;", "if (sel_ev) sel <= sel + 2'd1;"),
        ("((b_s < H_MIN + st) ? H_MIN : (b_s - st))", "((b_s < H_MIN) ? H_MIN : (b_s - st))"),
    ],
    'osd': [
        ("wire [5:0] hl_k  = 6'd8 + {2'd0, f_sel, 2'b0} + {3'd0, f_sel, 1'b0};", "wire [5:0] hl_k  = 6'd8 + {2'd0, f_sel, 2'b0};"),
        ("(ck < hl_k + 6'd5)", "(ck < hl_k + 6'd4)"),
        ("in_de && (x >= WX0) && (x < WX0 + WS)", "in_de && (x >= WX0) && (x <= WX0 + WS)"),
        ("avg_r <= sr[21:14];", "avg_r <= sr[20:13];"),
        ("if (wn == WS * WS) begin", "if (1'b1) begin"),
        ("else if (frame_edge) f_en <= enable;", "else f_en <= enable;"),
        ("always @(posedge clk) if (frame_edge) begin f_mode <= wb_mode;", "always @(posedge clk) if (1'b1) begin f_mode <= wb_mode;"),
        ("6'd16: wb_char = 6'd41;", "6'd16: wb_char = 6'd36;"),
        ("6'd4: wb_char = (md == 2'd0) ? 6'd30 : (md == 2'd1) ? 6'd15 : 6'd10;", "6'd4: wb_char = (md == 2'd0) ? 6'd30 : (md == 2'd1) ? 6'd14 : 6'd10;"),
        ("6'd41: glyph = {5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b01100, 5'b01100};", "6'd41: glyph = {5'b00000, 5'b00000, 5'b00000, 5'b00000, 5'b01100, 5'b01100, 5'b00000};"),
        ("(y >= SY1 && y < SY1 + 16) ? (y[3:0] - SY1[3:0])", "(y >= SY1 && y < SY1 + 16) ? (y[3:0] - SY0[3:0])"),
        ("wire       o_box = (x + 12'd2 >= WX0)", "wire       o_box = (x + 12'd1 >= WX0)"),
        ("out_data <= s2_on ? 24'hFFFFFF : {1'b0, s2_d[23:17], 1'b0, s2_d[15:9], 1'b0, s2_d[7:1]};", "out_data <= s2_on ? 24'hFFFFFF : s2_d;"),
        ("if (cc == 4'd11) begin", "if (cc == 4'd10) begin"),
        ("wire [5:0] nch   = l0 ? 6'd25 : l1 ? 6'd18 : 6'd33;", "wire [5:0] nch   = l0 ? 6'd25 : l1 ? 6'd19 : 6'd33;"),
        ("6'd12: wb_char = dg(d[63:60]);", "6'd12: wb_char = dg(d[67:64]);"),
        ("6'd17: wb_char = dg(d[3:0]);", "6'd17: wb_char = dg(d[7:4]);"),
        ("6'd31: wb_char = 6'd33;", "6'd31: wb_char = 6'd14;"),
        ("if (s2_txt && s2_hl)  out_data <= s2_on ? 24'h000000 : 24'hFFD020;", "if (s2_txt && s2_hl)  out_data <= s2_on ? 24'hFFFFFF : 24'hFFD020;"),
        ("wire       t_hl  = l0 && (ck >= hl_k)", "wire       t_hl  = (ck >= hl_k)"),
        ("else if (s2_box)      out_data <= 24'hFFD020;", "else if (s2_box)      out_data <= s2_d;"),
        ("sg <= sg + {14'd0, in_data[15:8]};", "sg <= sg + {14'd0, in_data[23:16]};"),
        ("wire [4:0] g_bits = (s1_row >= 4'd1 && s1_row <= 4'd14)", "wire [4:0] g_bits = (s1_row >= 4'd0 && s1_row <= 4'd14)"),
    ],
}


def run_one(suite, tag, rtl_text):
    mod, tb, deps, name = SUITES[suite]
    d = os.path.join(WORK, '%s_%s' % (suite, tag))
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(d)
    src = os.path.join(d, mod)
    open(src, 'w', encoding='utf-8').write(rtl_text)
    vvp = os.path.join(d, 'sim.vvp')
    cmd = [os.path.join(IV, 'iverilog.exe'), '-g2005'] + EXTRA_CARGS.get(suite, []) + ['-o', vvp, os.path.join(TB, tb), src] + [os.path.join(RTL, x) for x in deps] + EXTRA_SRC.get(suite, [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        return 'COMPILE_ERROR', (r.stdout + r.stderr)[-400:]
    try:
        r = subprocess.run([os.path.join(IV, 'vvp.exe'), vvp] + EXTRA_ARGS.get(suite, []), capture_output=True, text=True, cwd=d, timeout=2400)
    except subprocess.TimeoutExpired:
        return 'TIMEOUT', ''
    out = r.stdout
    if ('TB_RESULT: PASS ' + name) in out:
        return 'PASS', ''
    if 'TB_RESULT: FAIL' in out:
        return 'FAIL', ''
    return 'NO_RESULT', out[-400:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', choices=sorted(SUITES))
    ap.add_argument('-j', type=int, default=6)
    a = ap.parse_args()
    suites = [a.only] if a.only else ['awb', 'ctrl', 'osd', 'isp']
    # every mutant text must occur exactly once
    for s in suites:
        text = open(os.path.join(RTL, SUITES[s][0]), encoding='utf-8').read()
        for old, new in MUTANTS[s]:
            n = text.count(old)
            if n != 1:
                print('BAD MUTANT TEXT (%d occurrences) in %s: %s' % (n, SUITES[s][0], old))
                return 2
    jobs = []
    for s in suites:
        text = open(os.path.join(RTL, SUITES[s][0]), encoding='utf-8').read()
        jobs.append((s, 'control', text))
        for i, (old, new) in enumerate(MUTANTS[s]):
            jobs.append((s, 'm%02d' % i, text.replace(old, new)))
    res = {}
    with cf.ThreadPoolExecutor(max_workers=a.j) as ex:
        futs = {ex.submit(run_one, s, t, txt): (s, t) for s, t, txt in jobs}
        for f in cf.as_completed(futs):
            res[futs[f]] = f.result()
    ok = True
    for s in suites:
        ctl = res[(s, 'control')][0]
        killed = 0
        surv = []
        for i, (old, new) in enumerate(MUTANTS[s]):
            st, info = res[(s, 'm%02d' % i)]
            if st in ('FAIL', 'COMPILE_ERROR', 'NO_RESULT', 'TIMEOUT'):
                killed += 1
                if st != 'FAIL':
                    print('  %s m%02d killed by %s %s' % (s, i, st, info.strip()[:120]))
            else:
                surv.append((i, old, new))
        print('%-5s control (unmodified RTL): %s | mutants=%d killed=%d survived=%d' % (s, ctl, len(MUTANTS[s]), killed, len(surv)))
        for i, old, new in surv:
            print('   SURVIVED m%02d: %r -> %r' % (i, old, new))
        ok = ok and ctl == 'PASS' and not surv
    print('WB_MUTANTS: ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
