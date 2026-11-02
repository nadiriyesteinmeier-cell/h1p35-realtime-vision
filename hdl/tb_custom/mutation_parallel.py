#!/usr/bin/env python3
"""mutation_parallel.py - run mutation_test.py for a subset of mutants in several parallel processes and merge the verdicts.

  python mutation_parallel.py <jobs> <tag> <module-substring> [<module-substring> ...]
      jobs   number of parallel mutation_test.py processes (0 = do not run anything, only merge the existing
             logs_custom/mutation_console_<tag>_*.txt of an earlier run into the summary)
      tag    short name; consoles go to logs_custom/mutation_console_<tag>_<n>.txt, merged summary to
             logs_custom/mutation_summary_<tag>.txt
      module-substring   selects mutants whose module name contains it (e.g. osd_overlay, contest_vision_path)

Every process runs its own control (unmutated) cases first; a mutant is only counted if its process' controls passed.
The merge checks that every selected mutant was reported exactly once.
Exit code 0 = all killed or argued-equivalent, 1 otherwise.
"""
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import mutation_test as mt          # noqa: E402  (importing only reads the mutant table; main() is not run)

jobs = int(sys.argv[1])
tag = sys.argv[2]
mods = sys.argv[3:]
sel = [m for m in mt.M if any(x in m[0] for x in mods)]
names = [m[1] for m in sel]
if len(set(names)) != len(names):
    print("duplicate mutant names")
    sys.exit(1)
# substring matching in mutation_test.py: refuse selections where a name is a substring of another selected name
for a in names:
    for b in names:
        if a != b and a in b:
            print("ambiguous: %s is a substring of %s" % (a, b))
            sys.exit(1)

chunks = [names[i::jobs] for i in range(jobs)]
procs = []
t0 = time.time()
if jobs == 0:
    # merge only: reconstruct one pseudo-process per existing console file
    class _Done:
        def wait(self):
            return 0
    for f in sorted(mt.LOGS.glob("mutation_console_%s_*.txt" % tag)):
        n = int(f.stem.rsplit("_", 1)[1])
        procs.append((n, [], _Done(), open(os.devnull, "w")))
for n, ch in enumerate(chunks):
    if not ch:
        continue
    env = dict(os.environ)
    env["MUT_TAG"] = "_%s_%d" % (tag, n)
    env["MUT_REPORT"] = "mutation_report_%s_%d.txt" % (tag, n)
    out = open(mt.LOGS / ("mutation_console_%s_%d.txt" % (tag, n)), "w")
    procs.append((n, ch, subprocess.Popen([sys.executable, str(HERE / "mutation_test.py")] + ch, env=env, stdout=out,
                                          stderr=subprocess.STDOUT, cwd=str(HERE)), out))
    print("started job %d with %d mutants" % (n, len(ch)), flush=True)

rc_all = 0
for n, ch, p, out in procs:
    p.wait()
    out.close()

verd = {}
ctl = []
for n, ch, p, out in procs:
    txt = (mt.LOGS / ("mutation_console_%s_%d.txt" % (tag, n))).read_text(errors="replace")
    for line in txt.splitlines():
        if line.startswith("control (unmutated)"):
            ctl.append(line)
        m = re.match(r"(\S+)\s+(killed|SURVIVED|equivalent|INVALID.*?)\s+\[", line)
        if m:
            # mutation_test.py repeats the last mutant line in its closing summary: count each (name, verdict) once
            if m.group(2) not in verd.setdefault(m.group(1), []):
                verd[m.group(1)].append(m.group(2))

lines = ["mutation_parallel %s tag=%s modules=%s jobs=%d  wall %.0f s" % (time.strftime("%Y-%m-%d %H:%M:%S"), tag, ",".join(mods), jobs, time.time() - t0), ""]
lines += sorted(set(l.split(":")[0] + ":" + l.split(":")[1].split("(")[0] for l in ctl))
lines.append("")
problems = []
killed = survived = equiv = 0
for nm in names:
    v = verd.get(nm, [])
    if len(v) != 1:
        problems.append("%s reported %d times" % (nm, len(v)))
        continue
    if v[0] == "killed":
        killed += 1
    elif v[0] == "equivalent":
        equiv += 1
    else:
        survived += 1
        problems.append("%s %s" % (nm, v[0]))
lines.append("selected=%d killed=%d equivalent(argued)=%d survived/invalid=%d" % (len(names), killed, equiv, survived))
if problems:
    lines.append("PROBLEMS: " + "; ".join(problems))
if any("PASS" not in l for l in ctl):
    lines.append("a control run did not PASS: " + "; ".join(l for l in ctl if "PASS" not in l))
    problems.append("control")
(mt.LOGS / ("mutation_summary_%s.txt" % tag)).write_text("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(1 if problems else 0)
