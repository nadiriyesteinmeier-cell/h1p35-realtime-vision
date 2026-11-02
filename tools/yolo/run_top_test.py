#!/usr/bin/env python3
"""run_top_test.py - system-level simulation of the detector (tb_custom/tb_yolo_top.v): real 720p raster in, boxes out, dataset dump over the UART

Uses the case and the model ROMs written by tools/yolo/train/export_board.py:
    --case    prefix of the case files (default logs_custom/yolo_vec/board/board)
    --rtl     directory with yolo_desc_rom.v / yolo_wt_rom.v / yolo_pm_rom.v / yolo_model_cfg.v (default logs_custom/yolo_vec/board_rtl)
Icarus Verilog; several million clocks (a few minutes).  Exit code 0 only if the testbench prints TB_RESULT: PASS.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
IV = os.path.join(ROOT, 'tools', 'iverilog', 'ucrt64', 'bin')
RTL = ['yolo_top.v', 'yolo_net_engine.v', 'yolo_conv_core.v', 'yolo_aux_core.v', 'yolo_bank_ram.v', 'yolo_decode.v', 'yolo_lut_rom.v', 'yolo_box_down.v',
       'video_pos_adapter.v', 'key_debounce.v', 'uart_tx8.v']
GEN = ['yolo_desc_rom.v', 'yolo_wt_rom.v', 'yolo_pm_rom.v', 'yolo_model_cfg.v']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--case', default=os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'board', 'board'))
    ap.add_argument('--rtl', default=os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'board_rtl'))
    ap.add_argument('--rtl-dir', default=os.path.join(ROOT, 'rtl_custom'))
    a = ap.parse_args()
    vvp = os.path.join(ROOT, 'logs_custom', 'yolo_vec', 'sim_top.vvp')
    cmd = [os.path.join(IV, 'iverilog.exe'), '-g2005', '-o', vvp, os.path.join(ROOT, 'tb_custom', 'tb_yolo_top.v')]
    cmd += [os.path.join(a.rtl_dir, f) for f in RTL] + [os.path.join(a.rtl, f) for f in GEN]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout + r.stderr)
        return 2
    res = subprocess.run([os.path.join(IV, 'vvp.exe'), vvp, '+CASE=' + a.case.replace('\\', '/')], capture_output=True, text=True)
    out = res.stdout
    print('\n'.join(l for l in out.splitlines() if l.startswith(('RESULT', 'MISMATCH', 'TB_RESULT'))))
    return 0 if re.search(r'TB_RESULT: PASS tb_yolo_top', out) else 1


if __name__ == '__main__':
    sys.exit(main())
