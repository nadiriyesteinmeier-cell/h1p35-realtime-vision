#!/usr/bin/env python3
"""gen_box_vectors.py - test vectors for tb_custom/tb_yolo_box.v (rtl_custom/yolo_box_down.v) from the integer reference box_ref.py

Per case <prefix>_cfg.txt (frame width / height, box, net width, pad top, frames, mask of the frames that are armed, gap probability in 1/256), <prefix>_frames.hex (every frame as
IN_W * IN_H lines of 6 hex digits {r, g, b}) and <prefix>_exp.hex (for each armed frame the expected content of the written memory image: a line per byte of the padded map, 0x55 where
nothing may be written; the testbench pre-fills the image with 0x55 before each armed frame). Cases: random frames, extreme frames (all 0 / all 255 / alternating, the largest and
smallest box sums), a small box size / big frame, the full 1280 x 720 frame with BOX = 10 (the real configuration).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import box_ref as br


def write_case(prefix, w, h, box, net_w, pad_top, frames, armed_mask, gap, kind, seed, late=0):
    rng = np.random.default_rng(seed)
    rm, ra, rs = br.avg_params(box)
    imgs = []
    for f in range(frames):
        if kind == 'random':
            im = rng.integers(0, 256, size=(h, w, 3)).astype(np.uint8)
        elif kind == 'extreme':
            im = [np.zeros((h, w, 3)), np.full((h, w, 3), 255), np.indices((h, w, 3)).sum(axis=0) % 2 * 255, rng.choice([0, 255], size=(h, w, 3))][f % 4].astype(np.uint8)
        elif kind == 'gradient':
            im = (np.indices((h, w, 3))[1] * 255 // max(1, w - 1) + np.indices((h, w, 3))[2] * 40).astype(np.uint8)
        else:
            raise ValueError(kind)
        imgs.append(im)
    os.makedirs(os.path.dirname(prefix), exist_ok=True)
    net_h = h // box + 2 * pad_top
    size = (net_h + 2) * (net_w + 2) * 3
    with open(prefix + '_cfg.txt', 'w') as f:
        f.write('%d %d %d %d %d %d %d %d %d %d\n' % (w, h, box, net_w, pad_top, frames, armed_mask, gap, size, rm))
    with open(prefix + '_frames.hex', 'w') as f:
        for im in imgs:
            for y in range(h):
                for x in range(w):
                    f.write('%02X%02X%02X\n' % tuple(int(v) for v in im[y, x]))
    with open(prefix + '_exp.hex', 'w') as f:
        for fi in range(frames):
            if not (armed_mask >> fi) & 1:
                continue
            out = br.downscale(imgs[fi], box, rm, ra, rs)
            d = br.padded_bytes(out, net_w, net_h, pad_top)
            for a in range(size):
                f.write('%02X\n' % d.get(a, 0x55))
    return rm, ra, rs


CASES = [
    # name, w, h, box, net_w, pad_top, frames, armed mask, gap(/256), kind, seed, late mask (the arm pulse for frame f comes in the middle of frame f - 1), trunc mask (armed but only half of the lines are sent)
    ('small_box10', 40, 30, 10, 4, 2, 3, 0b101, 0, 'random', 1),
    ('small_gaps', 40, 30, 10, 4, 2, 3, 0b111, 64, 'random', 2),
    ('extreme', 40, 20, 10, 4, 1, 4, 0b1111, 0, 'extreme', 3),
    ('box8', 48, 32, 8, 6, 3, 2, 0b11, 0, 'random', 4),
    ('box6_wide', 60, 24, 6, 10, 2, 2, 0b11, 30, 'random', 5),
    ('gradient', 80, 40, 10, 8, 2, 2, 0b11, 0, 'gradient', 6),
    ('late_arm', 40, 30, 10, 4, 2, 4, 0b1010, 0, 'random', 8, 0b1010),
    ('truncated', 40, 30, 10, 4, 2, 6, 0b100101, 16, 'random', 9, 0, 0b001010),    # frames 1 and 3 are cut short, 4 is an unarmed frame behind a cut one
]
FULL = ('full_1280x720', 1280, 720, 10, 128, 12, 1, 0b1, 0, 'random', 7)


def main():
    outdir = os.path.normpath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'logs_custom', 'yolo_vec', 'box'))
    for c in CASES + ([FULL] if '--full' in sys.argv else []):
        print(c[0], write_case(os.path.join(outdir, c[0]), *c[1:]))


if __name__ == '__main__':
    main()
