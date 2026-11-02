#!/usr/bin/env python3
"""decode_mutants.py - mutation test of rtl_custom/yolo_decode.v against the bit-exact test set (run_decode_tests.py)

Every mutant is the unchanged RTL with ONE deliberately injected bug (table index, tie rule, threshold, box geometry, stride / head selection, clipping, candidate memory,
NMS selection and suppression, IoU arithmetic, scan counters). A mutant is KILLED when at least one case fails, it SURVIVED when everything still passes (a gap of the
test set or an equivalent mutant that has to be argued). The control run (unmodified RTL) must pass.
Usage: python decode_mutants.py [jobs [name ...]]      -> logs_custom/yolo_vec/decode_mutation_summary.txt
"""
import concurrent.futures as cf
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
RTLDIR = os.path.join(ROOT, 'rtl_custom')
WORK = os.path.join(ROOT, 'logs_custom', 'yolo_mut_dec')
FILES = ['yolo_decode.v', 'yolo_lut_rom.v']
D = 'yolo_decode.v'

MUT = [
    ("dc_obj_index", D, "6'd0:  sig_a <= {~vb[4][7], vb[4][6:0]};", "6'd0:  sig_a <= vb[4];"),
    ("dc_cls0_index", D, "6'd1:  sig_a <= {~vb[5][7], vb[5][6:0]};", "6'd1:  sig_a <= {~vb[6][7], vb[6][6:0]};"),
    ("dc_cls_tie_ge4", D, "6'd4:  if (sig_d > best_s) begin", "6'd4:  if (sig_d >= best_s) begin"),
    ("dc_cls_tie_ge5", D, "6'd5:  if (sig_d > best_s) begin", "6'd5:  if (sig_d >= best_s) begin"),
    ("dc_cls_code1", D, "best_s <= sig_d; cls_r <= 2'd1; end", "best_s <= sig_d; cls_r <= 2'd2; end"),
    ("dc_cls_code0", D, "best_s <= sig_d; cls_r <= 2'd0; end", "best_s <= sig_d; cls_r <= 2'd1; end"),
    ("dc_score_bits", D, "score_r <= mul_p[31:16];", "score_r <= mul_p[30:15];"),
    ("dc_thr_le", D, "score_r < THR) st <= D_NEXT", "score_r <= THR) st <= D_NEXT"),
    ("dc_thr_param", D, "parameter integer THR = 26214,", "parameter integer THR = 26215,"),
    ("dc_tx_sx", D, "exp_a <= {~vb[2][7], vb[2][6:0]}; sx_r <= sig_d; end", "exp_a <= {~vb[2][7], vb[2][6:0]}; sy_r <= sig_d; end"),
    ("dc_ew_target", D, "6'd13: ew_r <= exp_d;", "6'd13: eh_r <= exp_d;"),
    ("dc_anchor_w", D, "mul_a <= {10'd0, aw}; mul_b <= {2'b00, ew_r};", "mul_a <= {10'd0, ah}; mul_b <= {2'b00, ew_r};"),
    ("dc_anchor_h", D, "6'd15: begin mul_a <= {10'd0, ah};", "6'd15: begin mul_a <= {10'd0, aw};"),
    ("dc_bw_shift", D, "6'd16: bwq <= mul_p[31:0] >>> 4;", "6'd16: bwq <= mul_p[31:0] >>> 3;"),
    ("dc_bh_shift", D, "6'd17: bhq <= mul_p[31:0] >>> 4;", "6'd17: bhq <= mul_p[31:0] >>> 5;"),
    ("dc_cx_stride", D, "+ {16'd0, sx_r}) << (hi ? SH2 : SH1)) >> 12)", "+ {16'd0, sx_r}) << (hi ? SH1 : SH2)) >> 12)"),
    ("dc_cy_stride", D, "+ {16'd0, sy_r}) << (hi ? SH2 : SH1)) >> 12) - PAD_TOP * 16", "+ {16'd0, sy_r}) << (hi ? SH1 : SH2)) >> 12) - PAD_TOP * 16"),
    ("dc_cx_shift", D, "+ {16'd0, sx_r}) << (hi ? SH2 : SH1)) >> 12)", "+ {16'd0, sx_r}) << (hi ? SH2 : SH1)) >> 11)"),
    ("dc_cy_pad", D, ">> 12) - PAD_TOP * 16", ">> 12) - PAD_TOP * 15"),
    ("dc_cx_uses_cy", D, "(({16'd0, cx} << 16) + {16'd0, sx_r})", "(({16'd0, cy} << 16) + {16'd0, sx_r})"),
    ("dc_cy_uses_cx", D, "(({16'd0, cy} << 16) + {16'd0, sy_r})", "(({16'd0, cx} << 16) + {16'd0, sy_r})"),
    ("dc_half_x1", D, "x1q <= cxq + (bwq >>> 1);", "x1q <= cxq + (bwq >>> 2);"),
    ("dc_half_x0", D, "x0q <= cxq - (bwq >>> 1);", "x0q <= cxq - (bwq >>> 2);"),
    ("dc_half_y0", D, "y0q <= cyq - (bhq >>> 1);", "y0q <= cyq - (bhq >>> 2);"),
    ("dc_half_y1", D, "y1q <= cyq + (bhq >>> 1);", "y1q <= cyq + (bhq >>> 2);"),
    ("dc_clip_hi_x", D, "(v > FW - 1) ? (FW - 1) : v[11:0]", "(v > FW) ? (FW - 1) : v[11:0]"),
    ("dc_clip_hi_y", D, "(v > FH - 1) ? (FH - 1) : v[11:0]", "(v > FH) ? (FH - 1) : v[11:0]"),
    ("dc_clip_x_value", D, "(v > FW - 1) ? (FW - 1) : v[11:0]", "(v > FW - 1) ? FW : v[11:0]"),
    ("dc_clip_lo_x", D, "(v < 0) ? 12'sd0 : ((v > FW - 1)", "(v < -8) ? 12'sd0 : ((v > FW - 1)"),
    ("dc_k_scale", D, "for (b = 0; b < 8; b = b + 1) if ((KSC >> b) & 1) kmul", "for (b = 0; b < 3; b = b + 1) if ((KSC >> b) & 1) kmul"),
    ("dc_frame_shift_x0", D, "x0f <= clipx(kmul(x0q) >>> 4);", "x0f <= clipx(kmul(x0q) >>> 3);"),
    ("dc_cand_pack", D, "x0f[10:0], y0f[9:0], x1f[10:0], y1f[9:0]};", "x0f[10:0], y1f[9:0], x1f[10:0], y0f[9:0]};"),
    ("dc_slot_addr", D, "slot_wa <= cnt[4:0]; slot_wd <= cand; cnt <= cnt + 6'd1;", "slot_wa <= cnt[3:0]; slot_wd <= cand; cnt <= cnt + 6'd1;"),
    ("dc_store_full", D, "D_STORE: st <= (cnt < 6'd32) ? D_NEXT : D_MINA;", "D_STORE: st <= (cnt < 6'd31) ? D_NEXT : D_MINA;"),
    ("dc_min_tie_last", D, "if (!have || q_score < msc) begin", "if (!have || q_score <= msc) begin"),
    ("dc_min_scan_end", D, "D_MINC:  st <= (j == 6'd31) ? D_NEXT : D_MINA;", "D_MINC:  st <= (j == 6'd30) ? D_NEXT : D_MINA;"),
    ("dc_replace_ge", D, "if (have && (cand[57:42] > msc))", "if (have && (cand[57:42] >= msc))"),
    ("dc_replace_slot", D, "slot_we <= 1'b1; slot_wa <= mi; slot_wd <= cand; end", "slot_we <= 1'b1; slot_wa <= mi + 5'd1; slot_wd <= cand; end"),
    ("dc_sel_tie_last", D, "(!found || q_score > best_rec[57:42])", "(!found || q_score >= best_rec[57:42])"),
    ("dc_alive_mask", D, "((32'd1 << cnt) - 32'd1)", "(32'd1 << cnt)"),
    ("dc_kout", D, "(n_out == KOUT - 1) ? D_FIN : D_SUPA", "(n_out == KOUT) ? D_FIN : D_SUPA"),
    ("dc_res_wa", D, "res_wa <= n_out[2:0];", "res_wa <= 3'd0;"),
    ("dc_res_n", D, "res_n <= n_out + 4'd1;", "res_n <= n_out;"),
    ("dc_alive_clear", D, "alive[bi] <= 1'b0; sel <= best_rec;", "sel <= best_rec;"),
    ("dc_sel_record", D, "alive[bi] <= 1'b0; sel <= best_rec;", "alive[bi] <= 1'b0; sel <= slot_q;"),
    ("dc_sup_class", D, "(alive[j[4:0]] && (q_cls == s_cls)) ? D_IOU", "(alive[j[4:0]]) ? D_IOU"),
    ("dc_iou_clamp", D, "mul_a <= (ixr < 0) ? 18'sd0 : ixr; mul_b <= (iyr < 0) ? 18'sd0 : iyr;", "mul_a <= ixr; mul_b <= iyr;"),
    ("dc_iou_union", D, "uni <= aa + bb - inter;", "uni <= aa + bb;"),
    ("dc_iou_lhs", D, "lhs <= inter <<< 6;", "lhs <= inter <<< 5;"),
    ("dc_iou_q6_low", D, "parameter integer IOU_Q6 = 29,", "parameter integer IOU_Q6 = 28,"),
    ("dc_iou_q6_high", D, "parameter integer IOU_Q6 = 29,", "parameter integer IOU_Q6 = 30,"),
    ("dc_iou_ge", D, "if (lhs > rhs) alive[j[4:0]] <= 1'b0;", "if (lhs >= rhs) alive[j[4:0]] <= 1'b0;"),
    ("dc_iou_xmin", D, "(s_x1 < q_x1) ? s_x1 : q_x1", "(s_x1 > q_x1) ? s_x1 : q_x1"),
    ("dc_iou_ymax", D, "(s_y0 > q_y0) ? s_y0 : q_y0", "(s_y0 < q_y0) ? s_y0 : q_y0"),
    ("dc_iou_area_b", D, "mul_b <= {8'd0, q_y1} - {8'd0, q_y0}; end", "mul_b <= {8'd0, q_y1} - {8'd0, s_y0}; end"),
    ("dc_vb_index", D, "vb[k - 4'd2] <= rd_data;", "vb[k - 4'd1] <= rd_data;"),
    ("dc_ra_step", D, "ra <= ra + 20'd1; end", "ra <= ra + 20'd2; end"),
    ("dc_next_cx", D, "if (cx != wmax) cx <= cx + 4'd1;", "if (cx != wmax - 1) cx <= cx + 4'd1;"),
    ("dc_next_cy", D, "if (cy != hmax) cy <= cy + 4'd1;", "if (cy != hmax - 1) cy <= cy + 4'd1;"),
    ("dc_next_ca", D, "if (ca != 2'd2) ca <= ca + 2'd1;", "if (ca != 2'd1) ca <= ca + 2'd1;"),
    ("dc_last_anchor", D, "(cy == hmax) && (ca == 2'd2);", "(cy == hmax);"),
    ("dc_wmax", D, "wire [3:0] wmax = hi ? (W2 - 1) : (W1 - 1);", "wire [3:0] wmax = hi ? (W1 - 1) : (W2 - 1);"),
    ("dc_anc_select", D, "wire [47:0] anc = hi ? anc2 : anc1;", "wire [47:0] anc = hi ? anc1 : anc2;"),
    ("dc_aw_map", D, "(ca == 2'd1) ? anc[23:16] : anc[39:32]", "(ca == 2'd1) ? anc[39:32] : anc[23:16]"),
    ("dc_ah_map", D, "(ca == 2'd1) ? anc[31:24] : anc[47:40]", "(ca == 2'd1) ? anc[47:40] : anc[31:24]"),
    ("dc_sup_last_found", D, "if (sup_last) begin j <= 6'd0; found <= 1'b0; end\n                    else j <= j + 6'd1;", "if (sup_last) begin j <= 6'd0; end\n                    else j <= j + 6'd1;"),
]


