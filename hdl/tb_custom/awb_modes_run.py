#!/usr/bin/env python3
"""awb_modes_run.py - run tb_awb_modes.v with Icarus Verilog.

Builds logs_custom/awb_orig_tb.v from the UNMODIFIED vendor awb.v of contest_work_v3_color4 (module renamed awb_orig, nothing else
changed) and compiles it with the modified awb.v of contest_work_v3_shade, signal_delay.v and the testbench (which carries behavioural
stand-ins for the vendor divider and RAM IP). Prints the testbench output; exit code 0 only for TB_RESULT: PASS.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
IV = os.path.join(ROOT, 'tools', 'iverilog', 'ucrt64', 'bin')
src = open(os.path.join(ROOT, 'contest_work_v3_color4', 'user_source', 'hdl_source', 'awb.v'), 'rb').read()
n = len(re.findall(rb'module awb\s+#\(', src))
assert n == 1, n
orig = re.sub(rb'module awb\s+#\(', b'module awb_orig #(', src)
out = os.path.join(ROOT, 'logs_custom', 'awb_orig_tb.v')
open(out, 'wb').write(orig)
hd = os.path.join(ROOT, 'contest_work_v3_shade', 'user_source', 'hdl_source')
vvp = os.path.join(ROOT, 'logs_custom', 'sim_awb_modes.vvp')
cmd = [os.path.join(IV, 'iverilog.exe'), '-g2005', '-o', vvp, os.path.join(ROOT, 'tb_custom', 'tb_awb_modes.v'), out,
       os.path.join(hd, 'awb.v'), os.path.join(hd, 'signal_delay.v')]
r = subprocess.run(cmd, capture_output=True, text=True)
print(r.stdout + r.stderr)
if r.returncode:
    sys.exit(2)
r = subprocess.run([os.path.join(IV, 'vvp.exe'), vvp], capture_output=True, text=True)
print(r.stdout[-3000:])
sys.exit(0 if 'TB_RESULT: PASS' in r.stdout else 1)
