#!/usr/bin/env python3
"""aux_mutants.py - mutation test of rtl_custom/yolo_aux_core.v against the bit-exact test set (run_aux_tests.py)

Every mutant is the unchanged core with ONE deliberately injected bug (tap geometry, edge replication, up-sampling phase, stride, running maximum, pipeline
alignment, last-element detection, done timing). A mutant is KILLED when at least one case fails, it SURVIVED when everything still passes (a gap of the test set
or an equivalent mutant that has to be argued). The control run (unmodified core) must pass.
Usage: python aux_mutants.py [jobs]      -> logs_custom/yolo_vec/aux_mutation_summary.txt
"""
import concurrent.futures as cf
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
RTL = os.path.join(ROOT, 'rtl_custom', 'yolo_aux_core.v')
WORK = os.path.join(ROOT, 'logs_custom', 'yolo_mut_aux')

MUT = [
    ("ax_taps_three", "wire t_end   = (t == (is_pool ? 2'd3 : 2'd0));", "wire t_end   = (t == (is_pool ? 2'd2 : 2'd0));"),
    ("ax_taps_one_for_copy_only_pool", "wire t_end   = (t == (is_pool ? 2'd3 : 2'd0));", "wire t_end   = (t == (is_pool ? 2'd3 : 2'd1));"),
    ("ax_off_y_uses_dx", "(t[1] && y_ok) ? cfg_in_row", "(t[0] && y_ok) ? cfg_in_row"),
    ("ax_off_x_uses_dy", "(t[0] && x_ok) ? cfg_in_pix", "(t[1] && x_ok) ? cfg_in_pix"),
    ("ax_off_y_every_tap", "(t[1] && y_ok) ? cfg_in_row", "(y_ok) ? cfg_in_row"),
    ("ax_off_x_every_tap", "(t[0] && x_ok) ? cfg_in_pix", "(x_ok) ? cfg_in_pix"),
    ("ax_y_ok_always", "wire y_ok    = is_s2 || !y_last;", "wire y_ok    = 1'b1;"),
    ("ax_x_ok_always", "wire x_ok    = is_s2 || !x_last;", "wire x_ok    = 1'b1;"),
    ("ax_y_ok_never", "wire y_ok    = is_s2 || !y_last;", "wire y_ok    = is_s2;"),
    ("ax_x_ok_never", "wire x_ok    = is_s2 || !x_last;", "wire x_ok    = is_s2;"),
    ("ax_s2_pix_step", "is_s2 ? {cfg_in_pix[AW-2:0], 1'b0}", "is_s2 ? cfg_in_pix"),
    ("ax_s2_row_step", "is_s2 ? {cfg_in_row[AW-2:0], 1'b0}", "is_s2 ? cfg_in_row"),
    ("ax_up_x_phase", "(x[0] ? cfg_in_pix : {AW{1'b0}})", "(!x[0] ? cfg_in_pix : {AW{1'b0}})"),
    ("ax_up_y_phase", "(y[0] ? cfg_in_row : {AW{1'b0}})", "(!y[0] ? cfg_in_row : {AW{1'b0}})"),
    ("ax_up_x_always", "(is_up ? (x[0] ? cfg_in_pix : {AW{1'b0}}) : cfg_in_pix)", "(is_up ? cfg_in_pix : cfg_in_pix)"),
    ("ax_up_y_always", "(is_up ? (y[0] ? cfg_in_row : {AW{1'b0}}) : cfg_in_row)", "(is_up ? cfg_in_row : cfg_in_row)"),
    ("ax_up_mode_is_s2", "wire is_up   = (cfg_mode == 3'd1);", "wire is_up   = 1'b0;"),
    ("ax_c_last_off", "wire c_last  = (c == cfg_c - 11'd1);", "wire c_last  = (c == cfg_c);"),
    ("ax_x_last_off", "wire x_last  = (x == cfg_w - 12'd1);", "wire x_last  = (x == cfg_w);"),
    ("ax_y_last_off", "wire y_last  = (y == cfg_h - 12'd1);", "wire y_last  = (y == cfg_h);"),
    ("ax_first_flag", "m0_first <= (t == 2'd0);", "m0_first <= 1'b1;"),
    ("ax_first_never", "m0_first <= (t == 2'd0);", "m0_first <= 1'b0;"),
    ("ax_last_flag", "m0_last  <= t_end;", "m0_last  <= 1'b1;"),
    ("ax_max_is_min", "((q > mx) ? q : mx)", "((q < mx) ? q : mx)"),
    ("ax_max_unsigned", "wire signed [7:0] q   = rd_data;", "wire [7:0] q   = rd_data;"),
    ("ax_out_data_mx", "out_data <= is_fill ? 8'd0 : mxn;", "out_data <= is_fill ? 8'd0 : mx;"),
    ("ax_out_addr_pix", "m0_oa    <= o_c;", "m0_oa    <= o_pix;"),
    ("ax_oa_stage", "m1_first <= m0_first; m1_last <= m0_last; m1_oa <= m0_oa;", "m1_first <= m0_first; m1_last <= m0_last; m1_oa <= o_c;"),
    ("ax_m1_last_from_first", "m1_last <= m0_last;", "m1_last <= m0_first;"),
    ("ax_o_c_stuck", "o_c <= o_c + {{(AW-1){1'b0}}, 1'b1};", "o_c <= o_c;"),
    ("ax_a_c_stuck", "a_c <= a_c + {{(AW-1){1'b0}}, 1'b1};", "a_c <= a_c;"),
    ("ax_o_pix_step", "o_pix <= o_pix + cfg_out_pix; o_c <= o_pix + cfg_out_pix;", "o_pix <= o_pix + cfg_out_pix; o_c <= o_pix + cfg_out_pix + 1'b1;"),
    ("ax_o_row_step", "o_row <= o_row + cfg_out_row; o_pix <= o_row + cfg_out_row; o_c <= o_row + cfg_out_row;", "o_row <= o_row + cfg_out_row; o_pix <= o_row + cfg_out_row; o_c <= o_row;"),
    ("ax_i_row_pix", "i_row <= i_row + step_row; i_pix <= i_row + step_row; a_c <= i_row + step_row;", "i_row <= i_row + step_row; i_pix <= i_row + step_row; a_c <= i_row;"),
    ("ax_i_pix_step", "i_pix <= i_pix + step_pix; a_c <= i_pix + step_pix;", "i_pix <= i_pix + step_pix; a_c <= i_pix;"),
    ("ax_rd_addr_no_off_x", "rd_addr  <= a_c + off_y + off_x;", "rd_addr  <= a_c + off_y;"),
    ("ax_rd_addr_no_off_y", "rd_addr  <= a_c + off_y + off_x;", "rd_addr  <= a_c + off_x;"),
    ("ax_idle_load_in", "i_row <= cfg_in_base; i_pix <= cfg_in_base; a_c <= cfg_in_base;", "i_row <= cfg_in_base; i_pix <= cfg_in_base; a_c <= 20'd0;"),
    ("ax_idle_load_out", "o_row <= cfg_out_base; o_pix <= cfg_out_base; o_c <= cfg_out_base;", "o_row <= cfg_out_base; o_pix <= cfg_out_base; o_c <= cfg_out_base + 1'b1;"),
    ("ax_all_issued_row", "if (issue && t_end && c_last && x_last && y_last) all_issued <= 1'b1;", "if (issue && t_end && c_last && x_last) all_issued <= 1'b1;"),
    ("ax_all_issued_tap", "if (issue && t_end && c_last && x_last && y_last) all_issued <= 1'b1;", "if (issue && c_last && x_last && y_last) all_issued <= 1'b1;"),
    ("ax_done_early", "if (!pipe_busy) begin state <= S_IDLE; done <= 1'b1; end", "if (1'b1) begin state <= S_IDLE; done <= 1'b1; end"),
    ("ax_done_no_m1", "wire pipe_busy = m1_v | out_we;", "wire pipe_busy = out_we;"),
    ("ax_we_without_last", "out_we <= m1_v && m1_last;", "out_we <= m1_v;"),
    ("ax_we_without_valid", "out_we <= m1_v && m1_last;", "out_we <= m1_last;"),
    ("ax_m0_v_ungated", "m0_v  <= issue;", "m0_v  <= (state == S_RUN);"),
    ("ax_fill_off", "out_data <= is_fill ? 8'd0 : mxn;", "out_data <= mxn;"),
    ("ax_fill_mode_code", "wire is_fill = (cfg_mode == 3'd4);", "wire is_fill = (cfg_mode == 3'd5);"),
    ("ax_pool_mode_decode", "(cfg_mode == 3'd2) || (cfg_mode == 3'd3)", "(cfg_mode == 3'd2) || (cfg_mode >= 3'd3)"),
    ("ax_start_ignored_in_run", "if (start) state <= S_RUN;", "if (1'b1) state <= S_RUN;"),
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
    rtl = os.path.join(d, 'yolo_aux_core.v')
    open(rtl, 'w', encoding='utf-8', newline='').write(t)
    r = subprocess.run([sys.executable, os.path.join(HERE, 'run_aux_tests.py'), '--rtl', rtl, '--work', os.path.join(d, 'w'), '--quiet', '--stop-first'],
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
    lines = ['aux_mutants %s  wall %.0f s' % (time.strftime('%Y-%m-%d %H:%M:%S'), time.time() - t0), '']
    lines.append('control (unmodified core): %s' % ('PASS' if res['control'][0] == 0 else 'FAIL  ' + res['control'][1]))
    for name, old, new in MUT:
        rc = res[name][0]
        if res['control'][0] != 0:
            lines.append('%-26s INVALID (the control run failed)' % name)
            survived += 1
        elif rc == 0:
            survived += 1
            lines.append('%-26s SURVIVED' % name)
        elif rc == 2:
            survived += 1
            lines.append('%-26s INVALID (compile error: %s)' % (name, res[name][1].strip().replace('\n', ' ')[-150:]))
        else:
            killed += 1
            lines.append('%-26s KILLED' % name)
    lines += ['', 'mutants=%d killed=%d survived=%d' % (len(MUT), killed, survived)]
    out = '\n'.join(lines)
    os.makedirs(os.path.join(ROOT, 'logs_custom', 'yolo_vec'), exist_ok=True)
    open(os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'aux_mutation_summary.txt'), 'w', encoding='utf-8').write(out)
    print(out)
    return 0 if survived == 0 and res['control'][0] == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
