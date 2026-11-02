#!/usr/bin/env python3
"""eval_int.py - quantise a trained model (quantize.py) and evaluate the INTEGER network exactly as the FPGA computes it (qref.py + decode_ref.py)

Steps: float_folded.npz + anchors.json -> calibration on training images -> int8 parameters -> integer forward of every test image (bit-exact model of yolo_net_engine)
-> decode_ref (the bit-exact model of yolo_decode.v) -> AP50 per class, and precision / recall at the hardware operating point (score >= 0.4, 32 candidate slots, NMS 29/64,
8 boxes). Also: the float network on the same images for comparison, head saturation of the integer network.
Writes <run>/int8_params.npz, <run>/eval_int.json.

Usage: F:/yolo_env/Scripts/python.exe eval_int.py --run F:/yolo_runs/p5_synth --data F:/yolo_data [--n 2000] [--calib 256]
"""
import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
import qref
import decode_ref as dr
import quantize as qz

CH = (8, 8, 16, 16, 24, 32, 24, 16, 24, 8, 16)
PAD_TOP, KSC = 12, 10


def int_forward(x, qp):
    """x int8 [96, 128, 3] -> (head1, head2) int8; the same data flow as mininet.build / the descriptor table"""
    sp = qz.specs(CH)

    def conv(name, t):
        w, b, m, s = qp[name]
        return qref.conv2d(t, w, b, m, s, sp[name][3], sp[name][2])

    t = qref.maxpool2(conv('conv0', x), 2)
    t = qref.maxpool2(conv('conv2', t), 2)
    t = qref.maxpool2(conv('conv4', t), 2)
    t = qref.maxpool2(conv('conv6', t), 2)
    c8 = conv('conv8', t)
    t = qref.maxpool2(c8, 2)
    t = conv('conv12', conv('conv10', t))
    t13 = conv('conv13', t)
    h1 = conv('head1', conv('conv14', t13))
    cat = qref.concat(qref.upsample2(conv('conv18', t13)), c8)
    h2 = conv('head2', conv('conv21', cat))
    return h1, h2


def cfg_from_anchors(anchors, thr=26214, k_out=8, slots=32):
    a1 = tuple(tuple(int(v) for v in a) for a in anchors[0])
    a2 = tuple(tuple(int(v) for v in a) for a in anchors[1])
    return dr.Cfg(anchors=(a1, a2), thr=thr, k_out=k_out, slots=slots)


def to_net(dets):
    """decode_ref boxes (frame pixels) -> (cls, score, x0, y0, x1, y1) in network pixels"""
    return [(c, s / 65536.0, x0 / KSC, y0 / KSC + PAD_TOP, x1 / KSC, y1 / KSC + PAD_TOP) for (s, c, x0, y0, x1, y1) in dets]


def pr_at(dets, labels, iou_thr=0.5):
    tp = fp = 0
    npos = sum(len(l) for l in labels)
    bucket = {'small(<8px)': [0, 0], 'medium(8-16px)': [0, 0], 'large(>=16px)': [0, 0]}      # [found, total] by the larger side in network pixels (x10 = frame pixels)

    def bname(w, h):
        m = max(w, h)
        return 'small(<8px)' if m < 8 else ('medium(8-16px)' if m < 16 else 'large(>=16px)')
    for d, lab in zip(dets, labels):
        g = np.array([(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, c) for (c, cx, cy, w, h) in lab], dtype=np.float64).reshape(-1, 5)
        used = np.zeros(len(g), dtype=bool)
        for (c, cx, cy, w, h) in lab:
            bucket[bname(w, h)][1] += 1
        for (c, s, x0, y0, x1, y1) in d:
            if len(g) == 0:
                fp += 1
                continue
            ix = np.clip(np.minimum(x1, g[:, 2]) - np.maximum(x0, g[:, 0]), 0, None)
            iy = np.clip(np.minimum(y1, g[:, 3]) - np.maximum(y0, g[:, 1]), 0, None)
            inter = ix * iy
            u = (x1 - x0) * (y1 - y0) + (g[:, 2] - g[:, 0]) * (g[:, 3] - g[:, 1]) - inter
            iou = np.where(g[:, 4] == c, inter / np.maximum(u, 1e-9), 0)
            j = int(iou.argmax())
            if iou[j] >= iou_thr and not used[j]:
                used[j] = True
                tp += 1
                c_, cx_, cy_, w_, h_ = lab[j]
                bucket[bname(w_, h_)][0] += 1
            else:
                fp += 1
    return dict(precision=tp / max(tp + fp, 1), recall=tp / max(npos, 1), tp=tp, fp=fp, gt=npos,
                recall_by_size={k: (round(v[0] / max(v[1], 1), 3), v[1]) for k, v in bucket.items()})


