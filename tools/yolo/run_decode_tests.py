#!/usr/bin/env python3
"""run_decode_tests.py - generate the vectors (gen_decode_vectors.py), compile tb_yolo_decode.v with Icarus Verilog and run every case of rtl_custom/yolo_decode.v

Usage: python run_decode_tests.py [--rtl-dir dir] [--work dir] [--quiet] [--stop-first]
--rtl-dir: directory holding yolo_decode.v and yolo_lut_rom.v (default rtl_custom; the mutation run points it at a copy with one mutated file).
Exit code 0 only if every case prints TB_RESULT: PASS.
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
import decode_ref as dr
import gen_decode_vectors as g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rtl-dir', default=os.path.join(ROOT, 'rtl_custom'))
    ap.add_argument('--work', default=os.path.join(ROOT, 'logs_custom', 'yolo_vec'))
    ap.add_argument('--quiet', action='store_true')
    ap.add_argument('--stop-first', action='store_true')
    a = ap.parse_args()
    cfg = dr.Cfg()
    vec = os.path.join(a.work, 'decode')
    for (nm, kind, seed) in g.CASES:
        g.write_case(os.path.join(vec, nm), kind, seed, cfg)
    vvp = os.path.join(a.work, 'sim_decode.vvp')
    r = subprocess.run([os.path.join(IV, 'iverilog.exe'), '-g2005', '-o', vvp, os.path.join(ROOT, 'tb_custom', 'tb_yolo_decode.v'),
                        os.path.join(a.rtl_dir, 'yolo_decode.v'), os.path.join(a.rtl_dir, 'yolo_lut_rom.v')], capture_output=True, text=True)
    if r.returncode:
        print(r.stdout + r.stderr)
        return 2
    total = fails = 0
    for (nm, kind, seed) in g.CASES:
        res = subprocess.run([os.path.join(IV, 'vvp.exe'), vvp, '+CASE=' + os.path.join(vec, nm).replace('\\', '/')], capture_output=True, text=True)
        m = re.search(r'TB_RESULT: (PASS|FAIL) tb_yolo_decode (\S+) (.*)', res.stdout)
        total += 1
        if m and m.group(1) == 'PASS':
            if not a.quiet:
                print('PASS %-14s %s' % (nm, m.group(3)))
        else:
            fails += 1
            print('FAIL %-14s\n%s' % (nm, res.stdout[-1500:]))
            if a.stop_first:
                print('yolo_decode: stopped after the first failure')
                return 1
    print('yolo_decode: %d cases, %d failed' % (total, fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
