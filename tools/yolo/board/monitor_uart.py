#!/usr/bin/env python3
"""monitor_uart.py - print / log the detections the board reports over the UART (yolo_top modes 1 and 2, one report every 200 ms)

Report format (yolo_top.v): "Y <n> <frame:4 hex> <latency ms:2 hex> [<phase:1 hex><layer:2 hex> <layers done:2 hex> <ms in net/dec:2 hex>]" then n lines "<cls><score:2 hex> <x0> <y0> <x1> <y1>" (3 hex digits each, frame pixels of 1280 x 720).
The PC only displays what the FPGA computed; it takes no part in the detection.
Usage: F:/yolo_env/Scripts/python.exe monitor_uart.py --port COM3 [--csv F:/yolo_capture/detections.csv]
"""
import argparse
import time

import serial

CLS = ['red', 'green', 'blue', '?']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM3')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--csv', default='')
    a = ap.parse_args()
    ser = serial.Serial(a.port, a.baud, timeout=2)
    log = open(a.csv, 'a') if a.csv else None
    pending = 0
    head = None
    while True:
        line = ser.readline().decode('ascii', 'replace').strip()
        if not line:
            continue
        p = line.split()
        if p[0] == 'Y' and len(p) in (4, 7):
            pending = int(p[1], 16)
            head = (int(p[2], 16), int(p[3], 16))
            diag = ''
            if len(p) == 7:              # board diagnostics (yolo_top): phase + layer, layers finished, ms in net + decode
                diag = '  phase %s layer %2d  layers done %3d  %3d ms in net/dec' % (p[4][0], int(p[4][1:], 16), int(p[5], 16), int(p[6], 16))
            print('[%s] frame %5d  latency %3d ms  %d box(es)%s' % (time.strftime('%H:%M:%S'), head[0], head[1], pending, diag))
            continue
        if pending and len(p) == 5 and len(p[0]) == 3:
            c, s = int(p[0][0], 16), int(p[0][1:], 16) * 256 / 65536.0
            x0, y0, x1, y1 = (int(v, 16) for v in p[1:])
            print('    %-5s %.2f  (%4d, %3d) - (%4d, %3d)' % (CLS[c & 3], s, x0, y0, x1, y1))
            if log:
                log.write('%f,%d,%d,%s,%.3f,%d,%d,%d,%d\n' % (time.time(), head[0], head[1], CLS[c & 3], s, x0, y0, x1, y1))
                log.flush()
            pending -= 1


if __name__ == '__main__':
    main()
