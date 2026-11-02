#!/usr/bin/env python3
"""conv_mutants.py - mutation test of rtl_custom/yolo_conv_core.v against the bit-exact test set (run_conv_tests.py)

Every mutant is the unchanged core with ONE deliberately injected bug (a typical address, sign, rounding, saturation, pipeline or control error).
A mutant is KILLED when at least one of the 40 cases (8 and 16 lanes) fails; it SURVIVED when everything still passes (a gap of the test set, or
an equivalent mutant that has to be argued). The control run (unmodified core) must pass.
Usage: python conv_mutants.py [jobs]      -> logs_custom/yolo_vec/mutation_summary.txt
"""
import concurrent.futures as cf
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
RTL = os.path.join(ROOT, 'rtl_custom', 'yolo_conv_core.v')
WORK = os.path.join(ROOT, 'logs_custom', 'yolo_mut')

MUT = [
    ("cy_acc_no_first", "acc[j] <= f2 ? {{16{p[j][15]}}, p[j]} : (acc[j] + {{16{p[j][15]}}, p[j]});", "acc[j] <= acc[j] + {{16{p[j][15]}}, p[j]};"),
    ("cy_res_no_first", "if (l2) res[j] <= f2 ? {{16{p[j][15]}}, p[j]} : (acc[j] + {{16{p[j][15]}}, p[j]});", "if (l2) res[j] <= acc[j] + {{16{p[j][15]}}, p[j]};"),
    ("cy_prod_unsigned", "p[j] <= a_q * $signed(w_q[8*j +: 8]);", "p[j] <= a_q * $unsigned(w_q[8*j +: 8]);"),
    ("cy_bias_dropped", "s2_v32 <= s1_r + bias_w;", "s2_v32 <= s1_r;"),
    ("cy_round_dropped", "s4_p <= s3_p + rnd48;", "s4_p <= s3_p;"),
    ("cy_round_wrong", "(48'sd1 <<< (s3_s - 6'd1))", "(48'sd1 <<< s3_s)"),
    ("cy_shift_logical", "wire signed [47:0] sh48 = s4_p >>> s4_s;", "wire signed [47:0] sh48 = s4_p >> s4_s;"),
    ("cy_clamp_hi", "(s5_p > 48'sd127) ? 8'sd127", "(s5_p > 48'sd128) ? 8'sd127"),
    ("cy_clamp_lo", "(s5_p < -48'sd128) ? -8'sd128", "(s5_p < -48'sd129) ? -8'sd128"),
    ("cy_leaky_slope", "* 16'sd13 + 16'sd64;", "* 16'sd12 + 16'sd64;"),
    ("cy_leaky_round", "* 16'sd13 + 16'sd64;", "* 16'sd13 + 16'sd0;"),
    ("cy_leaky_off", "s7_z <= cfg_act ? leaky_v : s6_z;", "s7_z <= s6_z;"),
    ("cy_leaky_always", "s7_z <= cfg_act ? leaky_v : s6_z;", "s7_z <= leaky_v;"),
    ("cy_mult_signed", "s3_p <= s2_v32 * $signed({1'b0, s2_m});", "s3_p <= s2_v32 * $signed(s2_m);"),
    ("cy_wr_ok_le", "wire        wr_ok_now = (oc_now < {1'b0, cfg_cout});", "wire        wr_ok_now = (oc_now <= {1'b0, cfg_cout});"),
    ("cy_pm_addr_off", "assign pm_addr = oc_now[PW-1:0];", "assign pm_addr = oc_now[PW-1:0] + 1'b1;"),
    ("cy_res_lane0", "wire signed [31:0] r_sel = res[ridx];", "wire signed [31:0] r_sel = res[5'd0];"),
    ("cy_out_addr_lane", "s1_a <= f_opix + {{(AW-PW-1){1'b0}}, oc_now};", "s1_a <= f_opix + {{(AW-PW-1){1'b0}}, f_ocb};"),
    ("cy_gap_short", "localparam integer PERIOD_MIN = LANES + 1;", "localparam integer PERIOD_MIN = LANES;"),
    ("cy_gap_none", "if (short_vec) gap <= gap_len[7:0];", "if (1'b0) gap <= gap_len[7:0];"),
    ("cy_wt_index_stuck", "wt_i <= wt_i + 1'b1;", "wt_i <= wt_i;"),
    ("cy_wt_base_step", "wt_base <= wt_base + taps;", "wt_base <= wt_base + taps + 1'b1;"),
    ("cy_kx_step", "kx <= kx + 2'd1; a_kx <= a_kx + cfg_in_pix; a_cur <= a_kx + cfg_in_pix;", "kx <= kx + 2'd1; a_kx <= a_kx + cfg_in_pix; a_cur <= a_kx + cfg_in_pix + 1'b1;"),
    ("cy_ky_step", "a_ky <= a_ky + cfg_in_row; a_kx <= a_ky + cfg_in_row; a_cur <= a_ky + cfg_in_row;", "a_ky <= a_ky + cfg_in_row; a_kx <= a_ky + cfg_in_row; a_cur <= a_ky + cfg_in_row + 1'b1;"),
    ("cy_row_wrap", "a_row <= a_row + cfg_in_row; a_pix <= a_row + cfg_in_row; a_cur <= a_row + cfg_in_row;", "a_row <= a_row + cfg_in_row; a_pix <= a_row + cfg_in_row + cfg_in_pix; a_cur <= a_row + cfg_in_row;"),
    ("cy_out_row_step", "else begin o_row <= o_row + cfg_out_row; o_pix <= o_row + cfg_out_row; end", "else begin o_row <= o_row + cfg_out_row; o_pix <= o_row + cfg_out_row + 1'b1; end"),
    ("cy_ntiles_floor", "wire [10:0] ntiles_m1 = (cfg_cout + LANES - 1) / LANES - 11'd1;", "wire [10:0] ntiles_m1 = cfg_cout / LANES - 11'd1;"),
    ("cy_taps_k3", "({3'd0, cfg_cin} + {3'd0, cfg_cin, 3'd0})", "({3'd0, cfg_cin} + {3'd0, cfg_cin, 2'd0})"),
    ("cy_oc_base_step", "oc_base <= oc_base + LANES;", "oc_base <= oc_base + LANES - 1;"),
    ("cy_tile_wrap_stale_pix", "a_row <= cfg_in_base; a_pix <= cfg_in_base; a_cur <= cfg_in_base; a_kx <= cfg_in_base; a_ky <= cfg_in_base;", "a_row <= cfg_in_base; a_cur <= cfg_in_base; a_kx <= cfg_in_base; a_ky <= cfg_in_base;"),
    ("cy_done_early", "if (!pipe_busy) begin\n                        state <= S_IDLE;", "if (1'b1) begin\n                        state <= S_IDLE;"),
    ("cy_kernel_2x2", "wire [1:0]  kmax = cfg_k3 ? 2'd2 : 2'd0;", "wire [1:0]  kmax = cfg_k3 ? 2'd1 : 2'd0;"),
    ("cy_pool_first_flag", "iss_pf    <= !cfg_pool || (!px[0] && !py[0]);", "iss_pf    <= !cfg_pool;"),
    ("cy_pool_min", "(out_rd_data_s > s8_z)", "(out_rd_data_s < s8_z)"),
    ("cy_pool_unsigned", "(out_rd_data_s > s8_z)", "(out_rd_data > s8_z)"),
    ("cy_pool_x_advance", "if (!(cfg_pool && !px[0])) o_pix <= o_pix + cfg_out_pix;", "o_pix <= o_pix + cfg_out_pix;"),
    ("cy_pool_row_restart", "if (cfg_pool && !py[0]) o_pix <= o_row;", "if (1'b0) o_pix <= o_row;"),
    ("cy_pool_flag_lost", "pf1 <= iss_pf;", "pf1 <= 1'b1;"),
    ("cy_pool_rd_addr", "assign out_rd_addr = s7_a;", "assign out_rd_addr = s6_a;"),
    ("cy_pool_merge_off", "((POOL != 0) && !s8_pf", "((1'b0) && !s8_pf"),
    ("cy_write_gate_dropped", "out_we   <= s8_v && s8_wr;", "out_we   <= s8_v;"),
    ("cy_first_tap_flag", "iss_first <= first_tap;", "iss_first <= 1'b0;"),
    ("cy_last_tap_flag", "iss_last  <= tap_last;", "iss_last  <= 1'b0;"),
]


