#!/usr/bin/env python3
"""box_mutants.py - mutation test of rtl_custom/yolo_box_down.v against the bit-exact test set (run_box_tests.py)

Every mutant is the unchanged RTL with ONE deliberately injected bug (frame start / arming, box position bookkeeping, accumulator read timing, column sums, rounding, byte
addresses, emitter order, frame_done timing). KILLED = at least one case fails, SURVIVED = everything still passes. The control run (unmodified RTL) must pass.
Equivalent mutant (not in the list): `take = first_pix || (pix_valid && active)` - a frame start behind a truncated capture would be counted as one data pixel
before the abort takes effect; the capture is abandoned anyway, no byte is written.
Usage: python box_mutants.py [jobs [name ...]]      -> logs_custom/yolo_vec/box_mutation_summary.txt
"""
import concurrent.futures as cf
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
RTL = os.path.join(ROOT, 'rtl_custom', 'yolo_box_down.v')
WORK = os.path.join(ROOT, 'logs_custom', 'yolo_mut_box')

MUT = [
    ("bd_take_ungated", "wire          take = first_pix || (pix_valid && active && !pix_sof);", "wire          take = pix_valid;"),
    ("bd_start_no_sof", "wire          first_pix = new_frame && armed;", "wire          first_pix = pix_valid && armed;"),
    ("bd_start_no_arm", "wire          first_pix = new_frame && armed;", "wire          first_pix = new_frame;"),
    ("bd_no_abort", "else if (new_frame && active) begin active <= 1'b0; pend_done <= 1'b0; end", "else if (new_frame && active) begin pend_done <= 1'b0; end"),
    ("bd_arm_kept", "if (first_pix) begin armed <= 1'b0; active <= 1'b1; pend_done <= 1'b0; end", "if (first_pix) begin active <= 1'b1; pend_done <= 1'b0; end"),
    ("bd_acc_read_late", "if (take && bx == BOX - 3) acc_ra <= ox;", "if (take && bx == BOX - 2) acc_ra <= ox;"),
    ("bd_acc_read_wrong_col", "if (take && bx == BOX - 3) acc_ra <= ox;", "if (take && bx == BOX - 3) acc_ra <= ox + 11'd1;"),
    ("bd_acc_write_col", "acc_we <= 1'b1; acc_wa <= ox; acc_wd <= {sb, sg, sr};", "acc_we <= 1'b1; acc_wa <= ox + 11'd1; acc_wd <= {sb, sg, sr};"),
    ("bd_acc_write_order", "acc_wd <= {sb, sg, sr};", "acc_wd <= {sb, sr, sg};"),
    ("bd_base_r", "wire [15:0] sr = (by == 4'd0 ? 16'd0 : acc_q[15:0])", "wire [15:0] sr = (acc_q[15:0])"),
    ("bd_base_g", "wire [15:0] sg = (by == 4'd0 ? 16'd0 : acc_q[31:16])", "wire [15:0] sg = (acc_q[31:16])"),
    ("bd_base_b_lane", "wire [15:0] sb = (by == 4'd0 ? 16'd0 : acc_q[47:32])", "wire [15:0] sb = (by == 4'd0 ? 16'd0 : acc_q[31:16])"),
    ("bd_hsum_not_reset", "if (last_in_box) begin hr <= 12'd0; hg <= 12'd0; hb <= 12'd0; end", "if (last_in_box) begin hr <= hr; hg <= 12'd0; hb <= 12'd0; end"),
    ("bd_hsum_first_pixel", "hr <= {4'd0, pr}; hg <= {4'd0, pg}; hb <= {4'd0, pb};\n        end", "hr <= 12'd0; hg <= {4'd0, pg}; hb <= {4'd0, pb};\n        end"),
    ("bd_hsum_blue", "wire [11:0] hb_n = hb + {4'd0, pb};", "wire [11:0] hb_n = hb + {4'd0, pg};"),
    ("bd_round_dropped", "e_prod <= rmul(em == 2'd1 ? e_r : (em == 2'd2 ? e_g : e_b)) + RA;", "e_prod <= rmul(em == 2'd1 ? e_r : (em == 2'd2 ? e_g : e_b));"),
    ("bd_rmul_bit", "for (b = 0; b < 16; b = b + 1) if ((RM >> b) & 1) rmul", "for (b = 1; b < 16; b = b + 1) if ((RM >> b) & 1) rmul"),
    ("bd_channel_order", "rmul(em == 2'd1 ? e_r : (em == 2'd2 ? e_g : e_b))", "rmul(em == 2'd1 ? e_r : (em == 2'd2 ? e_b : e_g))"),
    ("bd_sign_flip", "wdata <= {~e_prod[RS+7], e_prod[RS+6:RS]};", "wdata <= {e_prod[RS+7], e_prod[RS+6:RS]};"),
    ("bd_byte_addr", "waddr <= e_base + {18'd0, em_d} - 20'd1;", "waddr <= e_base + {18'd0, em_d};"),
    ("bd_base_row", "localparam [19:0] ROW0  = (PAD_TOP + 1) * (NET_W + 2) * 3;", "localparam [19:0] ROW0  = (PAD_TOP) * (NET_W + 2) * 3;"),
    ("bd_base_col", "e_base <= row_base + {8'd0, ox, 1'b0} + {9'd0, ox} + 20'd3;", "e_base <= row_base + {8'd0, ox, 1'b0} + {9'd0, ox};"),
    ("bd_base_stride", "localparam [19:0] RSTEP = (NET_W + 2) * 3;", "localparam [19:0] RSTEP = (NET_W + 1) * 3;"),
    ("bd_base_col_x3", "e_base <= row_base + {8'd0, ox, 1'b0} + {9'd0, ox} + 20'd3;", "e_base <= row_base + {8'd0, ox, 1'b0} + 20'd3;"),
    ("bd_row_base_step", "begin by <= 4'd0; row_base <= row_base + RSTEP; end", "begin by <= 4'd0; end"),
    ("bd_emit_trigger", "if (take && last_in_box && last_row_in_box && em == 2'd0) begin", "if (take && last_in_box && em == 2'd0) begin"),
    ("bd_row_wrap_bx", "ox <= 11'd0; bx <= 4'd0;\n                if (by == BOX - 1)", "ox <= 11'd0;\n                if (by == BOX - 1)"),
    ("bd_by_step", "else by <= by + 4'd1;", "else by <= by;"),
    ("bd_ox_step", "if (last_in_box) begin bx <= 4'd0; ox <= ox + 11'd1; end", "if (last_in_box) begin bx <= 4'd0; ox <= ox; end"),
    ("bd_first_bx", "in_x <= 11'd1; in_y <= 11'd0; bx <= 4'd1; by <= 4'd0;", "in_x <= 11'd1; in_y <= 11'd0; bx <= 4'd0; by <= 4'd0;"),
    ("bd_last_pix_row", "wire          last_pix = (in_x == IN_W - 1) && (in_y == IN_H - 1);", "wire          last_pix = (in_x == IN_W - 1) && (in_y == IN_H - 2);"),
    ("bd_done_early", "if (pend_done && em == 2'd0 && em_d == 2'd0) begin", "if (pend_done && em == 2'd0) begin"),
    ("bd_done_active", "pend_done <= 1'b0; active <= 1'b0; frame_done <= 1'b1; end", "pend_done <= 1'b0; frame_done <= 1'b1; end"),
    ("bd_done_never_pend", "if (take && !first_pix && last_pix) pend_done <= 1'b1;", "if (take && !first_pix && last_pix && 1'b0) pend_done <= 1'b1;"),
    ("bd_we_extra", "if (em_d != 2'd0) we <= 1'b1;", "if (em != 2'd0) we <= 1'b1;"),
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
    rtl = os.path.join(d, 'yolo_box_down.v')
    open(rtl, 'w', encoding='utf-8', newline='').write(t)
    r = subprocess.run([sys.executable, os.path.join(HERE, 'run_box_tests.py'), '--rtl', rtl, '--work', os.path.join(d, 'w'), '--quiet', '--stop-first'], capture_output=True, text=True)
    return name, r.returncode, (r.stdout + r.stderr)[-400:]


def main():
    jobs = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    only = set(sys.argv[2:])
    src = open(RTL, encoding='utf-8').read()
    bad = [m[0] for m in MUT if src.count(m[1]) != 1]
    if bad:
        print('mutants whose old text does not occur exactly once:', bad)
        return 2
    muts = [m for m in MUT if not only or m[0] in only]
    items = [('control', None, None)] + muts
    t0 = time.time()
    res = {}
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        for name, rc, tail in ex.map(run_one, items):
            res[name] = (rc, tail)
    killed = survived = 0
    lines = ['box_mutants %s  wall %.0f s' % (time.strftime('%Y-%m-%d %H:%M:%S'), time.time() - t0), '']
    lines.append('control (unmodified RTL): %s' % ('PASS' if res['control'][0] == 0 else 'FAIL  ' + res['control'][1]))
    for name, old, new in muts:
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
    lines += ['', 'mutants=%d killed=%d survived=%d' % (len(muts), killed, survived)]
    out = '\n'.join(lines)
    os.makedirs(os.path.join(ROOT, 'logs_custom', 'yolo_vec'), exist_ok=True)
    open(os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'box_mutation_summary.txt'), 'w', encoding='utf-8').write(out)
    print(out)
    return 0 if survived == 0 and res['control'][0] == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
