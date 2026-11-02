#!/usr/bin/env python3
"""run_all.py - one command for the whole detector verification (Icarus Verilog; ModelSim and the mutation sets on request)

Usage: python run_all.py [--mutants] [--modelsim] [--full-frame] [--jobs N]
  default       decode_ref self-test, yolo_conv_core / yolo_aux_core / yolo_net_engine / yolo_decode / yolo_box_down against the integer references, quantize.py self-test (float model -> int8 package -> RTL) (a few minutes)
  --mutants     also the five mutation sets (conv 43, aux 50, net 54, decode 66, box 33 mutants; about 25 minutes with --jobs 8)
  --modelsim    also the second simulator (tools/yolo/run_conv_modelsim.ps1, needs F:/medolsim and the user-level LM_LICENSE_FILE)
  --full-frame  the real 1280 x 720 / BOX 10 frame in the downscaler test (about 3 minutes)
The result of every step (the last line it printed and its exit code) goes to logs_custom/yolo_vec/regression_summary.txt; the exit code is 0 only if every step passed.
Nothing here touches a board, a bitstream or a TD project.
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
PY = sys.executable


def step(name, cmd, lines, results):
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=HERE)
    out = (r.stdout + r.stderr).strip().splitlines()
    last = out[-1] if out else ''
    if name.startswith('mutants'):
        keep = [l for l in out if l.startswith('mutants=') or 'SURVIVED' in l or 'INVALID' in l or l.startswith('control')]
        last = ' | '.join(keep)
    ok = r.returncode == 0
    if name.startswith('modelsim'):             # vsim -c returns 0 even on errors: judge by the per-core summary lines
        ms_lines = [l for l in out if l.startswith('ModelSim')]
        ok = ok and len(ms_lines) == 5 and all(l.endswith(', 0 failed') for l in ms_lines) and not any(l.startswith('NORESULT') for l in out)
        last = ' | '.join(l.replace('ModelSim ', '') for l in ms_lines)
    results.append(ok)
    lines.append('%-26s %-5s %5.0f s  %s' % (name, 'PASS' if ok else 'FAIL', time.time() - t0, last))
    print(lines[-1], flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mutants', action='store_true')
    ap.add_argument('--modelsim', action='store_true')
    ap.add_argument('--full-frame', action='store_true')
    ap.add_argument('--jobs', type=int, default=8)
    a = ap.parse_args()
    lines = ['run_all %s' % time.strftime('%Y-%m-%d %H:%M:%S')]
    results = []
    step('decode_ref selftest', [PY, 'decode_ref.py'], lines, results)
    step('yolo_conv_core', [PY, 'run_conv_tests.py', '--quiet'], lines, results)
    step('yolo_aux_core', [PY, 'run_aux_tests.py', '--quiet'], lines, results)
    step('yolo_net_engine', [PY, 'run_net_tests.py', '--quiet'], lines, results)
    step('yolo_decode', [PY, 'run_decode_tests.py', '--quiet'], lines, results)
    step('yolo_box_down', [PY, 'run_box_tests.py', '--quiet'] + (['--full'] if a.full_frame else []), lines, results)
    step('quantize selftest', [PY, 'quantize.py', '--selftest'], lines, results)
    if a.mutants:
        for nm, script in (('conv', 'conv_mutants.py'), ('aux', 'aux_mutants.py'), ('net', 'net_mutants.py'), ('decode', 'decode_mutants.py'), ('box', 'box_mutants.py')):
            step('mutants %s' % nm, [PY, script, str(a.jobs)], lines, results)
    if a.modelsim:
        step('modelsim (all cores)', ['powershell', '-ExecutionPolicy', 'Bypass', '-File', os.path.join(HERE, 'run_conv_modelsim.ps1')], lines, results)
    os.makedirs(os.path.join(ROOT, 'logs_custom', 'yolo_vec'), exist_ok=True)
    open(os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'regression_summary.txt'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    return 0 if all(results) else 1


if __name__ == '__main__':
    sys.exit(main())
