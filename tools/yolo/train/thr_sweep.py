#!/usr/bin/env python3
"""thr_sweep.py - precision / recall of the int8 network at several decode score thresholds (the yolo_top THR parameter, Q16), plus false boxes on frames
that hold no target (negatives), so the board operating point can be chosen from data

Needs the int8 package written by eval_int.py (<run>/int8_params.npz). Uses exactly the FPGA decode (decode_ref, k_out 8, 32 slots).
Usage: F:/yolo_env/Scripts/python.exe thr_sweep.py --run F:/yolo_runs/real04 --data F:/yolo_data_real2 --neg F:/yolo_capture/s07neg [--thr 0.4 0.5 0.6 0.7 0.8]
"""
import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..'))
import decode_ref as dr
import eval_int as ei
import quantize as qz


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', required=True)
    ap.add_argument('--data', required=True)
    ap.add_argument('--split', default='val')
    ap.add_argument('--neg', nargs='*', default=[], help='sessions whose kept frames hold no target (their drop.json is applied)')
    ap.add_argument('--thr', type=float, nargs='+', default=[0.4, 0.5, 0.6, 0.7, 0.8])
    a = ap.parse_args()
    z = np.load(os.path.join(a.run, 'int8_params.npz'))
    qp = {n: (z[n + '_w'], z[n + '_b'], z[n + '_m'], z[n + '_s']) for n in qz.NAMES}
    anchors = json.load(open(os.path.join(a.run, 'anchors.json')))['anchors']
    imgs = np.load(os.path.join(a.data, a.split + '_img.npy'))
    labels = json.load(open(os.path.join(a.data, a.split + '_lab.json')))
    neg = []
    for s in a.neg:
        f = np.load(os.path.join(s, 'frames.npy'))
        dp = os.path.join(s, 'drop.json')
        drop = set(json.load(open(dp))['drop']) if os.path.exists(dp) else set()
        neg += [f[i] for i in range(len(f)) if i not in drop]
    heads = [ei.int_forward((im.astype(np.int16) - 128).astype(np.int8), qp) for im in imgs]
    nheads = [ei.int_forward((im.astype(np.int16) - 128).astype(np.int8), qp) for im in neg]
    print('%s: %d frames / %d boxes; negatives: %d frames' % (a.split, len(imgs), sum(len(l) for l in labels), len(neg)))
    print('thr   precision  recall   tp   fp   gt   | negatives: frames with a box, boxes')
    for t in a.thr:
        cfg = ei.cfg_from_anchors(anchors, thr=int(round(t * 65536)))
        d = [ei.to_net(dr.decode([h1, h2], cfg)) for (h1, h2) in heads]
        pr = ei.pr_at(d, labels)
        dn = [ei.to_net(dr.decode([h1, h2], cfg)) for (h1, h2) in nheads]
        print('%.2f  %.3f      %.3f    %3d  %3d  %3d  | %3d / %3d, %3d' % (t, pr['precision'], pr['recall'], pr['tp'], pr['fp'], pr['gt'],
                                                                      sum(1 for x in dn if x), len(dn), sum(len(x) for x in dn)))


if __name__ == '__main__':
    main()