def run_one(item):
    name, fname, old, new = item
    d = os.path.join(WORK, name)
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, 'rtl'))
    for f in FILES:
        shutil.copy(os.path.join(RTLDIR, f), os.path.join(d, 'rtl', f))
    if name != 'control':
        p = os.path.join(d, 'rtl', fname)
        t = open(p, encoding='utf-8').read()
        assert t.count(old) == 1, (name, 'old text occurs %d times' % t.count(old))
        open(p, 'w', encoding='utf-8', newline='').write(t.replace(old, new))
    r = subprocess.run([sys.executable, os.path.join(HERE, 'run_decode_tests.py'), '--rtl-dir', os.path.join(d, 'rtl'), '--work', os.path.join(d, 'w'), '--quiet', '--stop-first'],
                       capture_output=True, text=True)
    return name, r.returncode, (r.stdout + r.stderr)[-400:]


def main():
    jobs = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    only = set(sys.argv[2:])
    src = {f: open(os.path.join(RTLDIR, f), encoding='utf-8').read() for f in FILES}
    bad = [m[0] for m in MUT if src[m[1]].count(m[2]) != 1]
    if bad:
        print('mutants whose old text does not occur exactly once:', bad)
        return 2
    muts = [m for m in MUT if not only or m[0] in only]
    items = [('control', None, None, None)] + muts
    t0 = time.time()
    res = {}
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        for name, rc, tail in ex.map(run_one, items):
            res[name] = (rc, tail)
    killed = survived = 0
    lines = ['decode_mutants %s  wall %.0f s' % (time.strftime('%Y-%m-%d %H:%M:%S'), time.time() - t0), '']
    lines.append('control (unmodified RTL): %s' % ('PASS' if res['control'][0] == 0 else 'FAIL  ' + res['control'][1]))
    for name, fname, old, new in muts:
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
    open(os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'decode_mutation_summary.txt'), 'w', encoding='utf-8').write(out)
    print(out)
    return 0 if survived == 0 and res['control'][0] == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
