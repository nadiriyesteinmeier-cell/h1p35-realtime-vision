#!/usr/bin/env python3
"""gen_lsc_table.py - lens-shading correction table for isp_color.v from a flat-field (white) and a dark capture of the board

    python tools/shade/gen_lsc_table.py <white log, AWB mode 1> <dark log, AWB mode 1> [--rtl-out DIR] [--deg 4]

Input: shade_capture.ps1 logs of the shade_diag UART report (16 x 9 cells of 80 x 80 pixels, per-cell R/G/B sums of the frame-buffer
read-out, AWB mode 1 = unity gains, no black-level subtraction). Steps:
  1. per-cell means of the last --keep reports, black level (dark capture, per channel) subtracted;
  2. per channel a 2-D polynomial of degree --deg in u = (x - 640) / 640, v = (y - 360) / 640 is fitted to the cell values at the cell
     centres (least squares): a smooth shading surface, robust to paper texture and noise;
  3. gain_c(x, y) = surface_c(640, 360) / surface_c(x, y): 1.0 at the image centre, > 1 where the channel is weaker (colour shading
     and vignetting together); the colour balance at the centre stays with the white balance;
  4. evaluated at the LSC nodes x = 64 i (i = 0..20), y = 64 j (j = 0..12; nodes past the image are extrapolated by the fit, they
     only weigh in the last 16 lines), clamped to [GMIN, GMAX], Q2.10 (1024 = 1.0).
Output: <rtl-out>/lsc_rom.v (module lsc_rom: 273 words {R, G, B} x 12 bit, synchronous read, address = 21 j + i) and
<rtl-out>/lsc_table.hex (same words, one per line, for the reference model), plus a printed fit report (residuals, gain ranges).
"""
import argparse
import hashlib
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shade_analyze import parse_reports, to_array  # noqa: E402

NX, NY, STEP = 21, 13, 64
GMIN, GMAX = 0.5, 3.0


def load(path, keep, cell_px):
    reps, bad = parse_reports(open(path, encoding='ascii', errors='replace').read(), cell_px)
    reps = [r for r in reps if r['mode'] == 1] or reps
    return np.mean([to_array(r, cell_px) for r in reps[-keep:]], axis=0)


