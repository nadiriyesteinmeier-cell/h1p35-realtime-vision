#!/usr/bin/env python3
"""gen_aux_vectors.py - test vectors for tb_custom/tb_yolo_aux.v (rtl_custom/yolo_aux_core.v) from the integer reference qref.py

The operators: copy (route / concat), nearest-neighbour upsample x2, 2x2 max-pool stride 2, 2x2 max-pool stride 1 (right / bottom edge replicated).
Every case stores the source map INSIDE a larger memory image whose other bytes are random (a read at a wrong address returns a different value),
optionally with a one-pixel zero-border around the map (padded layout of a map that a 3x3 convolution reads) and with a channel offset in a wider channel
stride (a concat destination). The destination image is pre-filled with 0x55 by the testbench; the expected image has the reference output at the stored
positions and 0x55 everywhere else, so a stray or a missing write is a mismatch.
Files per case: <prefix>_cfg.txt, <prefix>_in.hex, <prefix>_exp.hex (format: see tb_yolo_aux.v).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qref


def make_src(rng, hs, ws, cs, kind):
    if kind == 'extreme':
        return rng.choice(np.array([-128, 127], dtype=np.int8), size=(hs, ws, cs))
    if kind == 'ties':
        return rng.integers(-2, 3, size=(hs, ws, cs)).astype(np.int8)
    if kind == 'neg':
        return rng.integers(-128, 0, size=(hs, ws, cs)).astype(np.int8)
    if kind == 'min':
        return np.full((hs, ws, cs), -128, dtype=np.int8)
    return rng.integers(-128, 128, size=(hs, ws, cs)).astype(np.int8)


def make_fill_case(name, kind, hs, ws, cs):
    """mode 4 (fill with 0). kind 'rows': rows 0 and H+1 of a padded map H x W x C (hs, ws, cs = H, W, C); 'cols': columns 0 and W+1 of rows 1..H;
    'plain': a dense hs x ws x cs block at address 0"""
    n = (hs + 2) * (ws + 2) * cs if kind != 'plain' else hs * ws * cs
    img = np.full(n, 0x55, dtype=np.uint8)
    if kind == 'rows':
        h_o, w_o, c_o = 2, ws + 2, cs
        base, row, pix = 0, (hs + 1) * (ws + 2) * cs, cs
    elif kind == 'cols':
        h_o, w_o, c_o = hs, 2, cs
        base, row, pix = (ws + 2) * cs, (ws + 2) * cs, (ws + 1) * cs
    else:
        h_o, w_o, c_o = hs, ws, cs
        base, row, pix = 0, ws * cs, cs
    for y in range(h_o):
        for x in range(w_o):
            a = base + y * row + x * pix
            img[a:a + c_o] = 0
    d = os.path.dirname(name)
    os.makedirs(d, exist_ok=True)
    with open(name + '_cfg.txt', 'w') as f:
        f.write('%d %d %d %d %d %d %d %d %d %d %d %d\n' % (4, h_o, w_o, c_o, 0, 0, 0, base, row, pix, 64, img.size))
    with open(name + '_in.hex', 'w') as f:                    # non-zero bytes: the engine reads them while it fills and must ignore them
        for i in range(64):
            f.write('%02X\n' % (0xA0 + (i % 0x40)))
    with open(name + '_exp.hex', 'w') as f:
        for v in img:
            f.write('%02X\n' % v)
    return dict(name=os.path.basename(name), mode=4, src='-', out='%dx%dx%d' % (h_o, w_o, c_o))


def make_case(name, mode, hs, ws, cs, p_src, ct_src, off_src, q_dst, ct_dst, off_dst, kind, seed):
    if mode == 4:
        return make_fill_case(name, kind, hs, ws, cs)
    rng = np.random.default_rng(seed)
    x = make_src(rng, hs, ws, cs, kind)
    if mode == 0:
        out = x.copy()
    elif mode == 1:
        out = qref.upsample2(x)
    elif mode == 2:
        out = qref.maxpool2(x, 2)
    else:
        out = qref.maxpool2(x, 1)
    ho, wo, co = out.shape
    # source memory: random bytes everywhere, the map in the interior block
    full = rng.integers(-128, 128, size=(hs + 2 * p_src, ws + 2 * p_src, ct_src)).astype(np.int8)
    full[p_src:p_src + hs, p_src:p_src + ws, off_src:off_src + cs] = x
    in_row = (ws + 2 * p_src) * ct_src
    in_base = (p_src * (ws + 2 * p_src) + p_src) * ct_src + off_src
    # destination image
    dst = np.full((ho + 2 * q_dst, wo + 2 * q_dst, ct_dst), 0x55, dtype=np.uint8)
    dst[q_dst:q_dst + ho, q_dst:q_dst + wo, off_dst:off_dst + co] = out.view(np.uint8)
    out_row = (wo + 2 * q_dst) * ct_dst
    out_base = (q_dst * (wo + 2 * q_dst) + q_dst) * ct_dst + off_dst
    d = os.path.dirname(name)
    os.makedirs(d, exist_ok=True)
    with open(name + '_cfg.txt', 'w') as f:
        f.write('%d %d %d %d %d %d %d %d %d %d %d %d\n' % (mode, ho, wo, co, in_base, in_row, ct_src, out_base, out_row, ct_dst, full.size, dst.size))
    with open(name + '_in.hex', 'w') as f:
        for v in full.reshape(-1).view(np.uint8):
            f.write('%02X\n' % v)
    with open(name + '_exp.hex', 'w') as f:
        for v in dst.reshape(-1):
            f.write('%02X\n' % v)
    return dict(name=os.path.basename(name), mode=mode, src='%dx%dx%d' % (hs, ws, cs), out='%dx%dx%d' % (ho, wo, co))


def all_cases():
    c = []
    # name, mode, hs, ws, cs, p_src, ct_src, off_src, q_dst, ct_dst, off_dst, kind, seed
    c.append(('copy_plain',        0, 4, 6, 5, 0, 5, 0, 0, 5, 0, 'random', 1))
    c.append(('copy_src_padded',   0, 4, 6, 5, 1, 5, 0, 0, 5, 0, 'random', 2))
    c.append(('copy_concat_hi',    0, 4, 6, 5, 1, 5, 0, 0, 12, 7, 'random', 3))
    c.append(('copy_concat_lo',    0, 3, 5, 8, 0, 8, 0, 1, 20, 0, 'random', 4))
    c.append(('copy_chan_slice',   0, 3, 5, 6, 1, 16, 8, 1, 16, 2, 'random', 5))
    c.append(('copy_one',          0, 1, 1, 1, 0, 1, 0, 0, 1, 0, 'random', 6))
    c.append(('up_plain',          1, 3, 5, 8, 0, 8, 0, 0, 8, 0, 'random', 11))
    c.append(('up_into_cat',       1, 3, 5, 32, 0, 32, 0, 1, 96, 0, 'random', 12))
    c.append(('up_src_slice',      1, 3, 5, 8, 1, 16, 8, 0, 8, 0, 'random', 13))
    c.append(('up_one',            1, 1, 1, 3, 0, 3, 0, 0, 3, 0, 'random', 14))
    c.append(('up_row',            1, 1, 7, 2, 0, 2, 0, 0, 2, 0, 'random', 15))
    c.append(('pool2_plain',       2, 8, 12, 16, 0, 16, 0, 0, 16, 0, 'random', 21))
    c.append(('pool2_route_cat',   2, 6, 10, 64, 1, 96, 32, 1, 64, 0, 'random', 22))
    c.append(('pool2_c1',          2, 4, 4, 1, 0, 1, 0, 0, 1, 0, 'random', 23))
    c.append(('pool2_extreme',     2, 6, 8, 5, 0, 5, 0, 0, 5, 0, 'extreme', 24))
    c.append(('pool2_ties',        2, 6, 8, 5, 0, 5, 0, 0, 5, 0, 'ties', 25))
    c.append(('pool2_neg',         2, 6, 8, 5, 0, 5, 0, 0, 5, 0, 'neg', 26))
    c.append(('pool2_min',         2, 4, 4, 3, 0, 3, 0, 0, 3, 0, 'min', 27))
    c.append(('pool2_big',         2, 24, 40, 8, 0, 8, 0, 1, 8, 0, 'random', 28))
    c.append(('pool1_plain',       3, 3, 5, 12, 0, 12, 0, 0, 12, 0, 'random', 31))
    c.append(('pool1_padded',      3, 3, 5, 12, 1, 20, 4, 1, 12, 0, 'random', 32))
    c.append(('pool1_1x1',         3, 1, 1, 4, 0, 4, 0, 0, 4, 0, 'random', 33))
    c.append(('pool1_row',         3, 1, 7, 3, 0, 3, 0, 0, 3, 0, 'random', 34))
    c.append(('pool1_col',         3, 6, 1, 3, 0, 3, 0, 0, 3, 0, 'random', 35))
    c.append(('pool1_ties',        3, 4, 5, 6, 0, 6, 0, 0, 6, 0, 'ties', 36))
    c.append(('pool1_neg',         3, 4, 5, 6, 0, 6, 0, 0, 6, 0, 'neg', 37))
    c.append(('fill_rows',         4, 6, 10, 8, 0, 0, 0, 0, 0, 0, 'rows', 41))
    c.append(('fill_cols',         4, 6, 10, 8, 0, 0, 0, 0, 0, 0, 'cols', 42))
    c.append(('fill_rows_c1',      4, 1, 1, 1, 0, 0, 0, 0, 0, 0, 'rows', 43))
    c.append(('fill_cols_c1',      4, 1, 1, 1, 0, 0, 0, 0, 0, 0, 'cols', 44))
    c.append(('fill_plain',        4, 3, 5, 4, 0, 0, 0, 0, 0, 0, 'plain', 45))
    return c


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'logs_custom', 'yolo_vec', 'auxops')
    outdir = os.path.normpath(outdir)
    for cs in all_cases():
        r = make_case(os.path.join(outdir, cs[0]), *cs[1:])
        print('%-18s mode %d  %-10s -> %s' % (r['name'], r['mode'], r['src'], r['out']))
    print('vectors written to', outdir)


if __name__ == '__main__':
    main()
