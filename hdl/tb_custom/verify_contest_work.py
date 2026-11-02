#!/usr/bin/env python3
"""verify_contest_work.py - provenance checks that must hold before any build / burn.

  1. lab1 / lab2 / lab3 are byte-identical to the 2026-10-05 snapshot (handoff/baseline_manifest.json)
  2. contest_work/user_source differs from lab1/user_source ONLY in the expected places
       modified : hdl_source/design_top_wrapper.v   (ports I_sw / O_led, one instance, three hdmi_tx inputs)
                  constraints_source/pin.adc        (8 appended pin lines)
       added    : hdl_source/custom/*.v             (our modules)
     and the project file contest_work/td_project/camera_to_dsi_display.al differs from lab1's only by the
     Project Path and the registered custom sources
  3. every contest_work/user_source/hdl_source/custom/*.v is byte-identical to rtl_custom/*.v
  4. every custom source listed in the .al exists, and every source path in the .al resolves to a file

Usage: python verify_contest_work.py [project-folder]      (default: contest_work; contest_work_v2 for the v2 build)
Exit code 0 = all hold. Prints one line per check; prints SHA-256 of the files that go into the build.
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
PROJ = sys.argv[1] if len(sys.argv) > 1 else 'contest_work'


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        h.update(f.read())
    return h.hexdigest()


def walk(base):
    out = {}
    for d, _, files in os.walk(base):
        for f in files:
            full = os.path.join(d, f)
            out[os.path.relpath(full, base).replace('\\', '/')] = full
    return out


ok = True


def report(name, cond, detail=''):
    global ok
    ok = ok and cond
    print(('PASS  ' if cond else 'FAIL  ') + name + (('  ' + detail) if detail else ''))


# 1. baseline manifest
man = json.load(open(os.path.join(ROOT, 'handoff', 'baseline_manifest.json'), encoding='utf-8'))
bad = []
for e in man['files']:
    p = os.path.join(ROOT, e['path'])
    if not os.path.isfile(p) or sha(p) != e['sha256'] or os.path.getsize(p) != e['bytes']:
        bad.append(e['path'])
report('baseline manifest (%d files)' % len(man['files']), not bad, ', '.join(bad[:5]))

# 2. contest_work vs lab1
lab = walk(os.path.join(ROOT, 'lab1', 'user_source'))
cw = walk(os.path.join(ROOT, PROJ, 'user_source'))
modified_expected = {'hdl_source/design_top_wrapper.v', 'constraints_source/pin.adc'}
# vendor files that a specific experimental project is ALLOWED to change (each change is documented in that project's doc)
EXTRA_MODIFIED = {
    'contest_work_v2_hdmidiag': {'hdl_source/hdmi_phy_warpper.v', 'hdl_source/hdmi_tx.v', 'hdl_source/lane_lvds_10_1.v'},      # docs/HDMI_DIAG_2026-10-07.md
    'contest_work_v3_shade': {'hdl_source/awb.v', 'hdl_source/isp/isp_top.v',                                                 # docs/IMAGE_SHADING_2026-10-16.md
                              'hdl_source/isp/demosaic_4x_2_0/demosaic.v'},
    'contest_work_v3_isplite': {'hdl_source/isp/isp_top.v', 'hdl_source/isp/demosaic_4x_2_0/demosaic.v'},                    # docs/IMAGE_SHADING_2026-10-16.md
    'contest_work_v3_yolo': {'hdl_source/isp/isp_top.v', 'hdl_source/isp/demosaic_4x_2_0/demosaic.v'},                       # isplite + detector, docs/YOLO_BOARD_2026-10-24.md
    'contest_work_v3_wb': {'hdl_source/isp/isp_top.v', 'hdl_source/isp/demosaic_4x_2_0/demosaic.v'},                         # yolo + white-balance page, docs/WB_MODE_2026-10-25.md
    'contest_work_v3_isp': {'hdl_source/isp/isp_top.v', 'hdl_source/isp/demosaic_4x_2_0/demosaic.v'},                        # wb + isp_color (BLC / LSC / AE), docs/ISP_COLOR_2026-10-26.md
    'contest_work_v3_adv': {'hdl_source/isp/isp_top.v', 'hdl_source/isp/demosaic_4x_2_0/demosaic.v'},                        # isp + latency / motion / logo on every page, docs/ADV_2026-10-26.md
    'contest_work_v3_advy': {'hdl_source/isp/isp_top.v', 'hdl_source/isp/demosaic_4x_2_0/demosaic.v'},                       # adv03 + YOLO ROMs of the real-data model (YOLO_GEN_DIR), docs/YOLO_REAL_2026-10-28.md
}
# generated model files (ROMs, model constants) are compared with the export directory of tools/yolo/train/export_board.py instead of rtl_custom
GENERATED = {'yolo_desc_rom.v', 'yolo_wt_rom.v', 'yolo_pm_rom.v', 'yolo_model_cfg.v'}
GEN_DIR = os.environ.get('YOLO_GEN_DIR', os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'board_rtl'))   # another export (e.g. a real-data model): set YOLO_GEN_DIR
# other generated files and the directory their reference copy lives in
GEN_OTHER = {'lsc_rom.v': os.path.join(ROOT, 'logs_custom', 'lsc')}       # tools/shade/gen_lsc_table.py
modified_expected = modified_expected | EXTRA_MODIFIED.get(PROJ, set())
added = sorted(k for k in cw if k not in lab)
removed = sorted(k for k in lab if k not in cw)
changed = sorted(k for k in cw if k in lab and sha(cw[k]) != sha(lab[k]))
unexpected_add = [k for k in added if not k.startswith('hdl_source/custom/')]
report('no baseline file removed from contest_work', not removed, ', '.join(removed[:5]))
report('only expected baseline files modified', set(changed) == modified_expected, 'modified: ' + ', '.join(changed))
report('only custom/ added', not unexpected_add, ', '.join(unexpected_add[:5]))

al_lab = open(os.path.join(ROOT, 'lab1', 'td_project', 'camera_to_dsi_display.al'), 'rb').read().decode('utf-8')
al_cw = open(os.path.join(ROOT, PROJ, 'td_project', 'camera_to_dsi_display.al'), 'rb').read().decode('utf-8')
stripped = re.sub(r'            <File Path="\.\./user_source/hdl_source/custom/[^"]+">.*?</File>\r\n', '', al_cw, flags=re.S)
stripped = stripped.replace('Path="F:/fpga_s2/%s/td_project"' % PROJ, 'Path="F:/fpga_s2/lab1/td_project"')
report('.al == lab1 .al + Project Path + custom entries', stripped == al_lab)

# 3. custom sources == rtl_custom
mism = []
n = 0
for k, full in cw.items():
    if k.startswith('hdl_source/custom/'):
        n += 1
        bn = os.path.basename(k)
        src = os.path.join(GEN_DIR if bn in GENERATED else GEN_OTHER.get(bn, os.path.join(ROOT, 'rtl_custom')), bn)
        if not os.path.isfile(src) or sha(src) != sha(full):
            mism.append(k)
report('custom/*.v identical to rtl_custom / the model export (%d files)' % n, not mism and n > 0, ', '.join(mism))

# 4. .al references resolve
tdp = os.path.join(ROOT, PROJ, 'td_project')
missing = []
nref = 0
for m in re.finditer(r'<File Path="([^"]+)"', al_cw):
    nref += 1
    if not os.path.isfile(os.path.normpath(os.path.join(tdp, m.group(1)))):
        missing.append(m.group(1))
report('.al file references resolve (%d)' % nref, not missing, ', '.join(missing[:5]))
custom_refs = re.findall(r'<File Path="\.\./user_source/hdl_source/custom/([^"]+)"', al_cw)
extra = sorted(k.split('/')[-1] for k in cw if k.startswith('hdl_source/custom/') and k.split('/')[-1] not in custom_refs)
report('every custom/*.v is registered in the .al', not extra, ', '.join(extra))

print()
print('SHA-256 of the files that differ from lab1 (for the build record):')
for rel in ['user_source/hdl_source/design_top_wrapper.v', 'user_source/constraints_source/pin.adc',
            'td_project/camera_to_dsi_display.al']:
    print('  %s  %s' % (sha(os.path.join(ROOT, PROJ, rel.replace('/', os.sep))), PROJ + '/' + rel))
for k in sorted(cw):
    if k.startswith('hdl_source/custom/'):
        print('  %s  %s/user_source/%s' % (sha(cw[k]), PROJ, k))

print()
print('VERIFY_CONTEST_WORK: ' + ('PASS' if ok else 'FAIL'))
sys.exit(0 if ok else 1)
