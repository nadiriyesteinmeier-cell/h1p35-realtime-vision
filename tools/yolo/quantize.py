#!/usr/bin/env python3
"""quantize.py - float model -> int8 package for yolo_net_engine (BN folding, per-channel weight scales, calibrated activation scales, per-channel M / S)

The topology and the memory plan are those of mininet.py (the pruned YOLOv3-tiny-derived detector: conv0 conv2 conv4 conv6 conv8 conv10 conv12 conv13 conv14 head1 conv18 conv21 head2,
2x2 max-pools after conv0..conv6 (fused) and conv8 (pool9), x2 upsample + concat). The trainer (PyTorch or anything else) only has to deliver, per convolution, a float weight
[cout, cin, k, k] and bias [cout] (with BatchNorm folded, see fold_bn) in an .npz file named `<layer>_w` / `<layer>_b`; leaky slope must be 13/128, the network input is
(pixel - 128) / 128, every head output channel is meant to have the real scale 1/16 (this script forces it through the requantiser).

Quantisation (symmetric, zero point 0)
    s_w[c]  = max |W[c]| / 127                         wq = round(W / s_w)
    s_in    = scale of the input tensor, s_out = percentile(|activation|, 99.99) / 127 from a calibration set (head outputs: 1/16; conv8 and conv18 share one scale because the
              concat buffer feeds conv21 with a single input scale)
    bias_q  = round(b / (s_in * s_w[c]))                    int32 in the accumulator scale
    r       = s_in * s_w[c] / s_out ;  S = floor(log2(65535 / r)) clipped to 0..47,  M = round(r * 2^S)  (M in [32768, 65535] unless S is clipped)
The integer network is then run by mininet.py / qref.py (bit-exact model of the RTL); the result is compared with the float network layer by layer (SQNR) and the package files for
tb_custom/tb_yolo_net.v are written (so that the RTL runs the exported model).

Usage:  python quantize.py --selftest        random float model + random images: the whole chain, the SQNR report, the package, the RTL simulation of it
        python quantize.py --model model.npz --calib calib.npz --out <prefix>      (calib.npz: array `images` uint8 [N, 720, 1280, 3] or already boxed int8 [N, 96, 128, 3])
"""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import qref
import mininet

NAMES = ['conv0', 'conv2', 'conv4', 'conv6', 'conv8', 'conv10', 'conv12', 'conv13', 'conv14', 'head1', 'conv18', 'conv21', 'head2']
LEAKY = 13.0 / 128.0
HEAD_SCALE = 1.0 / 16.0
IN_SCALE = 1.0 / 128.0


def specs(ch, classes=3):
    c0, c1, c2, c3, c4, c5, c6, d1, d2, d3, d4 = ch
    head = 3 * (5 + classes)
    return {'conv0': (3, c0, 3, True), 'conv2': (c0, c1, 3, True), 'conv4': (c1, c2, 3, True), 'conv6': (c2, c3, 3, True), 'conv8': (c3, c4, 3, True),
            'conv10': (c4, c5, 3, True), 'conv12': (c5, c6, 3, True), 'conv13': (c6, d1, 1, True), 'conv14': (d1, d2, 3, True), 'head1': (d2, head, 1, False),
            'conv18': (d1, d3, 1, True), 'conv21': (d3 + c4, d4, 3, True), 'head2': (d4, head, 1, False)}


def fold_bn(w, b, gamma, beta, mean, var, eps=1e-5):
    """fold y = gamma * (conv(x) + b - mean) / sqrt(var + eps) + beta into the convolution"""
    s = gamma / np.sqrt(var + eps)
    return w * s[:, None, None, None], (b - mean) * s + beta