def terms(u, v, deg):
    cols = []
    for d in range(deg + 1):
        for a in range(d + 1):
            cols.append((u ** (d - a)) * (v ** a))
    return np.stack(cols, axis=-1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('white')
    ap.add_argument('dark')
    ap.add_argument('--keep', type=int, default=10)
    ap.add_argument('--deg', type=int, default=4)
    ap.add_argument('--cell-pixels', type=int, default=6400)
    ap.add_argument('--rtl-out', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'logs_custom', 'lsc'))
    a = ap.parse_args()
    W = load(a.white, a.keep, a.cell_pixels)
    D = load(a.dark, a.keep, a.cell_pixels)
    gh, gw, _ = W.shape
    blk = D.reshape(-1, 3).mean(axis=0)
    S = W - blk
    yy, xx = np.mgrid[0:gh, 0:gw]
    xc = 40.0 + 80.0 * xx
    yc = 40.0 + 80.0 * yy
    A = terms((xc - 640) / 640.0, (yc - 360) / 640.0, a.deg).reshape(-1, terms(np.zeros(1), np.zeros(1), a.deg).shape[-1])
    ni, nj = np.meshgrid(np.arange(NX), np.arange(NY))
    An = terms((STEP * ni - 640) / 640.0, (STEP * nj - 360) / 640.0, a.deg)
    A0 = terms(np.zeros(1), np.zeros(1), a.deg)[0]
    words = np.zeros((NY, NX), dtype=np.int64)
    print('black level R G B: %.2f %.2f %.2f' % tuple(blk))
    gains = []
    for c, name in enumerate('RGB'):
        y = S[..., c].reshape(-1)
        coef, *_ = np.linalg.lstsq(A, y, rcond=None)
        fit = A @ coef
        rel = (y - fit) / fit
        surf_n = An @ coef
        g = (A0 @ coef) / surf_n
        g = np.clip(g, GMIN, GMAX)
        gains.append(g)
        print('%s: fit residual rms %.2f %% max %.2f %% | gain at nodes %.3f .. %.3f (centre node %.3f)' % (
            name, 100 * np.sqrt(np.mean(rel ** 2)), 100 * np.max(np.abs(rel)), g.min(), g.max(), g[6, 10]))
    q = [np.clip(np.round(g * 1024), 0, 4095).astype(np.int64) for g in gains]
    words = (q[0] << 24) | (q[1] << 12) | q[2]
    # what the correction does to the measured cells (nearest-node approximation is enough for a report)
    corr = np.zeros_like(S)
    for c in range(3):
        gi = np.interp(xc[0], STEP * np.arange(NX), np.arange(NX))
        gj = np.interp(yc[:, 0], STEP * np.arange(NY), np.arange(NY))
        from numpy import floor
        for j in range(gh):
            for i in range(gw):
                x0, y0 = int(floor(gi[i])), int(floor(gj[j]))
                fx, fy = gi[i] - x0, gj[j] - y0
                gg = gains[c]
                val = (gg[y0, x0] * (1 - fx) * (1 - fy) + gg[y0, min(x0 + 1, NX - 1)] * fx * (1 - fy) +
                       gg[min(y0 + 1, NY - 1), x0] * (1 - fx) * fy + gg[min(y0 + 1, NY - 1), min(x0 + 1, NX - 1)] * fx * fy)
                corr[j, i, c] = S[j, i, c] * val
    rg, bg = corr[..., 0] / corr[..., 1], corr[..., 2] / corr[..., 1]
    print('after correction (model, measured cells): R/G %.3f..%.3f (max/min %.3f), B/G %.3f..%.3f (max/min %.3f), G %.1f..%.1f (max/min %.3f)' % (
        rg.min(), rg.max(), rg.max() / rg.min(), bg.min(), bg.max(), bg.max() / bg.min(), corr[..., 1].min(), corr[..., 1].max(),
        corr[..., 1].max() / corr[..., 1].min()))
    out = os.path.normpath(a.rtl_out)
    os.makedirs(out, exist_ok=True)
    flat = words.reshape(-1)
    hexlines = ['%09X' % w for w in flat]
    open(os.path.join(out, 'lsc_table.hex'), 'w').write('\n'.join(hexlines) + '\n')
    src = hashlib.sha256(open(a.white, 'rb').read() + open(a.dark, 'rb').read()).hexdigest()[:16]
    lines = ['// lsc_rom.v - GENERATED by tools/shade/gen_lsc_table.py, do not edit by hand',
             '// lens-shading gains at the nodes x = 64 i (i = 0..20), y = 64 j (j = 0..12), word 21 j + i = {R[35:24], G[23:12], B[11:0]}, Q2.10',
             '// source: flat-field %s + dark %s (sha256 prefix of both logs %s), polynomial degree %d; synchronous read (1 clock)' % (
                 os.path.basename(a.white), os.path.basename(a.dark), src, a.deg),
             '',
             'module lsc_rom (',
             '    input  wire        clk,',
             '    input  wire [8:0]  addr,',
             '    output reg  [35:0] data',
             ');',
             '',
             '    (* rom_style = "bram" *) reg [35:0] mem [0:511];',
             '',
             '    // every word written explicitly with <= (TD ignores a for-loop fill: "net mem does not have a driver"); unused words = 1.0',
             '    initial begin',
             ]
    for k in range(512):
        w = int(flat[k]) if k < len(flat) else 0x400400400
        lines.append('        mem[%d] <= 36\'h%09X;' % (k, w))
    lines += ['    end', '', '    always @(posedge clk) data <= mem[addr];', '', 'endmodule', '']
    open(os.path.join(out, 'lsc_rom.v'), 'w').write('\n'.join(lines))
    print('written:', os.path.join(out, 'lsc_rom.v'), os.path.join(out, 'lsc_table.hex'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
