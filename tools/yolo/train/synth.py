#!/usr/bin/env python3
"""synth.py - synthetic training images for the PH1P35 detector: red / green / blue parts on cluttered backgrounds, in the exact input format of the board

Why synthetic: there are no real part images yet. A detector trained on these images makes the whole chain real (trained weights -> int8 -> ROM -> FPGA inference -> boxes);
it is NOT a substitute for real images of the actual parts: fine-tune on frames captured from the board (yolo_top dataset mode, tools/yolo/train/capture_uart.py) before
any accuracy claim about real parts.

Format = what yolo_box_down.v writes: the 1280 x 720 frame averaged over 10 x 10 blocks -> 128 x 72, placed 12 rows below the top of a 128 x 96 map whose letterbox rows are
mid-grey (int8 0 = pixel 128). Images are rendered at SS x (256 x 144) and box-averaged SS x SS (the board averages 10 x 10 of a real image - both are area averages).

Content: low-saturation backgrounds (gradients, large surfaces, texture, lines, shadows), distractor objects in non-target colours (white, black, grey, brown, yellow,
low-saturation tints), 0..8 target objects (rectangles, rotated boxes, ellipses, polygons, rings, L-brackets, cylinders) in red / green / blue hues with shading, highlights,
occlusion; global brightness / contrast / colour-gain jitter, the radial "centre green / edges red" cast observed on the board camera, blur and sensor noise.
Labels: class (0 red, 1 green, 2 blue) and the box of the VISIBLE part, in network pixels of the 128 x 96 map.

Usage: python synth.py --out F:/yolo_data --train 24000 --val 2000 --test 2000      (writes <split>_img.npy uint8 [N, 96, 128, 3] and <split>_lab.npy / .json)
"""
import argparse
import json
import math
import os

import numpy as np

SS = 2                       # supersampling factor (2: about 90 ms per image; 4 is 4x slower for no visible gain at 128 x 72)
IW, IH = 128, 72             # averaged image
NW, NH = 128, 96             # network input
PAD_TOP = 12
CLASSES = ['red', 'green', 'blue']
HUE = {0: (-14.0, 14.0), 1: (95.0, 150.0), 2: (205.0, 245.0)}


def hsv2rgb(h, s, v):
    """h in degrees (any range), s, v in 0..1 (numpy broadcasting) -> r, g, b in 0..1"""
    h = np.mod(h, 360.0) / 60.0
    c = v * s
    x = c * (1 - np.abs(np.mod(h, 2) - 1))
    m = v - c
    z = np.zeros_like(h)
    conds = [(h < 1), (h >= 1) & (h < 2), (h >= 2) & (h < 3), (h >= 3) & (h < 4), (h >= 4) & (h < 5), (h >= 5)]
    rs = [c, x, z, z, x, c]
    gs = [x, c, c, x, z, z]
    bs = [z, z, x, c, c, x]
    r = np.select(conds, rs) + m
    g = np.select(conds, gs) + m
    b = np.select(conds, bs) + m
    return r, g, b