# ---------------------------------------------------------------- float network (same data flow as mininet.build)
def fconv(x, w, b, k):
    h, wd, _ = x.shape
    xp = np.pad(x, ((k // 2, k // 2), (k // 2, k // 2), (0, 0))) if k == 3 else x
    out = np.zeros((h, wd, w.shape[0]), dtype=np.float64)
    for ky in range(k):
        for kx in range(k):
            out += np.tensordot(xp[ky:ky + h, kx:kx + wd, :], w[:, :, ky, kx], axes=([2], [1]))
    return out + b


def fleaky(x):
    return np.where(x >= 0, x, x * LEAKY)


def fpool2(x):
    return np.maximum(np.maximum(x[0::2, 0::2], x[0::2, 1::2]), np.maximum(x[1::2, 0::2], x[1::2, 1::2]))


def fup2(x):
    return np.repeat(np.repeat(x, 2, axis=0), 2, axis=1)


def float_forward(x, P, ch, classes=3):
    """x float [h, w, 3] (real values (pixel - 128) / 128); P: name -> (w, b). Returns a dict of the PRE-pool convolution outputs ('pre_<layer>') and the heads."""
    sp = specs(ch, classes)
    t = {}

    def conv(name, inp):
        cin, cout, k, act = sp[name]
        y = fconv(inp, P[name][0], P[name][1], k)
        y = fleaky(y) if act else y
        t['pre_' + name] = y
        return y

    x1 = fpool2(conv('conv0', x))
    x3 = fpool2(conv('conv2', x1))
    x5 = fpool2(conv('conv4', x3))
    x7 = fpool2(conv('conv6', x5))
    c8 = conv('conv8', x7)
    x9 = fpool2(c8)
    x10 = conv('conv10', x9)
    x12 = conv('conv12', x10)
    x13 = conv('conv13', x12)
    x14 = conv('conv14', x13)
    t['head1'] = conv('head1', x14)
    x18 = conv('conv18', x13)
    cat = np.concatenate([fup2(x18), c8], axis=2)
    x21 = conv('conv21', cat)
    t['head2'] = conv('head2', x21)
    return t


def pct_scale(vals, pct=99.99):
    m = np.percentile(np.abs(np.concatenate([v.reshape(-1) for v in vals])), pct)
    return max(m, 1e-6) / 127.0


def requant_const(r):
    """(M, S) with M / 2^S ~ r, M < 65536 and S in 0..47"""
    if r <= 0:
        return 0, 0
    s = int(math.floor(math.log2(65535.0 / r)))
    s = max(0, min(47, s))
    m = int(round(r * (1 << s)))
    if m > 65535:
        s = max(0, s - 1)
        m = int(round(r * (1 << s)))
    if m > 65535:
        raise ValueError('requantiser constant too large: r = %g' % r)
    return m, s


def quantize(P, calib_images, ch, classes=3):
    """P: float parameters; calib_images: list of float [h, w, 3]. Returns (qparams, scales, report)"""
    sp = specs(ch, classes)
    acts = {n: [] for n in NAMES}
    for im in calib_images:
        t = float_forward(im, P, ch, classes)
        for n in NAMES:
            acts[n].append(t['pre_' + n])
    s_out = {n: pct_scale(acts[n]) for n in NAMES}
    s_out['head1'] = s_out['head2'] = HEAD_SCALE
    s_out['conv8'] = s_out['conv18'] = max(s_out['conv8'], s_out['conv18'])               # shared scale of the concat buffer
    s_in = {'conv0': IN_SCALE, 'conv2': s_out['conv0'], 'conv4': s_out['conv2'], 'conv6': s_out['conv4'], 'conv8': s_out['conv6'], 'conv10': s_out['conv8'],
            'conv12': s_out['conv10'], 'conv13': s_out['conv12'], 'conv14': s_out['conv13'], 'head1': s_out['conv14'], 'conv18': s_out['conv13'],
            'conv21': s_out['conv8'], 'head2': s_out['conv21']}
    qp = {}
    rep = {}
    for n in NAMES:
        w, b = P[n]
        amax = np.abs(w).reshape(w.shape[0], -1).max(axis=1)
        s_w = np.where(amax > 0, amax / 127.0, 1.0)
        wq = np.clip(np.round(w / s_w[:, None, None, None]), -127, 127).astype(np.int8)
        bq = np.round(b / (s_in[n] * s_w)).astype(np.int64)
        ms = [requant_const(s_in[n] * sw / s_out[n]) for sw in s_w]
        mult = np.array([m for m, _ in ms], dtype=np.int64)
        shift = np.array([s for _, s in ms], dtype=np.int64)
        qp[n] = (wq, bq, mult, shift)
        rep[n] = dict(s_in=s_in[n], s_out=s_out[n], s_w_min=float(s_w.min()), s_w_max=float(s_w.max()), m_min=int(mult.min()), shift_range=(int(shift.min()), int(shift.max())))
    return qp, dict(s_in=s_in, s_out=s_out), rep


def write_manifest(prefix, ch, in_w, in_h, lanes, scales, classes=3, note=''):
    """<prefix>_manifest.json: topology, quantisation constants and the SHA256 of every file of the package (model identification for the board handoff)"""
    import hashlib
    import json
    files = {}
    for suf in ('_desc.hex', '_wt.hex', '_pm.hex', '_in.hex', '_exp.hex', '_cfg.txt'):
        files[os.path.basename(prefix) + suf] = hashlib.sha256(open(prefix + suf, 'rb').read()).hexdigest()
    man = dict(model='YOLOv3-tiny-derived pruned fixed-point detector (NOT the official full network)', topology=dict(channels=list(ch), input=[in_w, in_h], classes=classes, lanes=lanes,
               head_output_scale='1/16', leaky_slope='13/128', input_scale='1/128 (value = pixel - 128)'),
               scales=dict(s_out={k: float(v) for k, v in scales['s_out'].items()}, s_in={k: float(v) for k, v in scales['s_in'].items()}), sha256=files, note=note)
    with open(prefix + '_manifest.json', 'w') as f:
        json.dump(man, f, indent=2)
    return man


def sqnr_db(ref, approx):
    e = np.sum((ref - approx) ** 2)
    return 10.0 * math.log10(max(np.sum(ref ** 2), 1e-30) / max(e, 1e-30))


def random_model(ch, seed, classes=3):
    rng = np.random.default_rng(seed)
    P = {}
    for n, (cin, cout, k, act) in specs(ch, classes).items():
        w = rng.normal(0, math.sqrt(2.0 / (cin * k * k)), size=(cout, cin, k, k))
        b = rng.normal(0, 0.05, size=cout)
        gamma = rng.uniform(0.7, 1.3, cout)
        beta = rng.normal(0, 0.1, cout)
        mean = rng.normal(0, 0.1, cout)
        var = rng.uniform(0.5, 1.5, cout)
        P[n] = fold_bn(w, b, gamma, beta, mean, var) if act else (w, b)
    return P


def compare(P, qp, scales, img_q, ch, lanes, classes=3):
    """integer network on the int8 image vs the float network on the same (dequantised) image: per-layer SQNR and head errors"""
    import mininet as mn
    n, IN, tens, x = mn.build(img_q.shape[1], img_q.shape[0], ch, lanes, 0, classes, qparams=qp, image=img_q)
    xf = img_q.astype(np.float64) * IN_SCALE
    t = float_forward(xf, P, ch, classes)
    out = {}
    # integer tensors by mininet name (post-pool where the layer pools): compare after pooling the float tensor as well
    pairs = {'conv0': ('T1', True), 'conv2': ('T3', True), 'conv4': ('T5', True), 'conv6': ('T7', True), 'conv8': ('C8', False), 'conv10': ('T10', False), 'conv12': ('T12', False),
             'conv13': ('T13', False), 'conv14': ('T14', False), 'head1': ('H1', False), 'conv18': ('T18', False), 'conv21': ('T21', False), 'head2': ('H2', False)}
    for name, (tn, pooled) in pairs.items():
        ref = t['pre_' + name] if 'pre_' + name in t else t[name]
        if pooled:
            ref = fpool2(ref)
        approx = n.val[tn].astype(np.float64) * scales['s_out'][name]
        out[name] = sqnr_db(ref, approx)
    return n, out


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--lanes', type=int, default=8)
    a = ap.parse_args()
    if not a.selftest:
        print(__doc__)
        return 0
    ch = (8, 8, 16, 16, 24, 32, 24, 16, 24, 8, 16)
    in_w, in_h = 96, 64
    P = random_model(ch, 11)
    rng = np.random.default_rng(5)
    calib = [rng.integers(-128, 128, size=(in_h, in_w, 3)).astype(np.float64) / 128.0 for _ in range(6)]       # same distribution as the test image (a calibration set that is too small in amplitude clips the test data: SQNR drops by 10-15 dB)
    qp, scales, rep = quantize(P, calib, ch)
    print('%-8s %8s %8s %10s %10s %6s %s' % ('layer', 's_in', 's_out', 's_w min', 's_w max', 'M min', 'S range'))
    for n in NAMES:
        r = rep[n]
        print('%-8s %8.5f %8.5f %10.6f %10.6f %6d %s' % (n, r['s_in'], r['s_out'], r['s_w_min'], r['s_w_max'], r['m_min'], r['shift_range']))
    test = (rng.integers(-128, 128, size=(in_h, in_w, 3))).astype(np.int8)
    n, sq = compare(P, qp, scales, test, ch, a.lanes)
    print('SQNR integer network vs float network on a random test image (dB):')
    print('  ' + '  '.join('%s %.1f' % (k, v) for k, v in sq.items()))
    print('largest |acc| + |bias| per layer (must stay below 2^31 = 2147483648):', max(n.acc_worst.values()), '(%s)' % max(n.acc_worst, key=n.acc_worst.get))
    for hn in ('H1', 'H2'):
        v = n.val[hn]
        print('head %s: %.1f %% of the outputs saturate (int8 -128 / 127 = real -8 / +7.94); a head trained for this contract must stay inside +-8' % (hn, 100.0 * np.mean((v == 127) | (v == -128))))
    prefix = os.path.join(HERE, '..', '..', 'logs_custom', 'yolo_vec', 'quant%d' % a.lanes, 'quant_a')
    info = mininet.write_case(os.path.normpath(prefix), in_w, in_h, ch, a.lanes, 0, qparams=qp, image=test)
    write_manifest(os.path.normpath(prefix), ch, in_w, in_h, a.lanes, scales, note='self-test with a RANDOM float model, not a trained network')
    print('package written:', os.path.normpath(prefix), '- %d layers, %d expected bytes, %d weight words' % (len(info['layers']), info['n_exp'], info['wt_words']))
    # the exported package through the RTL (descriptor sequencer + both cores) in Icarus Verilog
    import subprocess
    root = os.path.normpath(os.path.join(HERE, '..', '..'))
    iv = os.path.join(root, 'tools', 'iverilog', 'ucrt64', 'bin')
    vvp = os.path.join(root, 'logs_custom', 'yolo_vec', 'sim_quant_L%d.vvp' % a.lanes)
    rtl = [os.path.join(root, 'rtl_custom', f) for f in ('yolo_net_engine.v', 'yolo_conv_core.v', 'yolo_aux_core.v', 'yolo_bank_ram.v')]
    r = subprocess.run([os.path.join(iv, 'iverilog.exe'), '-g2005', '-P', 'tb_yolo_net.LANES=%d' % a.lanes, '-o', vvp, os.path.join(root, 'tb_custom', 'tb_yolo_net.v')] + rtl, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout + r.stderr)
        return 2
    res = subprocess.run([os.path.join(iv, 'vvp.exe'), vvp, '+CASE=' + os.path.normpath(prefix).replace(chr(92), '/')], capture_output=True, text=True)
    line = [l for l in res.stdout.splitlines() if l.startswith('TB_RESULT')]
    print(line[-1] if line else res.stdout[-800:])
    return 0 if line and 'PASS' in line[-1] else 1


if __name__ == '__main__':
    sys.exit(main())
