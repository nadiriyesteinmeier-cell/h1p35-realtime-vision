#!/usr/bin/env python3
"""uart_soak.py - long-run stability record from the board's UART report (basic requirement 3: stable output)

Reads the FPGA report lines (rtl_custom/uart_report.v, ~5 lines/s, ending "...;CAMxxx,DSPxxx") for --minutes, and writes
logs_custom/soak/soak_<time>.csv (one row per second: lines, camera fps, display fps) and a summary:
total lines, seconds without any line (gaps), camera / display frame-rate min / max / mean, malformed lines.
The frame rates come from the FPGA's own meter against the 50 MHz crystal (fps_meter.v), so they show whether the camera and the
HDMI output kept running; the screen itself still needs a look from the user.

    F:/yolo_env/Scripts/python.exe tools/board/uart_soak.py --port COM3 --minutes 30
"""
import argparse
import os
import re
import time

import serial

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
FPS = re.compile(r'CAM(\d{3}),DSP(\d{3})')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM3')
    ap.add_argument('--minutes', type=float, default=30.0)
    a = ap.parse_args()
    out_dir = os.path.join(ROOT, 'logs_custom', 'soak')
    os.makedirs(out_dir, exist_ok=True)
    stamp = time.strftime('%Y%m%d_%H%M%S')
    csv_path = os.path.join(out_dir, 'soak_%s.csv' % stamp)
    sum_path = os.path.join(out_dir, 'soak_%s_summary.txt' % stamp)
    t0 = time.time()
    end = t0 + a.minutes * 60
    lines = bad = 0
    cams, dsps = [], []
    per_sec = {}
    reopen = 0

    def open_port():
        while time.time() < end:         # the board's USB can drop (cable knock, power key): wait for it, the lost seconds count as gaps
            try:
                return serial.Serial(a.port, 115200, timeout=0.5)
            except serial.SerialException:
                time.sleep(1)
        return None

    sp = open_port()
    with open(csv_path, 'w', encoding='utf-8') as fc:
        fc.write('second,lines,cam_fps,dsp_fps\n')
        while sp is not None and time.time() < end:
            try:
                raw = sp.readline()
            except serial.SerialException:
                reopen += 1
                try:
                    sp.close()
                except Exception:
                    pass
                sp = open_port()
                continue
            if not raw:
                continue
            sec = int(time.time() - t0)
            m = FPS.search(raw.decode('ascii', 'replace'))
            if not m:
                bad += 1
                continue
            lines += 1
            c, d = int(m.group(1)), int(m.group(2))
            cams.append(c)
            dsps.append(d)
            n, _, _ = per_sec.get(sec, (0, c, d))
            per_sec[sec] = (n + 1, c, d)
        if sp is not None:
            sp.close()
        total = int(a.minutes * 60)
        for s in range(total):
            n, c, d = per_sec.get(s, (0, '', ''))
            fc.write('%d,%d,%s,%s\n' % (s, n, c, d))
    gaps = [s for s in range(total) if s not in per_sec]
    rows = [
        'UART soak %s, port %s, %.1f min, started %s' % (stamp, a.port, a.minutes, time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t0))),
        'report lines: %d (%.2f per second), malformed lines: %d' % (lines, lines / max(1, total), bad),
        'seconds without any report line: %d%s, port re-opened %d times' % (len(gaps), (' (first: %s)' % gaps[:10]) if gaps else '', reopen),
        'camera fps  min %s max %s mean %.2f' % (min(cams) if cams else '-', max(cams) if cams else '-', sum(cams) / len(cams) if cams else 0),
        'display fps min %s max %s mean %.2f' % (min(dsps) if dsps else '-', max(dsps) if dsps else '-', sum(dsps) / len(dsps) if dsps else 0),
        'per-second record: %s' % csv_path,
    ]
    open(sum_path, 'w', encoding='utf-8').write('\n'.join(rows) + '\n')
    print('\n'.join(rows))


if __name__ == '__main__':
    main()
