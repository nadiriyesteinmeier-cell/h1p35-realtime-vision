#!/usr/bin/env python3
"""decode_ref.py - integer reference of the detection-head post-processing of the PH1P35 detector (bit-exact model of rtl_custom/yolo_decode.v)

Input: the int8 outputs of the two detection convolutions (YOLOv3 layout: channel = anchor * (5 + classes) + k, k = tx, ty, tw, th, objectness, class logits).
The network is trained / exported so that EVERY head output channel has the real scale 1/16 (the per-channel requantiser of the head convolutions absorbs the scale),
so one pair of 256-entry tables serves all channels:
    SIG[q]  = min(65535, round(65536 / (1 + exp(-q / 16))))                 sigmoid, Q16
    EXPQ8[q] = min(65535, round(256 * exp(q / 16)))                         exp, Q8 (saturates at q = 94, a box 256 times the anchor, clipped later anyway)
The tables are generated offline (floating point is used ONLY here, to write them); the hardware and this reference use integers only.

Per cell (head, y, x) and anchor a:
    obj = SIG[objectness]; best class = first maximum of SIG[class logit]; score = (obj * SIG[best]) >> 16       (Q16, 0..65535)
    candidate if score >= threshold; centre (Q4 network pixels) = ((x * 65536 + SIG[tx]) * stride) >> 12 ,  ((y * 65536 + SIG[ty]) * stride) >> 12 - pad_top * 16
    size (Q4) = (anchor * EXPQ8[tw]) >> 4 ;  x0 = cx - (w >> 1), x1 = cx + (w >> 1)  (same for y)
    frame coordinates = clip((v * K) >> 4, 0, limit)       K = frame pixels per network pixel (10 for a 128-wide input of the 1280 x 720 frame), arithmetic shift (floor)
Candidates are collected in `slots` slots (a full memory replaces its lowest score - first lowest slot - when the new score is strictly larger), then a greedy class-wise
non-maximum suppression picks up to `k_out` boxes: highest score first (first maximum slot wins), a box suppresses the remaining boxes of the same class whose
IoU is above iou_q6 / 64  (inter * 64 > iou_q6 * union, integers, no division).
Output boxes: (class, score, x0, y0, x1, y1) in frame pixels.
"""
import math

import numpy as np

SIG = [min(65535, int(math.floor(65536.0 / (1.0 + math.exp(-q / 16.0)) + 0.5))) for q in range(-128, 128)]
EXPQ8 = [min(65535, int(math.floor(256.0 * math.exp(q / 16.0) + 0.5))) for q in range(-128, 128)]


def sig(q):
    return SIG[int(q) + 128]


def expq8(q):
    return EXPQ8[int(q) + 128]


class Cfg(object):
    def __init__(self, classes=3, stride=(32, 16), anchors=(((12, 16), (20, 28), (32, 40)), ((4, 6), (8, 10), (14, 12))), grid=((3, 4), (6, 8)),
                 pad_top=12, k=10, fw=1280, fh=720, thr=26214, iou_q6=29, slots=32, k_out=8):
        self.classes, self.stride, self.anchors, self.grid = classes, stride, anchors, grid
        self.pad_top, self.k, self.fw, self.fh, self.thr, self.iou_q6, self.slots, self.k_out = pad_top, k, fw, fh, thr, iou_q6, slots, k_out


