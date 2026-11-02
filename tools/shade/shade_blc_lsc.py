#!/usr/bin/env python3
"""shade_blc_lsc.py - flat-field analysis with the black level subtracted, and the lens-shading gain table it implies

    python tools/shade/shade_blc_lsc.py <white log, AWB mode 1> <dark log, AWB mode 1> [--out-dir DIR]

Both logs come from shade_capture.ps1 (shade_diag UART report: per-cell R/G/B sums of the frame-buffer read-out, 16 x 9 cells of
80 x 80 pixels). The last --keep reports of each log are averaged. Printed:
  * black level per channel (dark capture), and its spread over the cells;
  * white field minus black: R/G, B/G, G by radius (centre ... corners), edge/centre ratios, vignetting;
  * the per-cell, per-channel gain that would make the white field flat and neutral after black subtraction
    (gain_c(cell) = target / (white_c(cell) - black_c), target = centre G), as the range an LSC table would need.
Writes <out-dir>/blc_lsc_summary.json and a map PNG (R/G, B/G, G after black subtraction).
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shade_analyze import parse_reports, to_array  # noqa: E402


def load(path, keep, cell_px):
    reps, bad = parse_reports(open(path, encoding='ascii', errors='replace').read(), cell_px)
    reps = [r for r in reps if r['mode'] == 1] or reps
    use = reps[-keep:]
    return np.mean([to_array(r, cell_px) for r in use], axis=0), len(reps), bad


def radial(gh, gw):
    yy, xx = np.mgrid[0:gh, 0:gw]
    cy, cx = (gh - 1) / 2.0, (gw - 1) / 2.0
    r = np.sqrt(((yy - cy) / cy) ** 2 + ((xx - cx) / cx) ** 2) / np.sqrt(2.0)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('white')
    ap.add_argument('dark')
    ap.add_argument('--keep', type=int, default=10)
    ap.add_argument('--cell-pixels', type=int, default=6400)
    ap.add_argument('--out-dir', default=None)
    a = ap.parse_args()
    W, nw, bw = load(a.white, a.keep, a.cell_pixels)       # shape (gh, gw, 3), means per cell
    D, nd, bd = load(a.dark, a.keep, a.cell_pixels)
    gh, gw, _ = W.shape
    blk = D.reshape(-1, 3).mean(axis=0)
    print('reports: white %d (bad %d), dark %d (bad %d); averaged the last %d of each' % (nw, bw, nd, bd, a.keep))
    print('black level R G B: %.2f %.2f %.2f  (cell range: R %.2f..%.2f  G %.2f..%.2f  B %.2f..%.2f)' % (
        blk[0], blk[1], blk[2], D[..., 0].min(), D[..., 0].max(), D[..., 1].min(), D[..., 1].max(), D[..., 2].min(), D[..., 2].max()))
    S = W - blk                                               # white minus black, per cell and channel
    rg = S[..., 0] / S[..., 1]
    bg = S[..., 2] / S[..., 1]
    g = S[..., 1]
    r = radial(gh, gw)
    rows = []
    for lo, hi in [(0, .2), (.2, .4), (.4, .6), (.6, .8), (.8, 1.01)]:
        m = (r >= lo) & (r < hi)
        rows.append({'radius': [lo, min(hi, 1.0)], 'cells': int(m.sum()), 'RG': float(rg[m].mean()), 'BG': float(bg[m].mean()), 'G': float(g[m].mean())})
        print('  radius %.1f-%.1f  R/G %.3f  B/G %.3f  G %5.1f  (%d cells)' % (lo, min(hi, 1.0), rows[-1]['RG'], rows[-1]['BG'], rows[-1]['G'], m.sum()))
    c = (r < 0.2)
    corner = np.zeros_like(r, dtype=bool)
    corner[0, 0] = corner[0, -1] = corner[-1, 0] = corner[-1, -1] = True
    summ = {
        'black_rgb': [float(x) for x in blk],
        'white_minus_black_centre_rgb': [float(S[..., k][c].mean()) for k in range(3)],
        'RG_centre': float(rg[c].mean()), 'RG_corners': float(rg[corner].mean()), 'RG_max_over_min': float(rg.max() / rg.min()),
        'BG_centre': float(bg[c].mean()), 'BG_corners': float(bg[corner].mean()), 'BG_max_over_min': float(bg.max() / bg.min()),
        'G_corner_over_centre': float(g[corner].mean() / g[c].mean()),
        'radial': rows,
    }
    target = g[c].mean()
    gains = target / S                                        # per channel gain to a flat neutral field at the centre G level
    summ['lsc_gain_range'] = {k: [float(gains[..., i].min()), float(gains[..., i].max())] for i, k in enumerate('RGB')}
    print('R/G centre %.3f corners %.3f (max/min over cells %.3f) | B/G centre %.3f corners %.3f (max/min %.3f) | G corner/centre %.3f' % (
        summ['RG_centre'], summ['RG_corners'], summ['RG_max_over_min'], summ['BG_centre'], summ['BG_corners'], summ['BG_max_over_min'],
        summ['G_corner_over_centre']))
    print('gain to a flat neutral field (target = centre G after black %.1f): R %.2f..%.2f  G %.2f..%.2f  B %.2f..%.2f' % (
        target, *summ['lsc_gain_range']['R'], *summ['lsc_gain_range']['G'], *summ['lsc_gain_range']['B']))
    out = a.out_dir or os.path.dirname(os.path.abspath(a.white))
    os.makedirs(out, exist_ok=True)
    json.dump(summ, open(os.path.join(out, 'blc_lsc_summary.json'), 'w'), indent=1)
    try:
        from PIL import Image, ImageDraw
        def cm(x):
            x = np.clip(x, 0, 1)
            return np.stack([np.clip(1.5 - abs(4 * x - 3), 0, 1), np.clip(1.5 - abs(4 * x - 2), 0, 1), np.clip(1.5 - abs(4 * x - 1), 0, 1)], -1)
        tiles = []
        for name, m in [('R/G', rg), ('B/G', bg), ('G', g)]:
            n = (m - m.min()) / max(1e-9, m.max() - m.min())
            im = Image.fromarray((cm(n) * 255).astype(np.uint8)).resize((gw * 40, gh * 40), Image.NEAREST)
            ImageDraw.Draw(im).text((4, 2), '%s %.3f..%.3f (black subtracted)' % (name, m.min(), m.max()), fill=(255, 255, 255))
            tiles.append(im)
        canvas = Image.new('RGB', (sum(t.width for t in tiles), tiles[0].height))
        x = 0
        for t in tiles:
            canvas.paste(t, (x, 0)); x += t.width
        canvas.save(os.path.join(out, 'blc_lsc_map.png'))
        print('map written:', os.path.join(out, 'blc_lsc_map.png'))
    except ImportError:
        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
