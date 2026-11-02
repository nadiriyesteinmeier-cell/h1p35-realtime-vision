#!/usr/bin/env python3
"""screen_wb.py - white-balance only the HDMI monitor inside a phone video of the demo (the phone recorded the cold-white monitor as blue,
while the FPGA output itself is neutral: CAPTURE-page white paper R112 G113 B113)

    python screen_wb.py <in.mp4> <out.mp4>            (needs ffmpeg; F:/yolo_env python)
    python screen_wb.py --frames <png ...>            (preview: writes <name>_wb.png next to each frame)

Per frame (at 1/4 resolution): pixels that are bright and clearly bluish (screen content: R > 70, B > 130, B - R > 45, B - G > 15) are counted per row and
per column; the screen box is the span of rows / columns with enough of them, smoothed over time. Inside that box every pixel gets channel gains towards
neutral, weighted by its own blueness (B / R): the black bezel, red / yellow objects and the neutral table are left alone. Frames without a screen in view
(or with the screen too dark to find) are not changed.
"""
import subprocess
import sys

import numpy as np
from PIL import Image

FF = 'E:/Ultimate Vocal Remover/ffmpeg.exe'
GAIN = np.array([1.19, 1.0, 0.74], dtype=np.float32)        # about 90 % of the full correction measured on the screen floor (R138 G167 B237)
MIN_PIX = 900                                                # bluish pixels at 1/4 resolution needed to accept a screen
MIN_LOOSE = 5000                                             # dark-bluish pixels needed when no bright ones are found


def block(m):
    """bounding box of the largest block of a mask, via projections"""
    cx = longest_run(m.sum(0))                       # the screen is one block: other bluish things (tissue pack, LEDs, keypad) are cut off
    if cx is None:
        return None
    ry = longest_run(m[:, cx[0]:cx[1]].sum(1))
    if ry is None:
        return None
    cx = longest_run(m[ry[0]:ry[1]].sum(0)) or cx
    if cx[1] - cx[0] < 10 or ry[1] - ry[0] < 10:
        return None
    return cx[0], ry[0], cx[1], ry[1]


def find_box(small):
    r, g, b = small[..., 0].astype(np.int16), small[..., 1].astype(np.int16), small[..., 2].astype(np.int16)
    m = (r > 70) & (b > 130) & (b - r > 45) & (b - g > 15)
    if m.sum() < MIN_PIX:
        # a screen showing a dark scene (WB page at night) has no bright bluish pixels at all; only a large dark-bluish block counts
        # (checked at 1 frame/s over the whole demo: the 5 frames this accepts all show the monitor)
        loose = (b > 45) & (b - r > 22) & (b - g > 8)
        if loose.sum() < MIN_LOOSE:
            return None
        bx = block(loose)
        return None if bx is None else np.array(bx, dtype=np.float32)
    seed = block(m)
    if seed is None:
        return None
    # grow: dark screen content (WB page at night, R58 G61 B86) fails the strict mask, so the seed may only cover the bright part of the screen
    x0, y0, x1, y1 = seed
    wx, wy = max(int(2.0 * (x1 - x0)) + 8, 120), max(int(2.0 * (y1 - y0)) + 8, 70)        # a small seed (bright patch) still reaches the whole screen
    X0, Y0 = max(0, x0 - wx), max(0, y0 - wy)
    X1, Y1 = min(small.shape[1], x1 + wx), min(small.shape[0], y1 + wy)
    loose = ((b > 45) & (b - r > 22) & (b - g > 8))[Y0:Y1, X0:X1]
    grown = block(loose)
    if grown is not None:
        gx0, gy0, gx1, gy1 = grown[0] + X0, grown[1] + Y0, grown[2] + X0, grown[3] + Y0
        if gx0 <= x1 and gx1 >= x0 and gy0 <= y1 and gy1 >= y0:              # must overlap the seed
            x0, y0, x1, y1 = min(x0, gx0), min(y0, gy0), max(x1, gx1), max(y1, gy1)
    return np.array([x0, y0, x1, y1], dtype=np.float32)


