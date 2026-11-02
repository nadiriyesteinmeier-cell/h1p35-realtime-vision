#!/usr/bin/env python3
"""isp_color_ref.py - integer reference model of rtl_custom/isp_color.v and generator of the expectation for tb_custom/tb_isp_color.v

    python tools/shade/isp_color_ref.py --table logs_custom/lsc/lsc_table.hex --out logs_custom/isp_color_vec

Writes into --out:
  exp_beats.txt   one 96-bit output word (24 hex digits) per output beat, frames in order (what the testbench must see on O_tdata)
  exp_frames.txt  per frame: mode, the gains it is processed with (R G B, decimal), the closed-loop gains after it (R G B) and the
                  output statistics of the frame (sums of the first pixel of every beat, R G B)
  schedule.txt    per frame: mode and manual gains R G B (the testbench reads it to drive I_mode / I_man_*)
The test pictures are defined by pix() below and by the same formula in tb_isp_color.v (keep them identical).
Model (see the header of isp_color.v): black level, lens-shading gain per beat from the node table, eff = min(65535, gain * lsc >> 10),
out = min(255, eff * max(0, in - blk) >> 12); closed loop er = min(65535, gain * TARGET * beats / sum), est = er * GAIN_MAX / max(er) when
max(er) > GAIN_MAX (ratios kept), est >= GAIN_MIN, auto = (gain + est + 1) >> 1.
"""
import argparse
import os
import sys

import numpy as np

W, H, BPL = 1280, 720, 320
BLK = (18, 19, 17)
TARGET = 110
GAIN_MIN, GAIN_MAX = 1024, 32768
NX, NY = 21, 13
V_LO, V_HI, N_MIN = 4, 250, 2304

# frame schedule: (mode, man_r, man_g, man_b); mode 0 AUTO, 1 OFF, 2/3 MAN
SCHEDULE = [
    (0, 4096, 4096, 4096),
    (0, 4096, 4096, 4096),
    (2, 5000, 3800, 6100),
    (1, 4096, 4096, 4096),
    (0, 4096, 4096, 4096),
    (3, 16384, 1024, 65535),
    (0, 4096, 4096, 4096),
    (0, 4096, 4096, 4096),
    (0, 4096, 4096, 4096),
    (0, 4096, 4096, 4096),
    (0, 4096, 4096, 4096),
    (0, 4096, 4096, 4096),
    (0, 4096, 4096, 4096),
    (2, 4096, 4096, 4096),                                      # frame 13: manual 1.0 so that B (raw 238..245) is not saturated
    (0, 4096, 4096, 4096),
]


def pix(f):
    """picture of frame f: arrays R, G, B of shape (H, W), int64 (identical formula in tb_isp_color.v)"""
    y, x = np.mgrid[0:H, 0:W].astype(np.int64)
    base = ((x >> 2) + (y >> 1) + f * 37) & 255
    r = (base * 3 + (x & 7) * 5 + 11 * f) & 255
    g = (base + (y & 15) * 3 + 23) & 255
    b = (255 - base + ((x + y) & 31)) & 255
    if f == 4:                                                  # dark frame: tests the gain ceiling
        r, g, b = r & 15, g & 31, b & 7
    if f == 6:                                                  # bright frame with saturated areas
        r, g, b = r | 0xC0, g | 0x80, b | 0xE0
    if f == 7:                                                  # dim, unequal channels: the estimates are over the limit by different amounts
        r, g, b = (r >> 4) + 18, (g >> 3) + 19, (b >> 2) + 17    # R darkest
    if f == 8:
        r, g, b = (r >> 2) + 18, (g >> 3) + 19, (b >> 4) + 17    # B darkest
    if f == 9:
        r, g, b = (r >> 3) + 18, (g >> 5) + 19, (b >> 2) + 17    # G darkest
    if f == 11:                                                 # almost black: fewer than N_MIN valid beats -> the gains are kept
        r, g, b = (r & 15) + 16, (g & 3) + 19, (b & 15) + 15
        g = np.where((x == 0) & (y < 8), 40, g)
    if f == 13:                                                 # R at the black level (sum 0 -> er 65535), B bright but valid:
        r, g, b = (r & 1) + 17, (g & 63) + 40, (b & 7) + 238     # the ratio limit takes est_B below GAIN_MIN -> the floor acts
    return r, g, b


def load_table(path):
    words = [int(l, 16) for l in open(path) if l.strip()]
    assert len(words) == NX * NY, len(words)
    t = np.array(words, dtype=np.int64).reshape(NY, NX)
    return np.stack([(t >> 24) & 4095, (t >> 12) & 4095, t & 4095], axis=-1)   # (NY, NX, 3)


def lsc_frame(T):
    """per beat lsc (H, BPL, 3)"""
    y = np.arange(H)
    j, fy = y >> 6, y & 63
    T0 = T[j]                      # (H, NX, 3)
    T1 = T[j + 1]
    L = T0 + (((T1 - T0) * fy[:, None, None]) >> 6)          # floor shift = Verilog >>> on the signed product
    b = np.arange(BPL)
    s, k = b >> 4, b & 15
    Ls = L[:, s, :]
    Ls1 = L[:, np.minimum(s + 1, NX - 1), :]
    return (16 * Ls + k[None, :, None] * (Ls1 - Ls)) >> 4


