#!/usr/bin/env python3
"""capture_uart.py - receive the network-input frames that the board sends in dataset mode (yolo_top mode 3: KEY3 + KEY4 three times from mode 0)

Protocol (yolo_top.v): 0xA5 0x5A 'I' <frame number, 16 bit, MSB first> <27648 bytes = 72 rows x 128 columns x (R, G, B), int8 = pixel - 128> <sum of the image bytes mod 256>.
At 115200 baud one frame takes about 2.4 s. Every frame is the EXACT input of the on-chip network (1280 x 720 averaged 10 x 10 on the FPGA), so images captured here are
the right training data for the board (same sensor, lens, ISP, averaging).

Writes <out>/img_<n>.png (128 x 72, plus a 4x enlarged copy for viewing in <out>/view/) and, at the end, <out>/frames.npy (uint8 [N, 96, 128, 3], letterboxed exactly like
the network input: 12 grey rows above and below) and <out>/meta.json (board frame numbers, time stamps, checksum errors).
Usage: F:/yolo_env/Scripts/python.exe capture_uart.py --port COM3 --out F:/yolo_capture/session01 [--n 200] [--baud 115200]
"""
import argparse
import json
import os
import time

import numpy as np
import serial
from PIL import Image


def read_exact(ser, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = ser.read(n - len(buf))
        if not chunk:
            raise TimeoutError('UART timeout after %d of %d bytes' % (len(buf), n))
        buf += chunk
    return bytes(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM3')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--out', required=True)
    ap.add_argument('--n', type=int, default=100)
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, 'view'), exist_ok=True)
    def open_port():
        t0 = time.time()
        while True:                      # the board's USB can drop for a moment (cable knock, re-enumeration): wait for it to come back
            try:
                return serial.Serial(a.port, a.baud, timeout=5)
            except serial.SerialException as e:
                if time.time() - t0 > 120:
                    raise
                print('waiting for %s (%s)' % (a.port, e))
                time.sleep(2)

    ser = open_port()
    frames, meta = [], dict(port=a.port, baud=a.baud, frames=[], bad=0, reopen=0)
    print('waiting for frames on %s (board in mode CAPTURE) ...' % a.port)
    try:
        while len(frames) < a.n:
            try:
                b = ser.read(1)
                if b != b'\xA5':
                    continue
                if ser.read(1) != b'\x5A' or ser.read(1) != b'I':
                    continue
                fn = int.from_bytes(read_exact(ser, 2), 'big')
                data = read_exact(ser, 27648)
                cs = read_exact(ser, 1)[0]
            except TimeoutError as e:
                print(e)
                continue
            except serial.SerialException as e:
                print('serial error (%s): reopening %s' % (e, a.port))
                meta['reopen'] += 1
                try:
                    ser.close()
                except Exception:
                    pass
                ser = open_port()
                continue
            if (sum(data) & 0xFF) != cs:
                meta['bad'] += 1
                print('checksum error in frame %d (%d bad so far)' % (fn, meta['bad']))
                continue
            img = (np.frombuffer(data, dtype=np.uint8) ^ 0x80).reshape(72, 128, 3)
            k = len(frames)
            Image.fromarray(img).save(os.path.join(a.out, 'img_%05d.png' % k))
            Image.fromarray(img).resize((512, 288), Image.NEAREST).save(os.path.join(a.out, 'view', 'img_%05d.png' % k))
            net = np.full((96, 128, 3), 128, dtype=np.uint8)
            net[12:84] = img
            frames.append(net)
            meta['frames'].append(dict(index=k, board_frame=fn, time=time.time()))
            print('frame %4d  (board frame %5d)' % (k, fn))
    finally:                             # keep what was captured even if the run is stopped
        if frames:
            np.save(os.path.join(a.out, 'frames.npy'), np.stack(frames))
        json.dump(meta, open(os.path.join(a.out, 'meta.json'), 'w'), indent=1)
        print('%d frames -> %s' % (len(frames), a.out))


if __name__ == '__main__':
    main()
