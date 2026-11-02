#!/usr/bin/env python3
"""run_box_tests.py - generate the vectors (gen_box_vectors.py), compile tb_yolo_box.v for every case's parameters with Icarus Verilog and run it against rtl_custom/yolo_box_down.v

Usage: python run_box_tests.py [--rtl path/to/yolo_box_down.v] [--work dir] [--quiet] [--stop-first] [--full]
--full adds the real 1280 x 720 / BOX 10 frame (about 1 M clocks, a few minutes).  Exit code 0 only if every case prints TB_RESULT: PASS.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
IV = os.path.join(ROOT, 'tools', 'iverilog', 'ucrt64', 'bin')
sys.path.insert(0, HERE)
import box_ref as br
import gen_box_vectors as g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rtl', default=os.path.join(ROOT, 'rtl_custom', 'yolo_box_down.v'))
    ap.add_argument('--work', default=os.path.join(ROOT, 'logs_custom', 'yolo_vec'))
    ap.add_argument('--quiet', action='store_true')
    ap.add_argument('--stop-first', action='store_true')
    ap.add_argument('--full', action='store_true')
    a = ap.parse_args()
    vec = os.path.join(a.work, 'box')
    cases = g.CASES + ([g.FULL] if a.full else [])
    total = fails = 0
    for c in cases:
        nm, w, h, box, net_w, pad_top, frames, mask, gap, kind, seed = c[:11]
        late = c[11] if len(c) > 11 else 0
        trunc = c[12] if len(c) > 12 else 0
        rm, ra, rs = g.write_case(os.path.join(vec, nm), w, h, box, net_w, pad_top, frames, mask, gap, kind, seed, late)
        vvp = os.path.join(a.work, 'sim_box_%s.vvp' % nm)
        pars = dict(IN_W=w, IN_H=h, BOX=box, NET_W=net_w, PAD_TOP=pad_top, RM=rm, RA=ra, RS=rs, FRAMES=frames, ARMED=mask, GAP=gap, LATE=late, TRUNC=trunc)
        with open(os.path.join(vec, nm + '_params.txt'), 'w') as pf:                 # for the ModelSim script (vsim -G<name>=<value>)
            pf.write(' '.join('%s=%d' % (k, v) for k, v in pars.items()) + chr(10))
        cmd = [os.path.join(IV, 'iverilog.exe'), '-g2005', '-o', vvp]
        for k, v in pars.items():
            cmd += ['-P', 'tb_yolo_box.%s=%d' % (k, v)]
        cmd += [os.path.join(ROOT, 'tb_custom', 'tb_yolo_box.v'), a.rtl]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            print(r.stdout + r.stderr)
            return 2
        res = subprocess.run([os.path.join(IV, 'vvp.exe'), vvp, '+CASE=' + os.path.join(vec, nm).replace('\\', '/')], capture_output=True, text=True)
        m = re.search(r'TB_RESULT: (PASS|FAIL) tb_yolo_box (\S+) (.*)', res.stdout)
        total += 1
        if m and m.group(1) == 'PASS':
            if not a.quiet:
                print('PASS %-16s %s' % (nm, m.group(3)))
        else:
            fails += 1
            print('FAIL %-16s\n%s' % (nm, res.stdout[-1500:]))
            if a.stop_first:
                print('yolo_box_down: stopped after the first failure')
                return 1
    print('yolo_box_down: %d cases, %d failed' % (total, fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