def clampg(q):
    if q > 65535 or q > GAIN_MAX:
        return GAIN_MAX
    if q < GAIN_MIN:
        return GAIN_MIN
    return q


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--table', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--gray-sh', type=int, default=0, help='GRAY_SH of the RTL: 0 off, k: a beat counts only if its first output pixel has |R-G|, |B-G| <= G >> k')
    ap.add_argument('--init', type=int, nargs=3, default=[4096, 4096, 4096], help='INIT_R / INIT_G / INIT_B (automatic gains after reset)')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    T = load_table(a.table)
    LSC = lsc_frame(T)
    auto = list(a.init)
    last_sums = [1, 1, 1]                                       # the RTL keeps the statistics of the last frame it used
    fb = open(os.path.join(a.out, 'exp_beats.txt'), 'w')
    ff = open(os.path.join(a.out, 'exp_frames.txt'), 'w')
    fs = open(os.path.join(a.out, 'schedule.txt'), 'w')
    for f, (mode, mr, mg, mb) in enumerate(SCHEDULE):
        fs.write('%d %d %d %d\n' % (mode, mr, mg, mb))
        raw = (mode == 1)
        if mode >= 2:
            g = [mr, mg, mb]
        elif raw:
            g = [4096, 4096, 4096]
        else:
            g = list(auto)
        chans = pix(f)
        outs = []
        for c in range(3):
            lsc = np.full((H, BPL), 1024, dtype=np.int64) if raw else LSC[..., c]
            eff = np.minimum(65535, (g[c] * lsc) >> 10)                       # (H, BPL)
            effp = np.repeat(eff, 4, axis=1)                                  # (H, W)
            p = chans[c]
            pb = p if raw else np.maximum(0, p - BLK[c])
            prod = effp * pb
            outs.append(np.where(prod >= (1 << 20), 255, prod >> 12))
        R, G, B = outs
        # beats: pixel k of a beat at [24k +: 24] = {R, G, B}; pixel 0 is the first pixel of the beat (x = 4b)
        word = np.zeros((H, BPL), dtype=object)
        lines = []
        pix24 = (R << 16) | (G << 8) | B                                      # (H, W)
        p4 = pix24.reshape(H, BPL, 4)
        for y in range(H):
            row = p4[y]
            for bb in range(BPL):
                w = int(row[bb, 3]) << 72 | int(row[bb, 2]) << 48 | int(row[bb, 1]) << 24 | int(row[bb, 0])
                lines.append('%024X' % w)
        fb.write('\n'.join(lines) + '\n')
        r0, g0, b0 = chans[0][:, 0::4], chans[1][:, 0::4], chans[2][:, 0::4]          # raw input, first pixel of every beat
        valid = (g0 >= BLK[1] + V_LO) & (r0 < V_HI) & (g0 < V_HI) & (b0 < V_HI)
        if a.gray_sh > 0:                                                     # grey gate on the first OUTPUT pixel of the beat
            R0, G0, B0 = R[:, 0::4], G[:, 0::4], B[:, 0::4]
            tol = G0 >> a.gray_sh
            valid &= (R0 + tol >= G0) & (R0 <= G0 + tol) & (B0 + tol >= G0) & (B0 <= G0 + tol)
        n = int(valid.sum())
        sums = [int(R[:, 0::4][valid].sum()), int(G[:, 0::4][valid].sum()), int(B[:, 0::4][valid].sum())]
        if n < N_MIN:
            ff.write('%d %d %d %d %d %d %d %d %d %d' % (mode, g[0], g[1], g[2], auto[0], auto[1], auto[2], last_sums[0], last_sums[1], last_sums[2]) + chr(10))
            print('frame %d mode %d gains %s valid %d < N_MIN: auto kept %s' % (f, mode, g, n, auto))
            continue
        TN = TARGET * n
        last_sums = list(sums)
        er = [0xFFFF if sums[c] == 0 else min(0xFFFF, (g[c] * TN) // sums[c]) for c in range(3)]
        m = max(er)
        est = [(er[c] * GAIN_MAX) // m if m > GAIN_MAX else er[c] for c in range(3)]
        if min(est) < GAIN_MIN:
            print('frame %d: est %s below GAIN_MIN before the floor' % (f, est))
        est = [max(GAIN_MIN, e) for e in est]
        auto = [(g[c] + est[c] + 1) >> 1 for c in range(3)]
        ff.write('%d %d %d %d %d %d %d %d %d %d\n' % (mode, g[0], g[1], g[2], auto[0], auto[1], auto[2], sums[0], sums[1], sums[2]))
        print('frame %d mode %d gains %s sums %s -> auto %s' % (f, mode, g, sums, auto))
    fb.close(); ff.close(); fs.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