def clip(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def cells(heads, cfg):
    """generator of candidates (score, cls, x0, y0, x1, y1) in cell order: head 0 then 1, y, x, anchor"""
    nch = 5 + cfg.classes
    for hi, t in enumerate(heads):
        h, w, c = t.shape
        assert c == 3 * nch and (h, w) == tuple(cfg.grid[hi]), (t.shape, cfg.grid[hi])
        for y in range(h):
            for x in range(w):
                for a in range(3):
                    v = t[y, x, a * nch:(a + 1) * nch]
                    obj = sig(v[4])
                    best, cls = -1, 0
                    for i in range(cfg.classes):
                        s = sig(v[5 + i])
                        if s > best:
                            best, cls = s, i
                    score = (obj * best) >> 16
                    if score < cfg.thr:
                        continue
                    st = cfg.stride[hi]
                    cx = (((x << 16) + sig(v[0])) * st) >> 12
                    cy = ((((y << 16) + sig(v[1])) * st) >> 12) - cfg.pad_top * 16
                    bw = (cfg.anchors[hi][a][0] * expq8(v[2])) >> 4
                    bh = (cfg.anchors[hi][a][1] * expq8(v[3])) >> 4
                    x0, x1 = cx - (bw >> 1), cx + (bw >> 1)
                    y0, y1 = cy - (bh >> 1), cy + (bh >> 1)
                    yield (score, cls, clip((x0 * cfg.k) >> 4, 0, cfg.fw - 1), clip((y0 * cfg.k) >> 4, 0, cfg.fh - 1),
                           clip((x1 * cfg.k) >> 4, 0, cfg.fw - 1), clip((y1 * cfg.k) >> 4, 0, cfg.fh - 1))


def collect(heads, cfg):
    slots = []
    for cand in cells(heads, cfg):
        if len(slots) < cfg.slots:
            slots.append(cand)
        else:
            m = min(range(len(slots)), key=lambda i: (slots[i][0], i))     # first lowest score
            if cand[0] > slots[m][0]:
                slots[m] = cand
    return slots


def iou_gt(a, b, q6):
    ix = max(0, min(a[4], b[4]) - max(a[2], b[2]))
    iy = max(0, min(a[5], b[5]) - max(a[3], b[3]))
    inter = ix * iy
    aa = (a[4] - a[2]) * (a[5] - a[3])
    bb = (b[4] - b[2]) * (b[5] - b[3])
    union = aa + bb - inter
    return inter * 64 > q6 * union


def nms(slots, cfg):
    alive = [True] * len(slots)
    out = []
    while len(out) < cfg.k_out and any(alive):
        i = max((j for j in range(len(slots)) if alive[j]), key=lambda j: (slots[j][0], -j))
        out.append(slots[i])
        alive[i] = False
        for j in range(len(slots)):
            if alive[j] and slots[j][1] == slots[i][1] and iou_gt(slots[i], slots[j], cfg.iou_q6):
                alive[j] = False
    return out


def decode(heads, cfg):
    return nms(collect(heads, cfg), cfg)


def plant(t, y, x, a, cfg, logit_xy=(0, 0), logit_wh=(0, 0), obj=40, cls_idx=0, cls=40):
    """write one object into a head tensor (test helper)"""
    nch = 5 + cfg.classes
    base = a * nch
    t[y, x, base:base + nch] = -60
    t[y, x, base + 0], t[y, x, base + 1] = logit_xy
    t[y, x, base + 2], t[y, x, base + 3] = logit_wh
    t[y, x, base + 4] = obj
    t[y, x, base + 5 + cls_idx] = cls


def selftest():
    """semantic sanity checks of the fixed-point formulas (independent of the RTL): a planted object comes out where float arithmetic puts it"""
    cfg = Cfg()
    h1 = np.full((3, 4, 24), -100, dtype=np.int8)
    h2 = np.full((6, 8, 24), -100, dtype=np.int8)
    # head 2 (stride 16), cell (y=3, x=4), anchor 1 (8 x 10), centre offset 0.5 / 0.5, size = 2 * anchor
    plant(h2, 3, 4, 1, cfg, logit_xy=(0, 0), logit_wh=(11, 11), obj=60, cls_idx=2, cls=60)
    res = decode([h1, h2], cfg)
    assert len(res) == 1, res
    score, cls, x0, y0, x1, y1 = res[0]
    cx = (4 + 0.5) * 16
    cy = (3 + 0.5) * 16 - 12
    bw = 8 * math.exp(11 / 16.0)
    bh = 10 * math.exp(11 / 16.0)
    ex0, ex1 = (cx - bw / 2) * 10, (cx + bw / 2) * 10
    ey0, ey1 = (cy - bh / 2) * 10, (cy + bh / 2) * 10
    assert cls == 2 and abs(x0 - ex0) <= 12 and abs(x1 - ex1) <= 12 and abs(y0 - ey0) <= 12 and abs(y1 - ey1) <= 12, (res, (ex0, ey0, ex1, ey1))
    assert score > 50000, score
    return True


if __name__ == '__main__':
    print('decode_ref selftest', 'PASS' if selftest() else 'FAIL')
