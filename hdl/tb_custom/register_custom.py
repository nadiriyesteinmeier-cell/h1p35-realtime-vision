#!/usr/bin/env python3
"""register_custom.py - copy rtl_custom files into a work project's custom folder and register them in its .al

Usage: python register_custom.py [--in-place] <project-folder> <file.v> [<file.v> ...]
       --in-place: the files are already in the custom folder (generated there, e.g. the model ROMs of tools/yolo/train/export_board.py): register only

For every file: copy F:/fpga_s2/rtl_custom/<file> to <project>/user_source/hdl_source/custom/, and (if not yet listed) append a
<File> entry with the next free CompileOrder before </Verilog> in <project>/td_project/camera_to_dsi_display.al. The .al is edited as
text with its own line endings (it is not generic XML); run verify_contest_work.py <project> afterwards.
"""
import os
import re
import shutil
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
args = sys.argv[1:]
in_place = '--in-place' in args
args = [x for x in args if x != '--in-place']
proj = args[0]
files = args[1:]
al = os.path.join(ROOT, proj, 'td_project', 'camera_to_dsi_display.al')
dst = os.path.join(ROOT, proj, 'user_source', 'hdl_source', 'custom')

t = open(al, 'rb').read().decode('utf-8')
nl = '\r\n' if '\r\n' in t else '\n'
nxt = max(int(x) for x in re.findall(r'CompileOrder" Val="(\d+)"', t)) + 1
for f in files:
    if not in_place:
        shutil.copy(os.path.join(ROOT, 'rtl_custom', f), os.path.join(dst, f))
    assert os.path.exists(os.path.join(dst, f)), f
    key = '../user_source/hdl_source/custom/' + f
    if key in t:
        print('already registered:', f)
        continue
    ent = ('            <File Path="%s">' % key + nl +
           '                <FileInfo>' + nl +
           '                    <Attr Name="UsedInSyn" Val="true"/>' + nl +
           '                    <Attr Name="UsedInP&R" Val="true"/>' + nl +
           '                    <Attr Name="BelongTo" Val="design_1"/>' + nl +
           '                    <Attr Name="CompileOrder" Val="%d"/>' % nxt + nl +
           '                </FileInfo>' + nl +
           '            </File>' + nl)
    anchor = '        </Verilog>' + nl
    assert t.count(anchor) == 1, 'anchor </Verilog> not unique'
    t = t.replace(anchor, ent + anchor)
    print('registered %s with CompileOrder %d' % (f, nxt))
    nxt += 1
open(al, 'wb').write(t.encode('utf-8'))