def run_one(item):
    name, old, new = item
    d = os.path.join(WORK, name)
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    t = open(RTL, encoding='utf-8').read()
    if name != 'control':
        assert t.count(old) == 1, (name, 'old text occurs %d times' % t.count(old))
        t = t.replace(old, new)
    rtl = os.path.join(d, 'yolo_conv_core.v')
    open(rtl, 'w', encoding='utf-8', newline='').write(t)
    r = subprocess.run([sys.executable, os.path.join(HERE, 'run_conv_tests.py'), '--rtl', rtl, '--work', os.path.join(d, 'w'), '--quiet', '--stop-first'],
                       capture_output=True, text=True)
    return name, r.returncode, (r.stdout + r.stderr)[-400:]


def main():
    jobs = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    items = [('control', None, None)] + MUT
    t0 = time.time()
    res = {}
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        for name, rc, tail in ex.map(run_one, items):
            res[name] = (rc, tail)
    killed = survived = 0
    lines = ['conv_mutants %s  wall %.0f s' % (time.strftime('%Y-%m-%d %H:%M:%S'), time.time() - t0), '']
    lines.append('control (unmodified core): %s' % ('PASS' if res['control'][0] == 0 else 'FAIL  ' + res['control'][1]))
    for name, old, new in MUT:
        rc = res[name][0]
        if res['control'][0] != 0:
            lines.append('%-26s INVALID (the control run failed)' % name)
            survived += 1
        elif rc == 0:
            survived += 1
            lines.append('%-26s SURVIVED' % name)
        else:
            killed += 1
            lines.append('%-26s KILLED' % name)
    lines += ['', 'mutants=%d killed=%d survived=%d' % (len(MUT), killed, survived)]
    out = '\n'.join(lines)
    os.makedirs(os.path.join(ROOT, 'logs_custom', 'yolo_vec'), exist_ok=True)
    open(os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'mutation_summary.txt'), 'w', encoding='utf-8').write(out)
    print(out)
    return 0 if survived == 0 and res['control'][0] == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
