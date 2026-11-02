#!/usr/bin/env python3
"""gen_conv_vectors.py - test vectors for tb_custom/tb_yolo_conv.v (rtl_custom/yolo_conv_core.v) from the integer reference qref.py

For every case it writes, next to <prefix>:
  <prefix>_cfg.txt   the layer configuration and the sizes of the memory images (decimal, one line)
  <prefix>_act.hex   input activation memory (one int8 per line, the padded map for 3x3 layers)
  <prefix>_wt.hex    weight words (2*lanes hex digits per line, lane 0 in the least significant byte)
  <prefix>_pm.hex    per output channel {bias, M, S} (14 hex digits per line)
  <prefix>_exp.hex   the expected content of the output memory: the reference output at the stored positions, 0x55 everywhere else
                     (the testbench pre-fills the output memory with 0x55, so a stray write is caught as well as a wrong value)
The cases cover: first-layer-like 3x3 with cin = 3, cout not a multiple of the lane count (partial last tile), 1x1 head without activation,
deep accumulation with extreme int8 values, saturation of the requantiser, tiny cin * k * k (pipeline stall logic), non-padded and padded
output storage, M / S corner values, leaky ReLU on and off.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qref


def choose_requant(acc_abs_max, cout, rng, target, force_shift=None):
    """per-channel (mult, shift) such that |acc| * mult / 2^shift is about `target` at the largest accumulator value"""
    mult = rng.integers(1 << 14, 1 << 16, size=cout).astype(np.int64)
    shift = np.zeros(cout, dtype=np.int64)
    for c in range(cout):
        a = max(1, int(acc_abs_max[c]))
        s = 0
        while s < 47 and (a * int(mult[c])) / float(1 << s) > target:
            s += 1
        shift[c] = s
    if force_shift is not None:
        shift[:] = force_shift
    return mult.astype(np.int64), shift


def make_case(name, h, w, cin, cout, k, act, lanes, seed, kind='random', out_pad=False, target=90, force_shift=None, mult_fixed=None, pool=False):
    rng = np.random.default_rng(seed)
    if kind == 'extreme':
        x = rng.choice(np.array([-128, 127], dtype=np.int8), size=(h, w, cin))
        wt = rng.choice(np.array([-128, 127, -127, 126], dtype=np.int8), size=(cout, cin, k, k))
    elif kind == 'sparse':
        x = np.where(rng.random((h, w, cin)) < 0.15, rng.integers(-128, 128, size=(h, w, cin)), 0).astype(np.int8)
        wt = np.where(rng.random((cout, cin, k, k)) < 0.3, rng.integers(-128, 128, size=(cout, cin, k, k)), 0).astype(np.int8)
    elif kind == 'clamp_edges':
        # acc = x in {-1, 0, 1} (weight 1, one tap); with M = 2^14, S = 14 the requantiser is the identity, so y = x + bias hits the
        # saturation edges 127 / 128 and -128 / -129 exactly (off-by-one thresholds of the clamp cannot hide)
        assert cin == 1 and k == 1
        x = ((np.arange(h * w * cin) % 3) - 1).astype(np.int8).reshape(h, w, cin)
        wt = np.ones((cout, cin, k, k), dtype=np.int8)
    else:
        x = rng.integers(-128, 128, size=(h, w, cin)).astype(np.int8)
        wt = rng.integers(-128, 128, size=(cout, cin, k, k)).astype(np.int8)
    # accumulator range per channel (exact, from the reference)
    zeros = np.zeros(cout, dtype=np.int64)
    xp = qref.padded_hwc(x, k // 2).astype(np.int64)
    accmax = np.zeros(cout, dtype=np.int64)
    acc = np.zeros((h, w, cout), dtype=np.int64)
    for ky in range(k):
        for kx in range(k):
            acc += np.tensordot(xp[ky:ky + h, kx:kx + w, :], wt[:, :, ky, kx].astype(np.int64), axes=([2], [1]))
    accmax = np.abs(acc).reshape(-1, cout).max(axis=0)
    bias = rng.integers(-(1 << 18), 1 << 18, size=cout).astype(np.int64)
    if kind == 'bias_big':
        bias = rng.integers(-(1 << 29), 1 << 29, size=cout).astype(np.int64)
    if kind == 'clamp_edges':
        edge_bias = [126, 127, 128, 129, 130, -127, -128, -129, -130, -131]
        bias = np.array([edge_bias[c % len(edge_bias)] for c in range(cout)], dtype=np.int64)
    mult, shift = choose_requant(accmax + np.abs(bias), cout, rng, target, force_shift)
    if kind == 'clamp_edges':
        mult[:] = 1 << 14
        shift[:] = 14
    if mult_fixed is not None:
        mult[:] = mult_fixed
        shift = np.zeros(cout, dtype=np.int64)
        for c in range(cout):
            s = 0
            a = max(1, int(accmax[c] + abs(bias[c])))
            while s < 47 and (a * int(mult[c])) / float(1 << s) > target:
                s += 1
            shift[c] = s
        if force_shift is not None:
            shift[:] = force_shift
    out = qref.conv2d(x, wt, bias, mult, shift, act, k)
    if pool:
        out = qref.maxpool2(out, 2)                                 # the core merges the 2x2 windows while it writes
    oh, ow = out.shape[0], out.shape[1]

    # memory images
    if k == 3:
        img = qref.padded_hwc(x, 1)
        in_row = (w + 2) * cin
    else:
        img = x
        in_row = w * cin
    act_img = img.reshape(-1)
    in_base = 0
    in_pix = cin
    if out_pad:
        oimg = np.full((oh + 2, ow + 2, cout), 0x55, dtype=np.uint8)
        oimg[1:1 + oh, 1:1 + ow, :] = out.view(np.uint8)
        out_row = (ow + 2) * cout
        out_base = ((ow + 2) + 1) * cout
    else:
        oimg = out.view(np.uint8)
        out_row = ow * cout
        out_base = 0
    out_pix = cout
    words = qref.pack_weights(wt, lanes)

    d = os.path.dirname(name)
    os.makedirs(d, exist_ok=True)
    with open(name + '_cfg.txt', 'w') as f:
        f.write('%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n' % (h, w, cin, cout, 1 if k == 3 else 0, 1 if act else 0, in_base, in_row, in_pix,
                                                                         out_base, out_row, out_pix, len(act_img), len(words), oimg.size, 1 if pool else 0))
    with open(name + '_act.hex', 'w') as f:
        for v in act_img.view(np.uint8):
            f.write('%02X\n' % v)
    with open(name + '_wt.hex', 'w') as f:
        for wd in words:
            f.write(qref.word_hex(wd) + '\n')
    with open(name + '_pm.hex', 'w') as f:
        for c in range(cout):
            f.write(qref.param_word(bias[c], mult[c], shift[c]) + '\n')
    with open(name + '_exp.hex', 'w') as f:
        for v in oimg.reshape(-1):
            f.write('%02X\n' % v)
    # statistics for the report: how often the requantiser saturated, how many outputs are negative / zero
    y = qref.requant(acc + bias, mult, shift)
    sat_hi = int((y > 127).sum())
    sat_lo = int((y < -128).sum())
    return dict(name=os.path.basename(name), h=h, w=w, cin=cin, cout=cout, k=k, act=act, lanes=lanes, taps=cin * k * k, pool=int(pool),
                sat=sat_hi + sat_lo, neg=int((out < 0).sum()), total=int(out.size), shift_min=int(shift.min()), shift_max=int(shift.max()))


def all_cases(lanes):
    c = []
    # name, h, w, cin, cout, k, act, seed, kind, out_pad, target, force_shift
    c.append(('first3x3', 6, 9, 3, 16, 3, 1, 1, 'random', True, 90, None))
    c.append(('partial_tile', 7, 5, 16, 20, 3, 1, 2, 'random', False, 90, None))
    c.append(('head1x1_linear', 4, 6, 24, 24, 1, 0, 3, 'random', False, 90, None))
    c.append(('deep_extreme', 4, 4, 64, 17, 3, 1, 4, 'extreme', True, 90, None))
    c.append(('saturating', 5, 5, 12, 9, 3, 0, 5, 'random', False, 4, None))
    c.append(('stall_tiny', 3, 7, 2, 11, 1, 1, 6, 'random', False, 90, None))
    c.append(('one_by_one_cin1', 4, 4, 1, 5, 1, 0, 7, 'random', True, 90, None))
    c.append(('sparse_zero_shift', 5, 6, 8, 16, 3, 0, 8, 'sparse', False, 90, 0))
    c.append(('shift_large', 4, 5, 32, 8, 3, 1, 9, 'random', True, 90, 40))
    c.append(('bias_big', 4, 4, 16, 12, 3, 1, 10, 'bias_big', False, 90, None))
    c.append(('exact_two_tiles', 5, 5, 9, 2 * lanes, 3, 1, 11, 'random', True, 90, None))
    c.append(('cout_one', 6, 6, 5, 1, 3, 1, 12, 'random', False, 90, None))
    c.append(('wide_row', 2, 40, 4, 10, 3, 1, 13, 'random', True, 90, None))
    c.append(('mult_max', 4, 4, 10, 6, 1, 0, 14, 'random', False, 90, None))
    c.append(('clamp_edges', 4, 4, 1, 10, 1, 0, 15, 'clamp_edges', False, 90, None))        # y = x + bias around +127/128 and -128/-129, linear
    c.append(('clamp_edges_leaky', 4, 4, 1, 10, 1, 1, 16, 'clamp_edges', True, 90, None))   # the same with leaky ReLU and padded output storage
    # fused 2x2 max-pool: name, h, w, cin, cout, k, act, seed, kind, out_pad, target, force_shift, pool
    c.append(('pool_first', 8, 6, 3, 16, 3, 1, 21, 'random', True, 90, None, True))
    c.append(('pool_partial', 6, 8, 16, 20, 3, 1, 22, 'random', False, 90, None, True))
    c.append(('pool_leaky_neg', 4, 4, 8, 12, 3, 1, 23, 'extreme', True, 90, None, True))
    c.append(('pool_linear_1x1', 4, 6, 24, 9, 1, 0, 24, 'random', False, 90, None, True))
    c.append(('pool_small_t', 4, 4, 2, 5, 1, 1, 25, 'random', True, 90, None, True))
    c.append(('pool_sat', 6, 6, 12, 8, 3, 0, 26, 'random', False, 4, None, True))
    return c


def main():
    lanes = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    outdir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'logs_custom', 'yolo_vec', 'L%d' % lanes)
    outdir = os.path.normpath(outdir)
    rows = []
    for cs in all_cases(lanes):
        (nm, h, w, cin, cout, k, act, seed, kind, opad, target, fsh) = cs[:12]
        pool = cs[12] if len(cs) > 12 else False
        r = make_case(os.path.join(outdir, nm), h, w, cin, cout, k, act, lanes, seed, kind, opad, target, fsh, 65535 if nm == 'mult_max' else None, pool)
        rows.append(r)
    for r in rows:
        print('%-18s %2dx%-2d cin %-3d cout %-3d k%d act%d pool%d T=%-4d saturated %4d / %-5d negative outputs %4d shift %d..%d' % (
            r['name'], r['h'], r['w'], r['cin'], r['cout'], r['k'], r['act'], r['pool'], r['taps'], r['sat'], r['total'], r['neg'], r['shift_min'], r['shift_max']))
    print('vectors written to', outdir)


if __name__ == '__main__':
    main()
