#!/usr/bin/env python3
"""run_conv_tests.py - generate the vectors, compile tb_yolo_conv.v for LANES = 8 and 16 with Icarus Verilog, run every case

Usage: python run_conv_tests.py [--rtl path/to/yolo_conv_core.v] [--lanes 8 16] [--keep-going]
Exit code 0 only if every case of every lane count prints TB_RESULT: PASS. The RTL path can point to a mutated copy (used by the mutation run).
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
import gen_conv_vectors as g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rtl', default=os.path.join(ROOT, 'rtl_custom', 'yolo_conv_core.v'))
    ap.add_argument('--lanes', type=int, nargs='+', default=[8, 16])
    ap.add_argument('--work', default=os.path.join(ROOT, 'logs_custom', 'yolo_vec'))
    ap.add_argument('--quiet', action='store_true')
    ap.add_argument('--stop-first', action='store_true', help='stop at the first failing case (mutation runs)')
    a = ap.parse_args()
    total = fails = 0
    for lanes in a.lanes:
        vec = os.path.join(a.work, 'L%d' % lanes)
        for cs in g.all_cases(lanes):
            (nm, h, w, cin, cout, k, act, seed, kind, opad, target, fsh) = cs[:12]
            g.make_case(os.path.join(vec, nm), h, w, cin, cout, k, act, lanes, seed, kind, opad, target, fsh, 65535 if nm == 'mult_max' else None,
                        cs[12] if len(cs) > 12 else False)
        vvp = os.path.join(a.work, 'sim_conv_L%d.vvp' % lanes)
        r = subprocess.run([os.path.join(IV, 'iverilog.exe'), '-g2005', '-P', 'tb_yolo_conv.LANES=%d' % lanes, '-o', vvp,
                            os.path.join(ROOT, 'tb_custom', 'tb_yolo_conv.v'), a.rtl], capture_output=True, text=True)
        if r.returncode:
            print(r.stdout + r.stderr)
            return 2
        for (nm, *_rest) in g.all_cases(lanes):
            res = subprocess.run([os.path.join(IV, 'vvp.exe'), vvp, '+CASE=' + os.path.join(vec, nm).replace('\\', '/')], capture_output=True, text=True)
            out = res.stdout
            m = re.search(r'TB_RESULT: (PASS|FAIL) tb_yolo_conv (\S+) (.*)', out)
            total += 1
            if m and m.group(1) == 'PASS':
                if not a.quiet:
                    print('PASS L%-2d %-18s %s' % (lanes, nm, m.group(3).replace(vec.replace('\\', '/'), '')))
            else:
                fails += 1
                print('FAIL L%-2d %-18s\n%s' % (lanes, nm, out[-1500:]))
                if a.stop_first:
                    print('yolo_conv_core: stopped after the first failure')
                    return 1
    print('yolo_conv_core: %d cases, %d failed' % (total, fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
