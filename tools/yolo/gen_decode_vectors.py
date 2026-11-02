#!/usr/bin/env python3
"""gen_decode_vectors.py - test vectors for tb_custom/tb_yolo_decode.v (rtl_custom/yolo_decode.v) from the integer reference decode_ref.py

Per case <prefix>_heads.hex (the two head tensors as int8 bytes, head 1 then head 2, anchor-major per cell: bank D of yolo_net_engine) and <prefix>_exp.hex
(first line: number of boxes, then one 60-bit hex word {cls[59:58], score[57:42], x0[41:31], y0[30:21], x1[20:10], y1[9:0]} per box).
The cases cover: no candidate, a single object, three classes, overlapping boxes of one class (suppression) and of different classes (both kept), equal scores
(tie rules), a few dozen candidates (candidate memory overflow: replacement of the lowest score), completely random tensors (hundreds of candidates, KOUT cap),
objects at the frame border (clipping), and the largest / smallest logits (table ends).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decode_ref as dr


def blank(cfg, rng, lo=-128, hi=-30):
    return [rng.integers(lo, hi, size=(h, w, 3 * (5 + cfg.classes))).astype(np.int8) for (h, w) in cfg.grid]


def score_pairs(cfg):
    """(obj logit, class logit) pairs and their score: used to hit the threshold exactly"""
    out = {}
    for qo in range(-20, 128):
        for qc in range(-20, 128):
            s = (dr.sig(qo) * dr.sig(qc)) >> 16
            out.setdefault(s, (qo, qc))
    return out


def iou_edge_pair(cfg, band):
    """search a pair of same-class boxes in one cell of head 2 whose IoU lies strictly inside (band-1, band] / 64: one threshold step decides whether the second is suppressed"""
    rng = np.random.default_rng(1234 + band)
    for _ in range(20000):
        xy = [tuple(int(v) for v in rng.integers(-30, 30, 2)) for _ in range(2)]
        wh = [tuple(int(v) for v in rng.integers(0, 20, 2)) for _ in range(2)]
        h = [np.full((g[0], g[1], 24), -128, dtype=np.int8) for g in cfg.grid]
        dr.plant(h[1], 3, 4, 0, cfg, logit_xy=xy[0], logit_wh=wh[0], obj=60, cls_idx=0, cls=60)
        dr.plant(h[1], 3, 4, 1, cfg, logit_xy=xy[1], logit_wh=wh[1], obj=50, cls_idx=0, cls=50)
        c = dr.collect(h, cfg)
        if len(c) != 2:
            continue
        a, b = c
        ix = max(0, min(a[4], b[4]) - max(a[2], b[2]))
        iy = max(0, min(a[5], b[5]) - max(a[3], b[3]))
        inter = ix * iy
        union = (a[4] - a[2]) * (a[5] - a[3]) + (b[4] - b[2]) * (b[5] - b[3]) - inter
        if union > 0 and (band - 1) * union < inter * 64 <= band * union:
            return h
    raise RuntimeError('no IoU edge pair found for band %d' % band)


def make_heads(kind, seed, cfg):
    rng = np.random.default_rng(seed)
    heads = blank(cfg, rng)
    nch = 5 + cfg.classes

    def put(hi, y, x, a, **kw):
        dr.plant(heads[hi], y, x, a, cfg, **kw)

    if kind == 'empty':
        pass
    elif kind == 'single':
        put(1, 3, 4, 1, logit_xy=(5, -7), logit_wh=(11, 4), obj=50, cls_idx=1, cls=50)
    elif kind == 'classes':
        put(0, 1, 2, 0, logit_wh=(0, 0), obj=60, cls_idx=0, cls=60)
        put(1, 4, 1, 2, logit_wh=(-8, 3), obj=60, cls_idx=1, cls=50)
        put(1, 0, 7, 1, logit_wh=(6, 6), obj=45, cls_idx=2, cls=45)
    elif kind == 'overlap_same':
        put(1, 3, 4, 1, logit_xy=(0, 0), logit_wh=(8, 8), obj=60, cls_idx=0, cls=60)
        put(1, 3, 4, 2, logit_xy=(4, 2), logit_wh=(2, 2), obj=45, cls_idx=0, cls=45)
        put(1, 3, 5, 0, logit_xy=(-30, 0), logit_wh=(12, 12), obj=50, cls_idx=0, cls=50)
    elif kind == 'overlap_diff':
        put(1, 3, 4, 1, logit_xy=(0, 0), logit_wh=(8, 8), obj=60, cls_idx=0, cls=60)
        put(1, 3, 4, 2, logit_xy=(4, 2), logit_wh=(2, 2), obj=45, cls_idx=2, cls=45)
    elif kind == 'ties':
        for (hi, y, x, a) in ((1, 0, 0, 0), (1, 5, 7, 2), (1, 2, 3, 1), (0, 1, 1, 0), (0, 2, 3, 2)):
            put(hi, y, x, a, logit_xy=(0, 0), logit_wh=(0, 0), obj=40, cls_idx=a % 3, cls=40)
    elif kind == 'cls_tie':
        dr.plant(heads[1], 2, 2, 0, cfg, obj=60, cls_idx=0, cls=40)
        heads[1][2, 2, 0 * 8 + 6] = 40                      # class 1 equals class 0: the first maximum (class 0) must win
        dr.plant(heads[1], 4, 5, 1, cfg, obj=60, cls_idx=1, cls=40)
        heads[1][4, 5, 1 * 8 + 7] = 40                      # classes 1 and 2 tie: class 1
        heads[1][4, 5, 1 * 8 + 5] = 40                      # all three tie: class 0
    elif kind == 'tie_overflow':
        cells = [(1, y, x, a) for y in range(6) for x in range(8) for a in range(3)]
        for idx in rng.choice(len(cells), size=44, replace=False):
            hi, y, x, a = cells[idx]
            dr.plant(heads[hi], y, x, a, cfg, logit_xy=(0, 0), logit_wh=(-20, -20), obj=40, cls_idx=int(idx % 3), cls=40)    # 44 equal scores, tiny boxes: no suppression
    elif kind == 'thr_edge':
        pairs = score_pairs(cfg)
        qo, qc = pairs[cfg.thr]
        dr.plant(heads[1], 1, 1, 0, cfg, logit_wh=(0, 0), obj=qo, cls_idx=0, cls=qc)           # score == THR: candidate
        below = max(s for s in pairs if s < cfg.thr)                                           # the largest score under the threshold that a logit pair produces
        qo2, qc2 = pairs[below]
        dr.plant(heads[1], 4, 6, 2, cfg, logit_wh=(0, 0), obj=qo2, cls_idx=1, cls=qc2)         # the largest score below THR: no candidate
    elif kind == 'min_tie':
        # 30 full-frame class-0 boxes (one survives the NMS), then two class-1 boxes with the lowest candidate score (a tie for the minimum) and a third class-1 box
        # with a higher score arrives with the candidate memory full: the FIRST lowest slot has to be replaced
        pairs = score_pairs(cfg)
        qo, qc = pairs[cfg.thr]
        for n in range(30):
            hi, y, x, a = 0, (n // 3) // 4, (n // 3) % 4, n % 3
            dr.plant(heads[hi], y, x, a, cfg, logit_xy=(0, 0), logit_wh=(60, 60), obj=int(rng.integers(40, 70)), cls_idx=0, cls=int(rng.integers(40, 70)))
        dr.plant(heads[0], 2, 2, 0, cfg, logit_xy=(-40, 0), logit_wh=(-20, -20), obj=qo, cls_idx=1, cls=qc)
        dr.plant(heads[0], 2, 2, 1, cfg, logit_xy=(40, 0), logit_wh=(-20, -20), obj=qo, cls_idx=1, cls=qc)
        dr.plant(heads[0], 2, 2, 2, cfg, logit_xy=(0, -40), logit_wh=(-20, -20), obj=45, cls_idx=1, cls=45)
    elif kind in ('full32', 'min_last'):
        # full32: 30 full-frame class-0 boxes + a low class-1 box (the 31st) + a higher class-1 box (the 32nd: the last free slot, no replacement may happen);
        # min_last: 31 cluster boxes + the low box in slot 31 (the LAST slot) + a higher box as the 33rd candidate, which has to replace exactly the low box
        pairs = score_pairs(cfg)
        qo, qc = pairs[cfg.thr]
        ncl, ilow, imid = (30, 30, 31) if kind == 'full32' else (31, 31, 32)
        for n in range(ncl):
            dr.plant(heads[0], (n // 3) // 4, (n // 3) % 4, n % 3, cfg, logit_xy=(0, 0), logit_wh=(60, 60), obj=int(rng.integers(40, 70)), cls_idx=0, cls=int(rng.integers(40, 70)))
        dr.plant(heads[0], (ilow // 3) // 4, (ilow // 3) % 4, ilow % 3, cfg, logit_xy=(-40, 0), logit_wh=(-20, -20), obj=qo, cls_idx=1, cls=qc)
        dr.plant(heads[0], (imid // 3) // 4, (imid // 3) % 4, imid % 3, cfg, logit_xy=(40, 0), logit_wh=(-20, -20), obj=45, cls_idx=1, cls=45)
    elif kind == 'clip_y720':
        # a box whose unclipped lower edge is exactly 720 frame pixels: the clip has to turn it into 719
        rng2 = np.random.default_rng(99)
        for _ in range(200000):
            hi, y, x, a = 1, int(rng2.integers(0, 6)), int(rng2.integers(0, 8)), int(rng2.integers(0, 3))
            xy = tuple(int(v) for v in rng2.integers(-40, 40, 2))
            wh = tuple(int(v) for v in rng2.integers(-10, 25, 2))
            h = [np.full((g[0], g[1], 24), -128, dtype=np.int8) for g in cfg.grid]
            dr.plant(h[hi], y, x, a, cfg, logit_xy=xy, logit_wh=wh, obj=60, cls_idx=0, cls=60)
            sx = dr.sig(xy[0]); sy = dr.sig(xy[1])
            cy = ((((y << 16) + sy) * cfg.stride[hi]) >> 12) - cfg.pad_top * 16
            bh = (cfg.anchors[hi][a][1] * dr.expq8(wh[1])) >> 4
            if ((cy + (bh >> 1)) * cfg.k) >> 4 == cfg.fh:
                heads = h
                break
        else:
            raise RuntimeError('no y == 720 box found')
    elif kind == 'iou_lo':
        heads = iou_edge_pair(cfg, cfg.iou_q6)
    elif kind == 'iou_hi':
        heads = iou_edge_pair(cfg, cfg.iou_q6 + 1)
    elif kind == 'border':
        put(1, 0, 0, 0, logit_xy=(-60, -60), logit_wh=(40, 40), obj=60, cls_idx=0, cls=60)
        put(1, 5, 7, 2, logit_xy=(60, 60), logit_wh=(60, 60), obj=60, cls_idx=1, cls=60)
        put(0, 0, 3, 1, logit_xy=(30, -50), logit_wh=(20, 20), obj=60, cls_idx=2, cls=60)
    elif kind == 'extremes':
        put(1, 2, 2, 0, logit_xy=(127, -128), logit_wh=(127, -128), obj=127, cls_idx=0, cls=127)
        put(1, 3, 3, 1, logit_xy=(-128, 127), logit_wh=(-128, 127), obj=127, cls_idx=1, cls=127)
        put(0, 1, 0, 2, logit_xy=(0, 0), logit_wh=(-128, -128), obj=127, cls_idx=2, cls=127)
    elif kind.startswith('dense'):
        n = int(kind[5:])
        cells = [(hi, y, x, a) for hi, (h, w) in enumerate(cfg.grid) for y in range(h) for x in range(w) for a in range(3)]
        for idx in rng.choice(len(cells), size=min(n, len(cells)), replace=False):
            hi, y, x, a = cells[idx]
            put(hi, y, x, a, logit_xy=tuple(int(v) for v in rng.integers(-40, 40, 2)), logit_wh=tuple(int(v) for v in rng.integers(-20, 30, 2)),
                obj=int(rng.integers(5, 70)), cls_idx=int(rng.integers(0, 3)), cls=int(rng.integers(5, 70)))
    elif kind == 'random':
        heads = [rng.integers(-128, 128, size=(h, w, 3 * nch)).astype(np.int8) for (h, w) in cfg.grid]
    elif kind == 'random_low':
        heads = [rng.integers(-128, 30, size=(h, w, 3 * nch)).astype(np.int8) for (h, w) in cfg.grid]
    else:
        raise ValueError(kind)
    return heads


CASES = [('empty', 'empty', 1), ('single', 'single', 2), ('classes', 'classes', 3), ('overlap_same', 'overlap_same', 4), ('overlap_diff', 'overlap_diff', 5),
         ('ties', 'ties', 6), ('border', 'border', 7), ('extremes', 'extremes', 8), ('dense12', 'dense12', 9), ('dense25', 'dense25', 10), ('dense40', 'dense40', 11),
         ('dense80', 'dense80', 12), ('random_a', 'random', 13), ('random_b', 'random', 14), ('random_low_a', 'random_low', 15), ('random_low_b', 'random_low', 16),
         ('dense20_b', 'dense20', 17), ('dense60_b', 'dense60', 18), ('cls_tie', 'cls_tie', 19), ('tie_overflow', 'tie_overflow', 20),
         ('thr_edge', 'thr_edge', 21), ('iou_lo', 'iou_lo', 22), ('iou_hi', 'iou_hi', 23),
         ('min_tie', 'min_tie', 24), ('full32', 'full32', 25), ('min_last', 'min_last', 26), ('clip_y720', 'clip_y720', 27)]


def write_case(prefix, kind, seed, cfg):
    heads = make_heads(kind, seed, cfg)
    res = dr.decode(heads, cfg)
    os.makedirs(os.path.dirname(prefix), exist_ok=True)
    with open(prefix + '_heads.hex', 'w') as f:
        for t in heads:
            for v in t.reshape(-1).view(np.uint8):
                f.write('%02X\n' % v)
    with open(prefix + '_exp.hex', 'w') as f:
        f.write('%d\n' % len(res))
        for (score, cls, x0, y0, x1, y1) in res:
            f.write('%015X\n' % ((cls << 58) | (score << 42) | (x0 << 31) | (y0 << 21) | (x1 << 10) | y1))
    return len(list(dr.cells(heads, cfg))), len(dr.collect(heads, cfg)), len(res)


def main():
    cfg = dr.Cfg()
    outdir = os.path.normpath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'logs_custom', 'yolo_vec', 'decode'))
    for (nm, kind, seed) in CASES:
        c, s, n = write_case(os.path.join(outdir, nm), kind, seed, cfg)
        print('%-14s candidates %3d  slots %2d  boxes %d' % (nm, c, s, n))


if __name__ == '__main__':
    main()
