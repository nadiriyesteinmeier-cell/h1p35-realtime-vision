#!/usr/bin/env python3
"""run_net_tests.py - generate the mini-network vectors (mininet.py), compile tb_yolo_net.v with Icarus Verilog for LANES = 8 and 16 and run every case

Usage: python run_net_tests.py [--lanes 8 16] [--work dir] [--rtl-dir dir] [--quiet] [--layers]
--rtl-dir: directory holding the RTL files (default rtl_custom); used by the mutation run with one mutated copy.
Exit code 0 only if every case prints TB_RESULT: PASS. --layers prints the clocks per layer.
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
import mininet

RTL_FILES = ['yolo_net_engine.v', 'yolo_conv_core.v', 'yolo_aux_core.v', 'yolo_bank_ram.v']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--lanes', type=int, nargs='+', default=[8, 16])
    ap.add_argument('--work', default=os.path.join(ROOT, 'logs_custom', 'yolo_vec'))
    ap.add_argument('--rtl-dir', default=os.path.join(ROOT, 'rtl_custom'))
    ap.add_argument('--quiet', action='store_true')
    ap.add_argument('--layers', action='store_true')
    ap.add_argument('--stop-first', action='store_true')
    a = ap.parse_args()
    total = fails = 0
    for lanes in a.lanes:
        vec = os.path.join(a.work, 'net%d' % lanes)
        for (nm, w, h, ch, seed) in mininet.CASES:
            mininet.write_case(os.path.join(vec, nm), w, h, ch, lanes, seed)
        vvp = os.path.join(a.work, 'sim_net_L%d.vvp' % lanes)
        r = subprocess.run([os.path.join(IV, 'iverilog.exe'), '-g2005', '-P', 'tb_yolo_net.LANES=%d' % lanes, '-o', vvp, os.path.join(ROOT, 'tb_custom', 'tb_yolo_net.v')] +
                           [os.path.join(a.rtl_dir, f) for f in RTL_FILES], capture_output=True, text=True)
        if r.returncode:
            print(r.stdout + r.stderr)
            return 2
        for (nm, *_rest) in mininet.CASES:
            res = subprocess.run([os.path.join(IV, 'vvp.exe'), vvp, '+CASE=' + os.path.join(vec, nm).replace('\\', '/')], capture_output=True, text=True)
            out = res.stdout
            m = re.search(r'TB_RESULT: (PASS|FAIL) tb_yolo_net (\S+) (.*)', out)
            total += 1
            if m and m.group(1) == 'PASS':
                if not a.quiet:
                    print('PASS L%-2d %-6s %s' % (lanes, nm, m.group(3)))
                if a.layers:
                    print('\n'.join(l for l in out.splitlines() if l.startswith('LAYER')))
            else:
                fails += 1
                print('FAIL L%-2d %-6s\n%s' % (lanes, nm, out[-2500:]))
                if a.stop_first:
                    print('yolo_net_engine: stopped after the first failure')
                    return 1
    print('yolo_net_engine: %d cases, %d failed' % (total, fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
