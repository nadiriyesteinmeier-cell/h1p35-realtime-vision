#!/usr/bin/env python3
"""autolabel.py - first-pass labels for frames captured from the board (capture_uart.py) + a dataset in the train_yolo.py format, split by capture SESSION

Real images of the actual parts are what turns the synthetic-trained detector into a detector of those parts. Hand-labelling every frame is slow, so this script proposes
boxes from colour (HSV thresholds per class, connected components, minimum area) and draws them on review sheets; WRONG LABELS MUST BE FIXED OR THE FRAME DROPPED before
training (edit <session>/labels.json, or list the frame index in <session>/drop.json: {"drop": [..], "why": ..}). The colour rule is only a labelling aid - the network learns from the images, and its value over
the colour rule is shown on frames where the rule fails (shading, colour cast, similar-colour background, occlusion).

Usage:
  F:/yolo_env/Scripts/python.exe autolabel.py label --session F:/yolo_capture/session01                 -> labels.json + review/sheet_*.png
  F:/yolo_env/Scripts/python.exe autolabel.py label --session F:/yolo_capture/s02 --single 1           (one green object per frame: merged box)
  F:/yolo_env/Scripts/python.exe autolabel.py dataset --sessions s01 s02 s03 --val s04 --test s05 --out F:/yolo_data_real
Labels: [cls, cx, cy, w, h] in network pixels of the 128 x 96 map (image rows 12..83). Classes 0 red, 1 green, 2 blue (working definitions until the real parts are defined).
"""
import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw

RULES = {   # hue ranges in degrees, minimum saturation / value
    0: dict(h=[(345, 360), (0, 15)], s=0.40, v=0.20),
    1: dict(h=[(85, 160)], s=0.30, v=0.15),
    2: dict(h=[(195, 255)], s=0.35, v=0.15),
}


def rgb2hsv(img):
    x = img.astype(np.float64) / 255.0
    r, g, b = x[..., 0], x[..., 1], x[..., 2]
    mx, mn = x.max(-1), x.min(-1)
    d = mx - mn
    h = np.zeros_like(mx)
    m = d > 1e-6
    rr = m & (mx == r)
    gg = m & (mx == g) & ~rr
    bb = m & ~rr & ~gg
    h[rr] = (60 * ((g - b)[rr] / d[rr])) % 360
    h[gg] = 60 * ((b - r)[gg] / d[gg]) + 120
    h[bb] = 60 * ((r - g)[bb] / d[bb]) + 240
    s = np.where(mx > 0, d / np.maximum(mx, 1e-6), 0)
    return h, s, mx