def main():
    import train_yolo as ty
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', default='F:/yolo_runs/p5_synth')
    ap.add_argument('--data', default='F:/yolo_data')
    ap.add_argument('--n', type=int, default=2000)
    ap.add_argument('--calib', type=int, default=256)
    ap.add_argument('--split', default='test')
    a = ap.parse_args()
    z = np.load(os.path.join(a.run, 'float_folded.npz'))
    P = {k: (z[k + '_w'], z[k + '_b']) for k in qz.NAMES}
    anchors = json.load(open(os.path.join(a.run, 'anchors.json')))['anchors']
    tr = np.load(os.path.join(a.data, 'train_img.npy'), mmap_mode='r')
    rng = np.random.default_rng(1)
    calib = [(tr[i].astype(np.float64) - 128.0) / 128.0 for i in rng.choice(len(tr), a.calib, replace=False)]
    qp, scales, rep = qz.quantize(P, calib, CH)
    np.savez(os.path.join(a.run, 'int8_params.npz'), **{n + '_w': qp[n][0] for n in qz.NAMES}, **{n + '_b': qp[n][1] for n in qz.NAMES},
             **{n + '_m': qp[n][2] for n in qz.NAMES}, **{n + '_s': qp[n][3] for n in qz.NAMES})
    json.dump(dict(s_in={k: float(v) for k, v in scales['s_in'].items()}, s_out={k: float(v) for k, v in scales['s_out'].items()}),
              open(os.path.join(a.run, 'int8_scales.json'), 'w'), indent=1)
    imgs = np.load(os.path.join(a.data, a.split + '_img.npy'))[:a.n]
    labels = json.load(open(os.path.join(a.data, a.split + '_lab.json')))[:a.n]
    cfg_ap = cfg_from_anchors(anchors, thr=655, k_out=64, slots=256)       # low threshold, many boxes: for the AP curve
    cfg_hw = cfg_from_anchors(anchors)                                     # exactly the FPGA operating point
    d_ap, d_hw, sat = [], [], []
    for i in range(len(imgs)):
        x = (imgs[i].astype(np.int16) - 128).astype(np.int8)
        h1, h2 = int_forward(x, qp)
        sat.append(float(np.mean(np.concatenate([(h1 == 127) | (h1 == -128), (h2 == 127) | (h2 == -128)], axis=None))))
        d_ap.append(to_net(dr.decode([h1, h2], cfg_ap)))
        d_hw.append(to_net(dr.decode([h1, h2], cfg_hw)))
    ap_int = ty.average_precision(d_ap, labels)
    pr_hw = pr_at(d_hw, labels)
    # float network on the same images
    import torch
    dev = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    model = ty.Net().to(dev)
    model.load_state_dict(torch.load(os.path.join(a.run, 'model.pt'), map_location=dev))
    ap_float, d_float = ty.evaluate(model, imgs, labels, anchors, dev)
    pr_float = pr_at([[d for d in dd if d[1] >= 0.4][:8] for dd in d_float], labels)
    res = dict(split=a.split, images=len(imgs), int8_AP50=ap_int, float_AP50=ap_float, int8_hw_operating_point=pr_hw, float_at_0p4_top8=pr_float,
               int8_head_saturation=float(np.mean(sat)), quant_report={k: {kk: (list(vv) if isinstance(vv, tuple) else vv) for kk, vv in v.items()} for k, v in rep.items()})
    json.dump(res, open(os.path.join(a.run, 'eval_int.json'), 'w'), indent=1)
    print('int8  AP50', {k: round(v, 3) for k, v in ap_int.items()})
    print('float AP50', {k: round(v, 3) for k, v in ap_float.items()})
    print('int8 at the FPGA operating point', pr_hw)
    print('float at score 0.4 / 8 boxes   ', pr_float)
    print('int8 head saturation %.4f' % np.mean(sat))


if __name__ == '__main__':
    main()
