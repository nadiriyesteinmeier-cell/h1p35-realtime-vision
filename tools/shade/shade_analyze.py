#!/usr/bin/env python3
"""shade_analyze.py - evaluate the flat-field reports printed by the shade diagnostic build (rtl_custom/shade_report.py format)

Usage:
    python shade_analyze.py <log.txt> [--out-dir DIR] [--cell-pixels 6400] [--black]
    python shade_analyze.py --selftest

The log holds repeated reports   HDR,<frame>,<awb mode>,<grid w>,<grid h>,<cell w>  /  C<row><col>,<R>,<G>,<B> x (w*h)  /  END,<checksum>
(hex, the sums are per-cell sums of 8-bit values; mean = sum / (cell_w * cell_h)). Reports that are incomplete, out of order or whose
checksum fails are dropped (and counted). For every AWB mode that occurs, the LAST --keep reports are averaged and summarized:

  * mean R, G, B of the centre cells and of the edge ring, corner means, luminance fall-off (corner / centre),
  * R/G and B/G at centre, edge ring and four corners (and relative to the centre), the spread (max/min over the image),
  * vertical asymmetry: mean R/G and B/G of the top two cell rows versus the bottom two cell rows (a running-gain AWB shows up here),
  * the radial profile of R/G, B/G and G (cells grouped by normalized distance from the image centre).
With --black the file is treated as a dark capture (lens covered): the per-channel black level is reported instead of ratios.
It writes <name>_mode<m>.png (colour-coded maps of R/G, B/G and G) and <name>_summary.json next to the log (or into --out-dir).
Only numpy and OpenCV (cv2) are needed; nothing here changes any setting of the board.
"""
import argparse
import json
import os
import sys

import numpy as np

try:
    import cv2
except Exception:                                   # pragma: no cover
    cv2 = None


def parse_reports(text, expect_cell_px=None):
    reports = []
    bad = 0
    cur = None
    for raw in text.splitlines():
        ln = raw.strip()
        if ln.startswith('HDR,'):
            if cur is not None:
                bad += 1
            f = ln.split(',')
            try:
                cur = {'frame': int(f[1], 16), 'mode': int(f[2], 16), 'gw': int(f[3], 16), 'gh': int(f[4], 16), 'cw': int(f[5], 16),
                       'cells': {}, 'chk': 0}
            except Exception:
                cur = None
                bad += 1
        elif ln.startswith('C') and cur is not None:
            try:
                row = int(ln[1:3], 16)
                col = int(ln[3:5], 16)
                parts = ln[5:].lstrip(',').split(',')
                r, g, b = (int(x, 16) for x in parts[:3])
                if len(parts) != 3 or (row, col) in cur['cells']:
                    raise ValueError
                cur['cells'][(row, col)] = (r, g, b)
                cur['chk'] = (cur['chk'] + (r & 0xFFFF) + (g & 0xFFFF) + (b & 0xFFFF)) & 0xFFFF
            except Exception:
                bad += 1
                cur = None
        elif ln.startswith('END,') and cur is not None:
            try:
                chk = int(ln[4:8], 16)
            except Exception:
                chk = -1
            ok = (len(cur['cells']) == cur['gw'] * cur['gh']) and chk == cur['chk']
            if ok:
                reports.append(cur)
            else:
                bad += 1
            cur = None
    if cur is not None:
        bad += 1
    return reports, bad


def to_array(rep, cell_px):
    gh, gw = rep['gh'], rep['gw']
    a = np.zeros((gh, gw, 3), dtype=np.float64)
    for (r, c), v in rep['cells'].items():
        a[r, c, :] = np.array(v, dtype=np.float64) / cell_px
    return a


def ring_mask(gh, gw, width=1):
    m = np.zeros((gh, gw), dtype=bool)
    m[:width, :] = True
    m[-width:, :] = True
    m[:, :width] = True
    m[:, -width:] = True
    return m


def centre_mask(gh, gw, frac=0.25):
    ch, cw = max(1, int(round(gh * frac))), max(1, int(round(gw * frac)))
    r0, c0 = (gh - ch) // 2, (gw - cw) // 2
    m = np.zeros((gh, gw), dtype=bool)
    m[r0:r0 + ch, c0:c0 + cw] = True
    return m


