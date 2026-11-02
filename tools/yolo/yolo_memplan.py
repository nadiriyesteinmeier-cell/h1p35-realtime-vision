#!/usr/bin/env python3
"""yolo_memplan.py - on-chip memory plan (ERAM20K blocks) of the YOLOv3-tiny-derived network executed by rtl_custom/yolo_conv_core.v

yolo_budget.py counts MACs and bytes per layer; this script answers the question that decides the architecture: does the network fit into the ERAM blocks
the video design leaves free, and what has to live in DDR instead?  NOTHING here is a measurement: it is arithmetic on the layer table and on the
data-flow of the core.

Data-flow assumptions (they follow the interface of yolo_conv_core.v):
  * every tensor is stored HWC, one byte per value; a tensor read by a 3x3 convolution carries a one-pixel zero border (H+2, W+2);
  * the core reads ONE byte of the input per clock (act port) and writes / read-modify-writes ONE byte of the output (out port), so a layer needs
    its input and its output in DIFFERENT memories -> ping-pong banks A / B, and a third bank C for the tensor that is also the route source
    (conv8 writes unpooled into the concat buffer, pool9 and conv21 read it);
  * the fused 2x2 max-pool makes conv0 / conv2 / conv4 / conv6 write only the pooled map;
  * weights are consumed tile by tile (LANES output channels x Cin x k x k bytes); a tile is re-read for every pixel, so it is buffered on chip
    (double-buffered when it is streamed from DDR);
  * per-channel parameters (bias, multiplier, shift: 7 bytes, stored in 8) are buffered per layer.
ERAM20K = 20 Kbit; with 8-bit data one block holds 2048 bytes (the parity bit is not used) - the conservative figure.

Usage: python yolo_memplan.py [--width 0.25] [--input 160x96] [--lanes 8] [--classes 3] [--free 63]
       python yolo_memplan.py --sweep
"""
import argparse
import math
import sys

import yolo_budget as yb

BLK = 2048
yb.DROP_POOL11 = True      # the memory plan is for our pruned topology without the stride-1 pool of the original cfg


def blocks(nbytes):
    return int(math.ceil(nbytes / float(BLK)))


def plan(width, in_w, in_h, classes, lanes, c_override=None):
    """returns a dict with the bank sizes (bytes), weights, tile buffers and the totals; the layer list comes from yolo_budget.build"""
    L = yb.build(width, in_w, in_h, classes)
    byname = {l['name']: l for l in L}

    def pad(h, w, c):
        return (h + 2) * (w + 2) * c

    def raw(h, w, c):
        return h * w * c

    ih, iw = in_h, in_w
    c0 = byname['conv0']['cout']
    c1 = byname['conv2']['cout']
    c2 = byname['conv4']['cout']
    c3 = byname['conv6']['cout']
    c4 = byname['conv8']['cout']
    c5 = byname['conv10']['cout']
    c6 = byname['conv12']['cout']
    d1 = byname['conv13']['cout']
    d2 = byname['conv14']['cout']
    d3 = byname['conv18']['cout']
    d4 = byname['conv21']['cout']
    head = byname['head1']['cout']
    h1, w1 = ih // 2, iw // 2        # after pool1
    h2, w2 = h1 // 2, w1 // 2
    h3, w3 = h2 // 2, w2 // 2
    h4, w4 = h3 // 2, w3 // 2        # conv8 resolution (stride 16)
    h5, w5 = h4 // 2, w4 // 2        # stride 32
    t = {}
    # name -> (bank, bytes, produced by, last consumer)
    t['IN'] = ('A', pad(ih, iw, 3), 'frame', 'conv0')
    t['T1'] = ('B', pad(h1, w1, c0), 'conv0', 'conv2')
    t['T3'] = ('A', pad(h2, w2, c1), 'conv2', 'conv4')
    t['T5'] = ('B', pad(h3, w3, c2), 'conv4', 'conv6')
    t['T7'] = ('A', pad(h4, w4, c3), 'conv6', 'conv8')
    t['CAT'] = ('C', pad(h4, w4, d3 + c4), 'conv8', 'conv21')            # concat buffer: [0, d3) upsampled, [d3, d3 + c4) conv8 output
    t['T9'] = ('B', pad(h5, w5, c4), 'pool9', 'conv10')
    t['T10'] = ('A', pad(h5, w5, c5), 'conv10', 'conv12')               # pool11 (stride 1) dropped in this variant
    t['T12'] = ('B', raw(h5, w5, c6), 'conv12', 'conv13')
    t['T13'] = ('A', pad(h5, w5, d1), 'conv13', 'conv18')
    t['T14'] = ('B', raw(h5, w5, d2), 'conv14', 'head1')
    t['T18'] = ('B', raw(h5, w5, d3), 'conv18', 'upsample')
    t['T21'] = ('A', raw(h4, w4, d4), 'conv21', 'head2')
    t['H1'] = ('D', raw(h5, w5, head), 'head1', 'decode')
    t['H2'] = ('D', raw(h4, w4, head), 'head2', 'decode')
    bank = {}
    for k, (b, n, _, _) in t.items():
        bank[b] = max(bank.get(b, 0), n)
    # weights / parameters
    wtot = 0
    maxtile = 0
    maxpm = 0
    for l in L:
        if l['op'] == 'conv':
            wtot += l['cout'] * l['cin'] * l['k'] * l['k']
            maxtile = max(maxtile, min(lanes, l['cout']) * l['cin'] * l['k'] * l['k'])
            maxpm = max(maxpm, l['cout'] * 8)
    ptot = sum(l['cout'] * 8 for l in L if l['op'] == 'conv')
    act_blocks = sum(blocks(v) for k, v in bank.items() if k != 'D') + blocks(bank.get('D', 0))
    return dict(width=width, inp='%dx%d' % (in_w, in_h), lanes=lanes, bankA=bank['A'], bankB=bank['B'], bankC=bank['C'], bankD=bank['D'],
                act_blocks=act_blocks, weights=wtot, params=ptot, maxtile=maxtile, maxpm=maxpm,
                tile_dbl_blocks=2 * blocks(maxtile), pm_blocks=blocks(maxpm), wrom_blocks=blocks(wtot) + blocks(ptot),
                tensors=t, ch=(c0, c1, c2, c3, c4, c5, c6, d1, d2, d3, d4))