def longest_run(proj, gap=4):
    """longest stretch of indices whose projection is above 15 % of the peak, bridging gaps of up to `gap`"""
    on = np.nonzero(proj > max(4, 0.15 * proj.max()))[0]
    if len(on) == 0:
        return None
    best, start, prev = None, on[0], on[0]
    for i in list(on[1:]) + [None]:
        if i is None or i - prev > gap + 1:
            if best is None or prev + 1 - start > best[1] - best[0]:
                best = (start, prev + 1)
            if i is not None:
                start = i
        if i is not None:
            prev = i
    return best


def correct(frame, box4):
    """frame uint8 HxWx3 (full resolution), box4 in 1/4-resolution coordinates"""
    x0, y0, x1, y1 = (box4 * 4).astype(int)
    pad = 6
    x0, y0 = max(0, x0 - pad), max(0, y0 - pad)
    x1, y1 = min(frame.shape[1], x1 + pad), min(frame.shape[0], y1 + pad)
    roi = frame[y0:y1, x0:x1].astype(np.float32)
    r, g, b = roi[..., 0], roi[..., 1], roi[..., 2]
    wr = np.clip(((b + 8.0) / (r + 8.0) - 1.08) / 0.25, 0.0, 1.0)      # ratios, not differences: dark navy gets the correction too
    wb = np.clip(((b + 8.0) / (g + 8.0) - 1.05) / 0.25, 0.0, 1.0)      # B is only pulled down where it exceeds G (dark cyan would turn green)
    out = np.stack([r * (1.0 + wr * (GAIN[0] - 1.0)), g * (1.0 + wr * (GAIN[1] - 1.0)), b * (1.0 + wb * (GAIN[2] - 1.0))], axis=-1)
    frame[y0:y1, x0:x1] = np.clip(out, 0, 255).astype(np.uint8)
    return frame


def preview(paths):
    for p in paths:
        im = np.asarray(Image.open(p).convert('RGB')).copy()
        small = im[::4, ::4]
        box = find_box(small)
        if box is not None:
            im = correct(im, box)
        Image.fromarray(im).save(p.replace('.png', '_wb.png'))
        print(p, 'box', None if box is None else (box * 4).astype(int).tolist())


def video(src, dst):
    W, H = 1920, 1080
    dec = subprocess.Popen([FF, '-loglevel', 'error', '-i', src, '-vf', 'fps=30', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
    enc = subprocess.Popen([FF, '-loglevel', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '%dx%d' % (W, H), '-r', '30', '-i', '-',
                            '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-pix_fmt', 'yuv420p', '-colorspace', 'bt709', '-color_primaries', 'bt709',
                            '-color_trc', 'bt709', '-color_range', 'tv', dst], stdin=subprocess.PIPE)
    n, sm, miss = 0, None, 0
    while True:
        buf = dec.stdout.read(W * H * 3)
        if len(buf) < W * H * 3:
            break
        f = np.frombuffer(buf, np.uint8).reshape(H, W, 3).copy()
        box = find_box(f[::4, ::4])
        if box is not None:
            sm = box if sm is None or np.abs(box - sm).max() > 60 else 0.7 * sm + 0.3 * box      # follow the camera, jump on a cut
            miss = 0
        else:
            miss += 1
            if miss > 6:
                sm = None
        if sm is not None:
            f = correct(f, sm)
        enc.stdin.write(f.tobytes())
        n += 1
        if n % 300 == 0:
            print('frame', n, flush=True)
    enc.stdin.close()
    enc.wait()
    dec.wait()
    print('frames', n)


if __name__ == '__main__':
    if sys.argv[1] == '--frames':
        preview(sys.argv[2:])
    else:
        video(sys.argv[1], sys.argv[2])