def summarize(a, black=False):
    gh, gw, _ = a.shape
    R, G, B = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    cm = centre_mask(gh, gw)
    rm = ring_mask(gh, gw)
    out = {'grid': [gw, gh]}
    if black:
        out['black_level_mean_rgb'] = [float(R.mean()), float(G.mean()), float(B.mean())]
        out['black_level_centre_rgb'] = [float(R[cm].mean()), float(G[cm].mean()), float(B[cm].mean())]
        out['black_level_edge_rgb'] = [float(R[rm].mean()), float(G[rm].mean()), float(B[rm].mean())]
        out['black_level_max_cell_rgb'] = [float(R.max()), float(G.max()), float(B.max())]
        return out
    eps = 1e-6
    rg = R / np.maximum(G, eps)
    bg = B / np.maximum(G, eps)
    lum = (77 * R + 150 * G + 29 * B) / 256.0

    def corner(arr, k=1):
        return float(np.mean([arr[:k, :k].mean(), arr[:k, -k:].mean(), arr[-k:, :k].mean(), arr[-k:, -k:].mean()]))

    out['mean_centre_rgb'] = [float(R[cm].mean()), float(G[cm].mean()), float(B[cm].mean())]
    out['mean_edge_ring_rgb'] = [float(R[rm].mean()), float(G[rm].mean()), float(B[rm].mean())]
    out['corner_mean_rgb'] = [corner(R), corner(G), corner(B)]
    out['luminance_centre'] = float(lum[cm].mean())
    out['luminance_edge_over_centre'] = float(lum[rm].mean() / max(lum[cm].mean(), eps))
    out['luminance_corner_over_centre'] = corner(lum) / max(float(lum[cm].mean()), eps)
    out['R_over_G'] = {'centre': float(rg[cm].mean()), 'edge': float(rg[rm].mean()), 'corners': corner(rg), 'min': float(rg.min()), 'max': float(rg.max())}
    out['B_over_G'] = {'centre': float(bg[cm].mean()), 'edge': float(bg[rm].mean()), 'corners': corner(bg), 'min': float(bg.min()), 'max': float(bg.max())}
    out['R_over_G']['edge_over_centre'] = out['R_over_G']['edge'] / max(out['R_over_G']['centre'], eps)
    out['B_over_G']['edge_over_centre'] = out['B_over_G']['edge'] / max(out['B_over_G']['centre'], eps)
    # vertical asymmetry (top two rows vs bottom two rows of cells)
    k = min(2, gh // 2)
    out['vertical'] = {
        'RG_top': float(rg[:k, :].mean()), 'RG_bottom': float(rg[-k:, :].mean()),
        'BG_top': float(bg[:k, :].mean()), 'BG_bottom': float(bg[-k:, :].mean()),
        'RG_bottom_over_top': float(rg[-k:, :].mean() / max(rg[:k, :].mean(), eps)),
        'BG_bottom_over_top': float(bg[-k:, :].mean() / max(bg[:k, :].mean(), eps)),
    }
    # horizontal asymmetry for comparison (left vs right, same width)
    kc = min(2, gw // 2)
    out['horizontal'] = {
        'RG_left': float(rg[:, :kc].mean()), 'RG_right': float(rg[:, -kc:].mean()),
        'RG_right_over_left': float(rg[:, -kc:].mean() / max(rg[:, :kc].mean(), eps)),
    }
    # radial profile: normalized distance of the cell centre from the image centre (corner = 1.0)
    yy, xx = np.mgrid[0:gh, 0:gw]
    d = np.hypot((yy - (gh - 1) / 2.0) / ((gh - 1) / 2.0 or 1), (xx - (gw - 1) / 2.0) / ((gw - 1) / 2.0 or 1)) / np.sqrt(2.0)
    prof = []
    for lo, hi in [(0.0, 0.2), (0.2, 0.4), (0.4, 0.6), (0.6, 0.8), (0.8, 1.01)]:
        m = (d >= lo) & (d < hi)
        if m.any():
            prof.append({'r': [lo, min(hi, 1.0)], 'RG': float(rg[m].mean()), 'BG': float(bg[m].mean()), 'G': float(G[m].mean()), 'n': int(m.sum())})
    out['radial'] = prof
    return out


def verdict(s):
    """plain-language hints, NOT a diagnosis by themselves"""
    hints = []
    rg = s['R_over_G']['edge_over_centre']
    bg = s['B_over_G']['edge_over_centre']
    lum = s['luminance_corner_over_centre']
    if rg > 1.08:
        hints.append('R/G is %.0f %% higher at the edge than at the centre: red edge cast (lens / sensor colour shading or IR leakage)' % ((rg - 1) * 100))
    if rg < 0.92:
        hints.append('R/G is %.0f %% lower at the edge than at the centre: cyan/green edge cast' % ((1 - rg) * 100))
    if bg > 1.08:
        hints.append('B/G is %.0f %% higher at the edge than at the centre: blue edge cast' % ((bg - 1) * 100))
    if bg < 0.92:
        hints.append('B/G is %.0f %% lower at the edge than at the centre' % ((1 - bg) * 100))
    if lum < 0.8:
        hints.append('corner luminance is only %.0f %% of the centre: vignetting' % (lum * 100))
    v = s['vertical']
    if abs(v['RG_bottom_over_top'] - 1) > 0.08 or abs(v['BG_bottom_over_top'] - 1) > 0.08:
        hints.append('top and bottom rows differ (R/G bottom/top %.2f, B/G bottom/top %.2f): a gain that changes inside the frame (running AWB) or an uneven target'
                     % (v['RG_bottom_over_top'], v['BG_bottom_over_top']))
    if not hints:
        hints.append('no strong spatial colour or brightness variation found at the thresholds used (8 %% colour ratio, 20 %% luminance)')
    return hints


def render(a, path, black=False):
    if cv2 is None:
        return False
    gh, gw, _ = a.shape
    eps = 1e-6
    maps = []
    for name, m in (('R/G', a[:, :, 0] / np.maximum(a[:, :, 1], eps)), ('B/G', a[:, :, 2] / np.maximum(a[:, :, 1], eps)), ('G', a[:, :, 1])):
        lo, hi = float(m.min()), float(m.max())
        n = ((m - lo) / max(hi - lo, eps) * 255).astype(np.uint8)
        c = cv2.applyColorMap(cv2.resize(n, (gw * 40, gh * 40), interpolation=cv2.INTER_NEAREST), cv2.COLORMAP_JET)
        cv2.putText(c, '%s %.3f..%.3f' % (name, lo, hi), (6, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
        maps.append(c)
    cv2.imwrite(path, np.hstack(maps))
    return True


def make_synthetic_log(mode_params, cell_px=6400, gw=16, gh=9, reports_per_mode=3, break_one=False):
    """a log with the same format as the board prints, from a modelled shading (for the self-test)"""
    lines = []
    fno = 0
    for mode, (rg_edge, bg_edge, lum_corner, vert) in mode_params.items():
        for _ in range(reports_per_mode):
            cells = {}
            chk = 0
            for r in range(gh):
                for c in range(gw):
                    dy = (r - (gh - 1) / 2) / ((gh - 1) / 2)
                    dx = (c - (gw - 1) / 2) / ((gw - 1) / 2)
                    d = min(1.0, np.hypot(dx, dy) / np.sqrt(2))
                    g = 150.0 * (1 - (1 - lum_corner) * d ** 2)
                    rr = g * (1 + (rg_edge - 1) * d ** 2) * (1 + vert * dy)
                    bb = g * (1 + (bg_edge - 1) * d ** 2)
                    vals = [int(round(v * cell_px)) for v in (rr, g, bb)]
                    cells[(r, c)] = vals
                    chk = (chk + sum(v & 0xFFFF for v in vals)) & 0xFFFF
            lines.append('HDR,%02X,%X,%02X,%02X,%02X' % (fno & 255, mode, gw, gh, 80))
            for (r, c), v in sorted(cells.items()):
                lines.append('C%02X%02X,%06X,%06X,%06X' % (r, c, v[0], v[1], v[2]))
            lines.append('END,%04X' % (chk ^ (1 if break_one and fno == 0 else 0)))
            fno += 1
    return '\n'.join(lines) + '\n'


def selftest():
    log = make_synthetic_log({0: (1.25, 1.0, 0.7, 0.10), 2: (1.20, 1.0, 0.7, 0.0)}, break_one=True)
    reps, bad = parse_reports(log)
    assert bad == 1 and len(reps) == 5, (bad, len(reps))              # the first report has a broken checksum
    modes = sorted({r['mode'] for r in reps})
    assert modes == [0, 2], modes
    s0 = summarize(np.mean([to_array(r, 6400) for r in reps if r['mode'] == 0], axis=0))
    s2 = summarize(np.mean([to_array(r, 6400) for r in reps if r['mode'] == 2], axis=0))
    assert abs(s0['R_over_G']['edge_over_centre'] - 1.2) < 0.08, s0['R_over_G']
    assert abs(s2['B_over_G']['edge_over_centre'] - 1.0) < 0.02, s2['B_over_G']
    assert s0['vertical']['RG_bottom_over_top'] > 1.1, s0['vertical']       # the modelled running-gain drift
    assert abs(s2['vertical']['RG_bottom_over_top'] - 1.0) < 0.02, s2['vertical']
    assert any('red edge cast' in h for h in verdict(s0))
    dark = to_array(parse_reports(make_synthetic_log({1: (1.0, 1.0, 1.0, 0.0)}, cell_px=6400))[0][0], 6400)
    assert summarize(dark, black=True)['black_level_mean_rgb'][1] > 100
    print('selftest: PASS (parser, checksum rejection, ratios, vertical asymmetry, hints)')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('log', nargs='?')
    ap.add_argument('--out-dir')
    ap.add_argument('--cell-pixels', type=int, default=6400)
    ap.add_argument('--keep', type=int, default=3, help='average the last N valid reports of every mode')
    ap.add_argument('--black', action='store_true', help='the capture was taken with the lens covered: report the black level')
    ap.add_argument('--selftest', action='store_true')
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0
    if not args.log:
        ap.error('log file required')
    text = open(args.log, 'r', errors='replace').read()
    reps, bad = parse_reports(text)
    print('valid reports: %d, dropped (incomplete / bad checksum / out of order): %d' % (len(reps), bad))
    if not reps:
        return 1
    out_dir = args.out_dir or os.path.dirname(os.path.abspath(args.log))
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.splitext(os.path.basename(args.log))[0]
    summary = {}
    for mode in sorted({r['mode'] for r in reps}):
        sel = [r for r in reps if r['mode'] == mode][-args.keep:]
        a = np.mean([to_array(r, args.cell_pixels) for r in sel], axis=0)
        s = summarize(a, black=args.black)
        s['reports_averaged'] = len(sel)
        summary['mode%d' % mode] = s
        print('\n=== AWB mode %d (%d reports averaged) ===' % (mode, len(sel)))
        if args.black:
            print('black level (mean R,G,B of all cells): %.2f %.2f %.2f   centre %.2f %.2f %.2f   edge %.2f %.2f %.2f   max cell %.2f %.2f %.2f' % (
                *s['black_level_mean_rgb'], *s['black_level_centre_rgb'], *s['black_level_edge_rgb'], *s['black_level_max_cell_rgb']))
        else:
            print('centre RGB %.1f %.1f %.1f | edge ring RGB %.1f %.1f %.1f | corner RGB %.1f %.1f %.1f' % (
                *s['mean_centre_rgb'], *s['mean_edge_ring_rgb'], *s['corner_mean_rgb']))
            print('luminance edge/centre %.2f, corner/centre %.2f' % (s['luminance_edge_over_centre'], s['luminance_corner_over_centre']))
            print('R/G centre %.3f edge %.3f corners %.3f (edge/centre %.3f, min %.3f max %.3f)' % (
                s['R_over_G']['centre'], s['R_over_G']['edge'], s['R_over_G']['corners'], s['R_over_G']['edge_over_centre'], s['R_over_G']['min'], s['R_over_G']['max']))
            print('B/G centre %.3f edge %.3f corners %.3f (edge/centre %.3f, min %.3f max %.3f)' % (
                s['B_over_G']['centre'], s['B_over_G']['edge'], s['B_over_G']['corners'], s['B_over_G']['edge_over_centre'], s['B_over_G']['min'], s['B_over_G']['max']))
            v = s['vertical']
            print('top vs bottom rows: R/G %.3f -> %.3f (x%.3f), B/G %.3f -> %.3f (x%.3f)' % (v['RG_top'], v['RG_bottom'], v['RG_bottom_over_top'], v['BG_top'], v['BG_bottom'], v['BG_bottom_over_top']))
            print('left vs right columns: R/G x%.3f' % s['horizontal']['RG_right_over_left'])
            for p in s['radial']:
                print('  radius %.1f-%.1f  R/G %.3f  B/G %.3f  G %.1f  (%d cells)' % (p['r'][0], p['r'][1], p['RG'], p['BG'], p['G'], p['n']))
            for h in verdict(s):
                print('  hint:', h)
        png = os.path.join(out_dir, '%s_mode%d.png' % (base, mode))
        if render(a, png, args.black):
            print('  map written:', png)
    with open(os.path.join(out_dir, base + '_summary.json'), 'w', encoding='utf-8') as f:
        json.dump(summary, f, indent=1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