def show(p, free):
    print('%s input %s lanes %d  channels %s' % ('custom channel plan' if yb.CH_OVERRIDE else 'width %.3g' % p['width'], p['inp'], p['lanes'], p['ch']))
    print('  activation banks: A %d B  B %d B  C %d B  D %d B  -> %d ERAM blocks' % (p['bankA'], p['bankB'], p['bankC'], p['bankD'], p['act_blocks']))
    print('  weights %d B (%.1f KB), largest tile %d B; params %d B' % (p['weights'], p['weights'] / 1024.0, p['maxtile'], p['params']))
    a = p['act_blocks'] + p['pm_blocks']
    streamed = a + p['tile_dbl_blocks']
    resident = a + p['wrom_blocks']
    print('  (1) weights streamed from DDR: activations %d + params %d + double-buffered tile %d = %d blocks  -> %s (free %d)' % (
        p['act_blocks'], p['pm_blocks'], p['tile_dbl_blocks'], streamed, 'FITS' if streamed <= free else 'DOES NOT FIT', free))
    print('  (2) weights + params resident as ROM in the bitstream: activations %d + ROM %d = %d blocks  -> %s' % (
        p['act_blocks'], p['wrom_blocks'], p['act_blocks'] + p['wrom_blocks'], 'FITS' if p['act_blocks'] + p['wrom_blocks'] <= free else 'DOES NOT FIT'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--width', type=float, default=0.25)
    ap.add_argument('--input', default='160x96')
    ap.add_argument('--lanes', type=int, default=8)
    ap.add_argument('--classes', type=int, default=3)
    ap.add_argument('--free', type=int, default=63, help='free ERAM20K blocks (contest_work_v3_isplite: 63, color4: 58)')
    ap.add_argument('--sweep', action='store_true')
    ap.add_argument('--ch', help='explicit channel plan c0,c1,c2,c3,c4,c5,c6,d1,d2,d3,d4 (overrides --width)')
    a = ap.parse_args()
    if a.ch:
        yb.CH_OVERRIDE = tuple(int(x) for x in a.ch.split(','))
    if a.sweep:
        print('%-6s %-8s %5s | %9s %9s %9s | %6s %6s %5s | %12s %12s' % ('width', 'input', 'lanes', 'weights', 'bankA', 'bankB', 'actBlk', 'tile2x', 'pm', 'DDR-weights', 'ROM-weights'))
        for inp in ('160x96', '128x96', '128x64', '96x64'):
            for w in (1.0, 0.5, 0.25, 0.125):
                for lanes in (8,):
                    iw, ih = (int(x) for x in inp.split('x'))
                    p = plan(w, iw, ih, a.classes, lanes)
                    s1 = p['act_blocks'] + p['pm_blocks'] + p['tile_dbl_blocks']
                    s2 = p['act_blocks'] + p['wrom_blocks']
                    print('%-6.3g %-8s %5d | %9d %9d %9d | %6d %6d %5d | %5d blk %-4s %5d blk %-4s' % (
                        w, inp, lanes, p['weights'], p['bankA'], p['bankB'], p['act_blocks'], p['tile_dbl_blocks'], p['pm_blocks'],
                        s1, 'ok' if s1 <= a.free else 'NO', s2, 'ok' if s2 <= a.free else 'NO'))
        return 0
    iw, ih = (int(x) for x in a.input.split('x'))
    p = plan(a.width, iw, ih, a.classes, a.lanes)
    show(p, a.free)
    print('  tensors:')
    for k, (b, n, src, dst) in p['tensors'].items():
        print('    %-4s bank %s %8d B  %s -> %s' % (k, b, n, src, dst))
    return 0


if __name__ == '__main__':
    sys.exit(main())