def components(mask):
    """4-connected components -> list of (y0, x0, y1, x1, area)"""
    H, W = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    out = []
    for y in range(H):
        for x in range(W):
            if mask[y, x] and not seen[y, x]:
                stack = [(y, x)]
                seen[y, x] = True
                ys, xs = [], []
                while stack:
                    cy, cx = stack.pop()
                    ys.append(cy)
                    xs.append(cx)
                    for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                        if 0 <= ny < H and 0 <= nx < W and mask[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            stack.append((ny, nx))
                out.append((min(ys), min(xs), max(ys) + 1, max(xs) + 1, len(ys)))
    return out


def propose(net_img, min_area=6):
    img = net_img[12:84]
    h, s, v = rgb2hsv(img)
    labels = []
    for c, r in RULES.items():
        hm = np.zeros(h.shape, dtype=bool)
        for lo, hi in r['h']:
            hm |= (h >= lo) & (h < hi)
        m = hm & (s >= r['s']) & (v >= r['v'])
        for (y0, x0, y1, x1, area) in components(m):
            if area < min_area or (x1 - x0) < 2 or (y1 - y0) < 2:
                continue
            labels.append([c, (x0 + x1) / 2.0, (y0 + y1) / 2.0 + 12, float(x1 - x0), float(y1 - y0)])
    return labels


RELAX = {   # single-object sessions under backlight (camera looking up at a ceiling lamp): the wire frame and the foam turn into dark silhouettes
    0: RULES[0],
    1: dict(h=[(75, 185)], s=0.18, v=0.06),
    2: dict(h=[(190, 265)], s=0.18, v=0.06),
}


def label_map(mask):
    """4-connected labelling -> (label image, count)"""
    H, W = mask.shape
    lab = np.zeros((H, W), dtype=np.int32)
    n = 0
    for y in range(H):
        for x in range(W):
            if mask[y, x] and not lab[y, x]:
                n += 1
                lab[y, x] = n
                stack = [(y, x)]
                while stack:
                    cy, cx = stack.pop()
                    for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                        if 0 <= ny < H and 0 <= nx < W and mask[ny, nx] and not lab[ny, nx]:
                            lab[ny, nx] = n
                            stack.append((ny, nx))
    return lab, n


def open2(m):
    """erode then dilate with a 3 x 3 cross: removes one-pixel speckle and thin fringes"""
    e = m.copy()
    e[1:] &= m[:-1]; e[:-1] &= m[1:]; e[:, 1:] &= m[:, :-1]; e[:, :-1] &= m[:, 1:]
    d = e.copy()
    d[1:] |= e[:-1]; d[:-1] |= e[1:]; d[:, 1:] |= e[:, :-1]; d[:, :-1] |= e[:, 1:]
    return d


def propose_single(net_img, cls, rel=0.08, min_area=12, bg=None, fg_thr=40):
    """session with ONE object of a known class.
    With bg (median of empty frames, static camera): seeds = class-colour pixels that differ from the empty scene; the box covers every foreground region
    (non-skin pixels that differ from the empty scene) touching a seed. Backlit parts of the object lose their colour but still differ from the background.
    Without bg: union of the class-colour components, pieces smaller than rel x the largest dropped. A seed area under min_area means an empty frame."""
    img = net_img[12:84]
    h, s, v = rgb2hsv(img)
    r = RELAX[cls]
    hm = np.zeros(h.shape, dtype=bool)
    for lo, hi in r['h']:
        hm |= (h >= lo) & (h < hi)
    seed = hm & (s >= r['s']) & (v >= r['v'])
    if bg is not None:
        diff = np.abs(img.astype(np.float64) - bg).max(-1)
        seed &= diff > fg_thr
        if seed.sum() < min_area:
            return []
        skin = ((h < 50) | (h >= 330)) & (s > 0.10)
        if cls == 0:
            skin &= ~seed                # the red class shares hues with skin: keep its own seeds
        lab, _ = label_map(open2((diff > fg_thr - 5) & ~skin) | seed)
        ids = [i for i in np.unique(lab[seed]) if i > 0 and (lab == i).sum() >= min_area]
        if not ids:
            return []
        ys, xs = np.nonzero(np.isin(lab, ids))
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    else:
        comps = components(seed)
        if not comps or max(c[4] for c in comps) < min_area:
            return []
        big = max(c[4] for c in comps)
        keep = [c for c in comps if c[4] >= rel * big]
        y0, x0 = min(c[0] for c in keep), min(c[1] for c in keep)
        y1, x1 = max(c[2] for c in keep), max(c[3] for c in keep)
    return [[cls, (x0 + x1) / 2.0, (y0 + y1) / 2.0 + 12, float(x1 - x0), float(y1 - y0)]]


def class_mask(h, s, v, rule):
    m = np.zeros(h.shape, dtype=bool)
    for lo, hi in rule['h']:
        m |= (h >= lo) & (h < hi)
    return m & (s >= rule['s']) & (v >= rule['v'])


def union_box(mask, cls, rel=0.08, min_area=12):
    comps = components(mask)
    if not comps or max(c[4] for c in comps) < min_area:
        return []
    big = max(c[4] for c in comps)
    keep = [c for c in comps if c[4] >= rel * big]
    y0, x0 = min(c[0] for c in keep), min(c[1] for c in keep)
    y1, x1 = max(c[2] for c in keep), max(c[3] for c in keep)
    return [[cls, (x0 + x1) / 2.0, (y0 + y1) / 2.0 + 12, float(x1 - x0), float(y1 - y0)]]


def propose_multi(net_img, bg, min_area=12, fg_thr=40):
    """session with AT MOST ONE object per class, objects held apart: red and blue = union of their colour pieces (the foam is a clean colour, the red box
    is split by glare); green = foreground silhouette grown from green seeds, excluding skin, the other two classes (dilated) and the lamp (v > 0.9)"""
    img = net_img[12:84]
    h, s, v = rgb2hsv(img)
    out = []
    red, blue = class_mask(h, s, v, RULES[0]), class_mask(h, s, v, RELAX[2]) & (v < 0.8) & (s >= 0.25)   # not the bluish lamp glare through the wire frame
    out += union_box(red, 0, min_area=min_area)
    for b in union_box(blue, 2, min_area=min_area):  # the foam fills its box; glare through slots is sparse
        x0, x1 = int(b[1] - b[3] / 2), int(b[1] + b[3] / 2)
        y0, y1 = int(b[2] - b[4] / 2) - 12, int(b[2] + b[4] / 2) - 12
        if blue[y0:y1, x0:x1].mean() >= 0.3:
            out.append(b)
    diff = np.abs(img.astype(np.float64) - bg).max(-1)
    seed = class_mask(h, s, v, RELAX[1]) & (diff > fg_thr)
    if seed.sum() >= min_area:
        other = red | blue
        for _ in range(2):
            o = other.copy()
            o[1:] |= other[:-1]; o[:-1] |= other[1:]; o[:, 1:] |= other[:, :-1]; o[:, :-1] |= other[:, 1:]
            other = o
        skin = ((h < 50) | (h >= 330)) & (s > 0.10)
        lab, _ = label_map((open2((diff > fg_thr - 5) & ~skin & ~other & (v < 0.9)) | seed))
        ids = [i for i in np.unique(lab[seed]) if i > 0 and (lab == i).sum() >= min_area]
        if ids:
            ys, xs = np.nonzero(np.isin(lab, ids))
            y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
            out.append([1, (x0 + x1) / 2.0, (y0 + y1) / 2.0 + 12, float(x1 - x0), float(y1 - y0)])
    greens = [b for b in out if b[0] == 1]

    def inside(b, g):                    # fraction of box b covered by box g
        ix = min(b[1] + b[3] / 2, g[1] + g[3] / 2) - max(b[1] - b[3] / 2, g[1] - g[3] / 2)
        iy = min(b[2] + b[4] / 2, g[2] + g[4] / 2) - max(b[2] - b[4] / 2, g[2] - g[4] / 2)
        return max(ix, 0) * max(iy, 0) / max(b[3] * b[4], 1e-6)
    # lamp glare seen through the wire frame's slots has the foam's hue: a blue box lying inside a green box is that glare, not the foam
    return [b for b in out if not (b[0] == 2 and any(inside(b, g) >= 0.75 for g in greens))]


def sheet(imgs, labs, path, cols=6, scale=3):
    col = {0: (255, 60, 60), 1: (60, 255, 60), 2: (80, 140, 255)}
    tiles = []
    for im, lab in zip(imgs, labs):
        t = Image.fromarray(im).resize((128 * scale, 96 * scale), Image.NEAREST)
        d = ImageDraw.Draw(t)
        for (c, cx, cy, w, h) in lab:
            d.rectangle([(cx - w / 2) * scale, (cy - h / 2) * scale, (cx + w / 2) * scale, (cy + h / 2) * scale], outline=col[int(c)], width=2)
        tiles.append(t)
    rows = (len(tiles) + cols - 1) // cols
    S = Image.new('RGB', (cols * 128 * scale, rows * 96 * scale))
    for i, t in enumerate(tiles):
        S.paste(t, ((i % cols) * 128 * scale, (i // cols) * 96 * scale))
    S.save(path)


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest='cmd')
    a1 = sp.add_parser('label')
    a1.add_argument('--session', required=True)
    a1.add_argument('--single', type=int, default=None, help='session holds one object of this class (0 red, 1 green, 2 blue): one merged box per frame')
    a1.add_argument('--bg', type=int, default=0, help='with --single: the first N frames are empty, their median is the background')
    a1.add_argument('--multi', action='store_true', help='at most one object per class, held apart (needs --bg)')
    a1.add_argument('--bg-session', default=None, help='take the --bg empty frames from this session instead (same camera pose)')
    a2 = sp.add_parser('dataset')
    a2.add_argument('--sessions', nargs='+', required=True)
    a2.add_argument('--val', nargs='+', required=True)
    a2.add_argument('--test', nargs='+', required=True)
    a2.add_argument('--out', required=True)
    a = ap.parse_args()
    if a.cmd == 'label':
        frames = np.load(os.path.join(a.session, 'frames.npy'))
        src = np.load(os.path.join(a.bg_session, 'frames.npy')) if a.bg_session else frames
        bg = np.median(src[:a.bg, 12:84].astype(np.float64), 0) if a.bg else None
        if a.multi:
            labs = [propose_multi(f, bg) for f in frames]
        else:
            labs = [propose(f) if a.single is None else propose_single(f, a.single, bg=bg) for f in frames]
        json.dump(labs, open(os.path.join(a.session, 'labels.json'), 'w'))
        os.makedirs(os.path.join(a.session, 'review'), exist_ok=True)
        for k in range(0, len(frames), 36):
            sheet(frames[k:k + 36], labs[k:k + 36], os.path.join(a.session, 'review', 'sheet_%04d.png' % k))
        print('%d frames, %d proposed boxes -> %s/labels.json (CHECK the review sheets)' % (len(frames), sum(len(l) for l in labs), a.session))
    elif a.cmd == 'dataset':
        os.makedirs(a.out, exist_ok=True)
        for split, sess in (('train', a.sessions), ('val', a.val), ('test', a.test)):
            imgs, labs = [], []
            for s in sess:
                im = np.load(os.path.join(s, 'frames.npy'))
                lb = json.load(open(os.path.join(s, 'labels.json')))
                dp = os.path.join(s, 'drop.json')                 # frames rejected at review (wrong or partial boxes, missed objects)
                drop = set(json.load(open(dp))['drop']) if os.path.exists(dp) else set()
                keep = [i for i in range(len(lb)) if i not in drop]
                imgs.append(im[keep])
                labs += [lb[i] for i in keep]
            np.save(os.path.join(a.out, split + '_img.npy'), np.concatenate(imgs))
            json.dump(labs, open(os.path.join(a.out, split + '_lab.json'), 'w'))
            print('%-5s %d frames from %s' % (split, len(labs), sess))
    else:
        ap.print_help()


if __name__ == '__main__':
    main()