class Renderer(object):
    def __init__(self, seed):
        self.rng = np.random.default_rng(seed)
        self.W, self.H = IW * SS, IH * SS
        yy, xx = np.mgrid[0:self.H, 0:self.W]
        self.xx = (xx + 0.5) / SS            # coordinates in averaged-image pixels
        self.yy = (yy + 0.5) / SS

    # ------------------------------------------------------------------ shape masks (averaged-image pixel units)
    def shape_mask(self, kind, cx, cy, size, ang, aspect):
        x = self.xx - cx
        y = self.yy - cy
        ca, sa = math.cos(ang), math.sin(ang)
        u = x * ca + y * sa
        v = -x * sa + y * ca
        a = size / 2.0
        b = a * aspect
        if kind == 'rect':
            return (np.abs(u) <= a) & (np.abs(v) <= b)
        if kind == 'ellipse':
            return (u / a) ** 2 + (v / b) ** 2 <= 1.0
        if kind == 'ring':
            r = (u / a) ** 2 + (v / b) ** 2
            return (r <= 1.0) & (r >= 0.35)
        if kind == 'lbracket':
            return ((np.abs(u) <= a) & (v >= b * 0.2) & (v <= b)) | ((u >= a * 0.3) & (u <= a) & (np.abs(v) <= b))
        if kind == 'cylinder':
            body = (np.abs(u) <= a) & (np.abs(v) <= b * 0.8)
            cap = ((u - a) / (a * 0.25 + 1e-6)) ** 2 + (v / (b * 0.8)) ** 2 <= 1.0
            return body | cap
        if kind == 'poly':
            n = int(self.rng.integers(3, 7))
            angs = np.sort(self.rng.uniform(0, 2 * math.pi, n))
            rad = self.rng.uniform(0.55, 1.0, n) * a
            px = rad * np.cos(angs)
            py = rad * np.sin(angs) * aspect
            m = np.ones_like(u, dtype=bool)
            # convex hull of points sorted by angle around the centre: inside test against every edge (the polygon is star-shaped and convex enough)
            for i in range(n):
                x0, y0, x1, y1 = px[i], py[i], px[(i + 1) % n], py[(i + 1) % n]
                m &= ((x1 - x0) * (v - y0) - (y1 - y0) * (u - x0)) >= 0
            return m
        raise ValueError(kind)

    # ------------------------------------------------------------------ background
    def background(self):
        rng = self.rng
        H, W = self.H, self.W
        base_h = rng.uniform(0, 360)
        base_s = rng.uniform(0.0, 0.22)
        base_v = rng.uniform(0.25, 0.9)
        gx, gy = rng.uniform(-0.4, 0.4, 2)
        v = base_v + gx * (self.xx / IW - 0.5) + gy * (self.yy / IH - 0.5)
        h = np.full((H, W), base_h)
        s = np.full((H, W), base_s)
        # large surfaces (table edge, paper, cloth)
        for _ in range(int(rng.integers(0, 4))):
            kind = rng.choice(['rect', 'ellipse', 'poly'])
            m = self.shape_mask(kind, rng.uniform(0, IW), rng.uniform(0, IH), rng.uniform(30, 160), rng.uniform(0, math.pi), rng.uniform(0.3, 1.0))
            h = np.where(m, rng.uniform(0, 360), h)
            s = np.where(m, rng.uniform(0.0, 0.25), s)
            v = np.where(m, rng.uniform(0.2, 0.95), v)
        # lines / seams
        for _ in range(int(rng.integers(0, 5))):
            ang = rng.uniform(0, math.pi)
            d = (self.xx - rng.uniform(0, IW)) * math.sin(ang) - (self.yy - rng.uniform(0, IH)) * math.cos(ang)
            m = np.abs(d) < rng.uniform(0.2, 1.2)
            v = np.where(m, v * rng.uniform(0.3, 1.4), v)
        # texture
        if rng.random() < 0.7:
            amp = rng.uniform(0.01, 0.08)
            sc = int(rng.integers(2, 12))
            coarse = rng.normal(0, 1, (H // (sc * SS) + 2, W // (sc * SS) + 2))
            tex = np.kron(coarse, np.ones((sc * SS, sc * SS)))[:H, :W]
            v = v + amp * tex
        return h, s, np.clip(v, 0.02, 1.0)

    # ------------------------------------------------------------------ one image
    def render(self, n_max=8):
        rng = self.rng
        h, s, v = self.background()
        r, g, b = hsv2rgb(h, s, v)
        img = np.stack([r, g, b], axis=-1)
        owner = np.full((self.H, self.W), -1, dtype=np.int32)     # which target object is visible at each subpixel (-1: none)
        objs = []
        kinds = ['rect', 'rect', 'ellipse', 'poly', 'ring', 'lbracket', 'cylinder']
        n_t = int(rng.integers(0, n_max + 1)) if rng.random() > 0.08 else 0
        n_d = int(rng.integers(0, 5))
        order = [('t', i) for i in range(n_t)] + [('d', i) for i in range(n_d)]
        rng.shuffle(order)
        for typ, _ in order:
            kind = str(rng.choice(kinds))
            size = float(np.exp(rng.uniform(math.log(5.0), math.log(48.0))))
            cx, cy = rng.uniform(-0.1 * IW, 1.1 * IW), rng.uniform(-0.1 * IH, 1.1 * IH)
            m = self.shape_mask(kind, cx, cy, size, rng.uniform(0, math.pi), rng.uniform(0.35, 1.0))
            if not m.any():
                continue
            if typ == 't':
                cls = int(rng.integers(0, 3))
                lo, hi = HUE[cls]
                hue = rng.uniform(lo, hi)
                sat = rng.uniform(0.45, 1.0)
                val = rng.uniform(0.3, 1.0)
            else:
                cls = -1
                pick = rng.random()
                if pick < 0.25:      # white / grey / black
                    hue, sat, val = rng.uniform(0, 360), rng.uniform(0, 0.12), rng.choice([rng.uniform(0.05, 0.25), rng.uniform(0.4, 0.7), rng.uniform(0.8, 1.0)])
                elif pick < 0.5:     # yellow / orange-yellow
                    hue, sat, val = rng.uniform(45, 65), rng.uniform(0.4, 1.0), rng.uniform(0.5, 1.0)
                elif pick < 0.7:     # brown / wood
                    hue, sat, val = rng.uniform(20, 40), rng.uniform(0.3, 0.7), rng.uniform(0.2, 0.6)
                else:                # weak tints of any hue (not a part)
                    hue, sat, val = rng.uniform(0, 360), rng.uniform(0.05, 0.3), rng.uniform(0.3, 0.9)
            # shading across the object + highlight
            ang = rng.uniform(0, 2 * math.pi)
            shade = 1.0 + rng.uniform(0.0, 0.5) * ((self.xx - cx) * math.cos(ang) + (self.yy - cy) * math.sin(ang)) / max(size, 1.0)
            vv = np.clip(val * shade, 0.02, 1.0)
            ro, go, bo = hsv2rgb(np.full_like(vv, hue), np.full_like(vv, sat), vv)
            if rng.random() < 0.5:
                hx, hy = cx + rng.uniform(-0.3, 0.3) * size, cy + rng.uniform(-0.3, 0.3) * size
                hl = np.exp(-(((self.xx - hx) ** 2 + (self.yy - hy) ** 2) / (2 * (0.08 * size + 0.5) ** 2))) * rng.uniform(0.1, 0.5)
                ro, go, bo = ro + hl, go + hl, bo + hl
            obj = np.stack([ro, go, bo], axis=-1)
            img = np.where(m[..., None], obj, img)
            if typ == 't':
                idx = len(objs)
                objs.append(dict(cls=cls, full=int(m.sum())))
                owner = np.where(m, idx, owner)
            else:
                owner = np.where(m, -1, owner)          # a distractor in front occludes targets
        # global photometric effects
        img = img * rng.uniform(0.6, 1.35) + rng.uniform(-0.08, 0.08)
        img = img * rng.uniform(0.85, 1.15, 3)[None, None, :]
        if rng.random() < 0.7:                             # radial cast: centre green / edges red (observed on the board camera)
            rad = np.sqrt(((self.xx - IW / 2) / (IW / 2)) ** 2 + ((self.yy - IH / 2) / (IH / 2)) ** 2) / math.sqrt(2)
            k = rng.uniform(0.0, 0.35)
            img[..., 0] *= 1 + k * rad ** 2
            img[..., 1] *= 1 + k * 0.5 * (1 - rad ** 2)
        img = np.clip(img, 0, 1)
        # area average 4x4 -> 128 x 72 (the board: 10 x 10)
        small = img.reshape(IH, SS, IW, SS, 3).mean(axis=(1, 3))
        if rng.random() < 0.3:                             # slight defocus
            k = np.array([0.25, 0.5, 0.25])
            small = np.apply_along_axis(lambda c: np.convolve(np.pad(c, 1, mode='edge'), k, 'valid'), 0, small)
            small = np.apply_along_axis(lambda c: np.convolve(np.pad(c, 1, mode='edge'), k, 'valid'), 1, small)
        small = small + rng.normal(0, rng.uniform(0.0, 0.025), small.shape)
        small8 = np.clip(np.round(small * 255), 0, 255).astype(np.uint8)
        net = np.full((NH, NW, 3), 128, dtype=np.uint8)
        net[PAD_TOP:PAD_TOP + IH] = small8
        # labels from the visible subpixels
        labels = []
        for idx, o in enumerate(objs):
            vis = owner == idx
            cnt = int(vis.sum())
            if cnt < 0.3 * o['full'] or cnt < 9 * SS * SS * 0.5:
                continue
            ys, xs = np.nonzero(vis)
            x0, x1 = xs.min() / SS, (xs.max() + 1) / SS
            y0, y1 = ys.min() / SS + PAD_TOP, (ys.max() + 1) / SS + PAD_TOP
            if x1 - x0 < 2.0 or y1 - y0 < 2.0:
                continue
            labels.append([o['cls'], (x0 + x1) / 2, (y0 + y1) / 2, x1 - x0, y1 - y0])
        return net, labels


def _chunk(args):
    seed, n = args
    r = Renderer(seed)
    imgs = np.zeros((n, NH, NW, 3), dtype=np.uint8)
    labs = []
    for i in range(n):
        imgs[i], lab = r.render()
        labs.append(lab)
    return imgs, labs


def make_split(out, name, n, seed, procs=16, chunk=250):
    import multiprocessing as mp
    jobs = [(seed * 1000 + k, min(chunk, n - k * chunk)) for k in range((n + chunk - 1) // chunk)]
    with mp.Pool(procs) as pool:
        res = pool.map(_chunk, jobs)
    imgs = np.concatenate([r[0] for r in res], axis=0)
    labs = [l for r in res for l in r[1]]
    np.save(os.path.join(out, name + '_img.npy'), imgs)
    with open(os.path.join(out, name + '_lab.json'), 'w') as f:
        json.dump(labs, f)
    return sum(len(l) for l in labs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='F:/yolo_data')
    ap.add_argument('--train', type=int, default=24000)
    ap.add_argument('--val', type=int, default=2000)
    ap.add_argument('--test', type=int, default=2000)
    ap.add_argument('--part', type=int, default=-1, help='internal: render one chunk of the training split (parallel generation)')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for name, n, seed in (('val', a.val, 1001), ('test', a.test, 2002), ('train', a.train, 3003)):
        nobj = make_split(a.out, name, n, seed)
        print('%-5s %6d images, %6d objects' % (name, n, nobj), flush=True)


if __name__ == '__main__':
    main()
