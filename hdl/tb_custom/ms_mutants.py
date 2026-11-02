#!/usr/bin/env python3
"""ms_mutants.py - run a ModelSim testbench against deliberately broken copies of rtl_custom (parallel, private work libraries)

Usage: python ms_mutants.py <testbench-name> <spec.py> [parallel-jobs]

spec.py defines   MUT = [(name, file-in-rtl_custom, text-that-occurs-exactly-once, replacement), ...]
For every entry a copy of rtl_custom is made in logs_custom/mut_ms/<tb>/<name>/ with that one edit, then
  vsim -c -do "set TBDIR ...; set ONLY <tb>; set WRKNAME w_<tb>_<name>; set RTLDIR logs_custom/mut_ms/<tb>/<name>; do run_modelsim.do"
runs it (the run_modelsim.do list decides which sources the testbench gets; anything that lives in rtl_custom is taken from the copy).
A mutant is KILLED when the log has TB_RESULT: FAIL; SURVIVED when it ends in TB_RESULT: PASS. A control run on the unmodified copy must PASS.
The summary is written to logs_custom/mut_ms/<tb>/summary.txt. The license variable is read from the user environment (registry);
nothing is printed or changed about it.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
tb = sys.argv[1]
spec_path = sys.argv[2]
jobs = int(sys.argv[3]) if len(sys.argv) > 3 else 6

spec = importlib.util.spec_from_file_location('mutspec', spec_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
MUT = list(mod.MUT)
EQUIV = dict(getattr(mod, 'EQUIV', {}))

try:
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as k:
        lic = winreg.QueryValueEx(k, 'LM_LICENSE_FILE')[0]
except Exception:
    lic = os.environ.get('LM_LICENSE_FILE', '')
env = dict(os.environ)
env['LM_LICENSE_FILE'] = lic

base = os.path.join(ROOT, 'logs_custom', 'mut_ms', tb)
os.makedirs(base, exist_ok=True)
items = [('control', None, None, None)] + MUT
for name, f, old, new in items:
    d = os.path.join(base, name)
    if os.path.isdir(d):
        shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(os.path.join(ROOT, 'rtl_custom'), d)
    if f:
        p = os.path.join(d, f)
        t = open(p, encoding='utf-8').read()
        assert t.count(old) == 1, (name, 'old text occurs %d times' % t.count(old))
        open(p, 'w', encoding='utf-8', newline='').write(t.replace(old, new))

vsim = r'F:\medolsim\win64\vsim.exe'
pending = list(items)
running = []
results = {}
t0 = time.time()
while pending or running:
    while pending and len(running) < jobs:
        name = pending.pop(0)[0]
        rel = 'logs_custom/mut_ms/%s/%s' % (tb, name)
        do = 'set TBDIR %s/tb_custom; set ONLY %s; set WRKNAME w_%s_%s; set RTLDIR %s; do %s/tb_custom/run_modelsim.do' % (
            ROOT.replace('\\', '/'), tb, tb, name, rel, ROOT.replace('\\', '/'))
        log = open(os.path.join(base, name + '.log'), 'wb')
        p = subprocess.Popen([vsim, '-c', '-do', do], stdout=log, stderr=subprocess.STDOUT, env=env, cwd=base)
        running.append((name, p, log))
    time.sleep(3)
    still = []
    for name, p, log in running:
        if p.poll() is None:
            still.append((name, p, log))
        else:
            log.close()
            txt = open(os.path.join(base, name + '.log'), 'rb').read().decode('latin-1')
            if 'TB_RESULT: PASS' in txt:
                results[name] = 'PASS'
            elif 'TB_RESULT: FAIL' in txt:
                results[name] = 'FAIL'
            else:
                results[name] = 'NO RESULT (tool error?)'
    running = still

lines = ['ms_mutants %s  tb=%s  wall %.0f s' % (time.strftime('%Y-%m-%d %H:%M:%S'), tb, time.time() - t0), '']
lines.append('control (unmodified copy): %s' % results.get('control'))
killed = survived = equiv = 0
for name, f, old, new in MUT:
    r = results.get(name)
    verdict = 'KILLED' if r == 'FAIL' else ('SURVIVED' if r == 'PASS' else r)
    if r == 'FAIL':
        killed += 1
    elif r == 'PASS' and name in EQUIV:
        verdict = 'EQUIVALENT'
        equiv += 1
    else:
        survived += 1
    lines.append('%-40s %-10s [%s]' % (name, verdict, f))
    if verdict == 'EQUIVALENT':
        lines.append('    argued: ' + EQUIV[name])
lines.append('')
lines.append('mutants=%d killed=%d equivalent(argued)=%d survived-or-invalid=%d' % (len(MUT), killed, equiv, survived))
out = '\n'.join(lines)
open(os.path.join(base, 'summary.txt'), 'w', encoding='utf-8').write(out)
print(out)
ok = results.get('control') == 'PASS' and survived == 0
sys.exit(0 if ok else 1)
