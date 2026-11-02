#!/usr/bin/env python3
"""run_aux_tests.py - generate the vectors, compile tb_yolo_aux.v with Icarus Verilog, run every case of rtl_custom/yolo_aux_core.v

Usage: python run_aux_tests.py [--rtl path/to/yolo_aux_core.v] [--work dir] [--quiet] [--stop-first]
Exit code 0 only if every case prints TB_RESULT: PASS. The RTL path can point to a mutated copy (used by aux_mutants.py).
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
import gen_aux_vectors as g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rtl', default=os.path.join(ROOT, 'rtl_custom', 'yolo_aux_core.v'))
    ap.add_argument('--work', default=os.path.join(ROOT, 'logs_custom', 'yolo_vec'))
    ap.add_argument('--quiet', action='store_true')
    ap.add_argument('--stop-first', action='store_true')
    a = ap.parse_args()
    vec = os.path.join(a.work, 'auxops')
    cases = g.all_cases()
    for cs in cases:
        g.make_case(os.path.join(vec, cs[0]), *cs[1:])
    vvp = os.path.join(a.work, 'sim_aux.vvp')
    r = subprocess.run([os.path.join(IV, 'iverilog.exe'), '-g2005', '-o', vvp, os.path.join(ROOT, 'tb_custom', 'tb_yolo_aux.v'), a.rtl], capture_output=True, text=True)
    if r.returncode:
        print(r.stdout + r.stderr)
        return 2
    total = fails = 0
    for cs in cases:
        nm = cs[0]
        res = subprocess.run([os.path.join(IV, 'vvp.exe'), vvp, '+CASE=' + os.path.join(vec, nm).replace('\\', '/')], capture_output=True, text=True)
        out = res.stdout
        m = re.search(r'TB_RESULT: (PASS|FAIL) tb_yolo_aux (\S+) (.*)', out)
        total += 1
        if m and m.group(1) == 'PASS':
            if not a.quiet:
                print('PASS %-18s %s' % (nm, m.group(3).replace(vec.replace('\\', '/'), '')))
        else:
            fails += 1
            print('FAIL %-18s\n%s' % (nm, out[-1500:]))
            if a.stop_first:
                print('yolo_aux_core: stopped after the first failure')
                return 1
    print('yolo_aux_core: %d cases, %d failed' % (total, fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
