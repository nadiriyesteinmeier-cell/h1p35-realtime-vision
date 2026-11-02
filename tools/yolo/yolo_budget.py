#!/usr/bin/env python3
"""yolo_budget.py - layer-by-layer cost model of YOLOv3-tiny-derived detectors on the PH1P35 board

The reference topology is darknet's yolov3-tiny.cfg (pjreddie/darknet, 2 detection scales, leaky ReLU 0.1, 3x3 / 1x1 convolutions, 2x2 max-pools,
one 1x1 + upsample + concat branch). The model here is parametrised so that "YOLOv3-tiny" can be compared with channel-pruned versions:

    --width W     channel multiplier on every hidden layer (1.0 = the original 16-32-64-128-256-512-1024 / 256-512 / 128 / 256 channels), channels are
                  rounded to a multiple of 8, minimum 8;  the two detection convolutions keep 3 * (5 + classes) output channels
    --input WxH   network input (multiples of 32); 160x96 = the 1280x720 frame averaged 8x8 and letter-boxed (3 rows of padding top and bottom)
    --classes N   number of classes (3: red_part / green_part / blue_part, the working labels of the task)
    --lanes L     output-channel lanes of the convolution engine (L multiply-accumulate units working in parallel on one broadcast activation)
    --clock MHz   engine clock

Per layer it prints: output shape, MACs, int8 weight bytes, activation bytes in / out, engine cycles, and for the whole network the sums, the largest
weight tile the engine has to hold on chip (L output channels x Cin x k x k), the largest single activation map, the DDR traffic per frame and the
frame rate an engine with the given lanes / clock reaches (compute bound, 100 % MAC utilisation; the cycle count adds one cycle per tap, per output
vector pipeline overhead of OVERHEAD cycles, and pads Cout up to a multiple of L).  NOTHING here is a measurement: it is arithmetic on the layer table.

Usage:  python yolo_budget.py [--width 1.0] [--input 160x96] [--classes 3] [--lanes 16] [--clock 100] [--csv out.csv]
        python yolo_budget.py --sweep          (the comparison table used in docs/YOLO_FEASIBILITY_2026-10-16.md)
"""
import argparse
import csv
import math
import sys

DROP_POOL11 = False      # True: the stride-1 max-pool of the original cfg is left out (our own pruned topology; --no-pool11)
CH_OVERRIDE = None       # explicit channel plan (c0 .. c6, d1, d2, d3, d4) instead of width * the YOLOv3-tiny channels (--ch 8,8,16,...)

# Cycle model of rtl_custom/yolo_conv_core.v, measured in simulation (tb_yolo_conv.v, utilisation 98-99 % for T >= LANES + 1):
#   one output vector (LANES channels of one pixel) costs max(T, LANES + 1) clocks, T = cin * k * k; a layer adds LANES + 14 clocks of pipeline fill.


def ch(c, w):
    if w == 1.0:
        return c
    return max(8, int(round(c * w / 8.0)) * 8)


def build(width, in_w, in_h, classes):
    """returns a list of layer dicts; sizes are tracked as (h, w, c)"""
    head = 3 * (5 + classes)
    L = []

    def conv(name, cin, cout, k, h, w, act=True, src=None):
        L.append(dict(name=name, op='conv', k=k, cin=cin, cout=cout, h=h, w=w, act=act, src=src))

    def pool(name, c, h, w, s):
        L.append(dict(name=name, op='maxpool', k=2, cin=c, cout=c, h=h // s if s == 2 else h, w=w // s if s == 2 else w, stride=s, ih=h, iw=w))

    h, w = in_h, in_w
    c0, c1, c2, c3, c4, c5, c6 = (ch(x, width) for x in (16, 32, 64, 128, 256, 512, 1024))
    if CH_OVERRIDE:
        c0, c1, c2, c3, c4, c5, c6 = CH_OVERRIDE[:7]
    conv('conv0', 3, c0, 3, h, w)
    pool('pool1', c0, h, w, 2); h //= 2; w //= 2
    conv('conv2', c0, c1, 3, h, w)
    pool('pool3', c1, h, w, 2); h //= 2; w //= 2
    conv('conv4', c1, c2, 3, h, w)
    pool('pool5', c2, h, w, 2); h //= 2; w //= 2
    conv('conv6', c2, c3, 3, h, w)
    pool('pool7', c3, h, w, 2); h //= 2; w //= 2
    conv('conv8', c3, c4, 3, h, w)                   # route source for the second scale (stride 16)
    L[-1]['route'] = True                            # its UNPOOLED output is needed by the concat, so pool9 cannot be fused into it
    h8, w8 = h, w
    pool('pool9', c4, h, w, 2); h //= 2; w //= 2
    conv('conv10', c4, c5, 3, h, w)
    if not DROP_POOL11:
        pool('pool11', c5, h, w, 1)
    conv('conv12', c5, c6, 3, h, w)
    d1 = CH_OVERRIDE[7] if CH_OVERRIDE else ch(256, width)
    conv('conv13', c6, d1, 1, h, w)                  # route source for the upsample branch
    d2 = CH_OVERRIDE[8] if CH_OVERRIDE else ch(512, width)
    conv('conv14', d1, d2, 3, h, w)
    conv('head1', d2, head, 1, h, w, act=False)      # detection scale 1 (stride 32)
    d3 = CH_OVERRIDE[9] if CH_OVERRIDE else ch(128, width)
    conv('conv18', d1, d3, 1, h, w)
    L.append(dict(name='upsample', op='upsample', cin=d3, cout=d3, h=h8, w=w8))
    # concat with conv8 output: channels d3 + c4
    d4 = CH_OVERRIDE[10] if CH_OVERRIDE else ch(256, width)
    conv('conv21', d3 + c4, d4, 3, h8, w8)
    conv('head2', d4, head, 1, h8, w8, act=False)    # detection scale 2 (stride 16)
    return L


def analyse(L, lanes, clock_mhz, fuse=False):
    """fuse=True: a stride-2 max-pool that follows a convolution is done while the convolution writes its outputs (pooled map stored, no pass of its own)"""
    rows = []
    tot = dict(macs=0, wbytes=0, cycles=0, pbytes=0)
    max_tile = 0
    max_map = 0
    max_inout = 0
    for idx, l in enumerate(L):
        h, w, cin, cout = l['h'], l['w'], l['cin'], l['cout']
        nxt = L[idx + 1] if idx + 1 < len(L) else None
        prv = L[idx - 1] if idx > 0 else None
        if fuse and l['op'] == 'maxpool' and l['stride'] == 2 and prv is not None and prv['op'] == 'conv' and not prv.get('route'):
            rows.append((l['name'], 'fused', '%dx%dx%d' % (h, w, cout), 0, 0, 0, 0, 0))
            continue
        if l['op'] == 'conv':
            k = l['k']
            macs = h * w * cout * cin * k * k
            wb = cout * cin * k * k
            pb = cout * 8                                   # int32 bias + 16-bit multiplier + 8-bit shift + pad
            vec = h * w * int(math.ceil(cout / lanes))      # output vectors of `lanes` channels
            cyc = vec * max(cin * k * k, lanes + 1) + lanes + 14
            tile = min(lanes, cout) * cin * k * k
            max_tile = max(max_tile, tile)
            ib = (h + 2) * (w + 2) * cin if k == 3 else h * w * cin      # zero-padded input storage for 3x3
            ob = h * w * cout
            if fuse and nxt is not None and nxt['op'] == 'maxpool' and nxt['stride'] == 2 and not l.get('route'):
                ob = (h // 2) * (w // 2) * cout                 # only the pooled map is stored
            tot['macs'] += macs; tot['wbytes'] += wb; tot['cycles'] += cyc; tot['pbytes'] += pb
        elif l['op'] == 'maxpool':
            macs = wb = pb = 0
            cyc = h * w * int(math.ceil(cout / lanes)) * 4 if l['stride'] == 2 else l['ih'] * l['iw'] * int(math.ceil(cout / lanes)) * 4
            ib = l['ih'] * l['iw'] * cin
            ob = h * w * cout
            tot['cycles'] += cyc
        else:
            macs = wb = pb = 0
            cyc = h * w * int(math.ceil(cout / 16))          # copy 16 channels per cycle
            ib = (h // 2) * (w // 2) * cin
            ob = h * w * cout
            tot['cycles'] += cyc
        max_map = max(max_map, ob)
        max_inout = max(max_inout, ib + ob)
        rows.append((l['name'], l['op'], '%dx%dx%d' % (h, w, cout), macs, wb, ib, ob, cyc))
    ms = tot['cycles'] / (clock_mhz * 1e3)
    return rows, tot, dict(max_tile=max_tile, max_map=max_map, max_inout=max_inout, ms=ms, fps=1000.0 / ms)


def summary_line(width, in_w, in_h, classes, lanes, clock, fuse=False):
    L = build(width, in_w, in_h, classes)
    rows, tot, ex = analyse(L, lanes, clock, fuse)
    return dict(width=width, inp='%dx%d' % (in_w, in_h), classes=classes, lanes=lanes,
                params_M=tot['wbytes'] / 1e6, macs_M=tot['macs'] / 1e6, ms=ex['ms'], fps=ex['fps'],
                max_tile_KB=ex['max_tile'] / 1024.0, max_map_KB=ex['max_map'] / 1024.0, max_inout_KB=ex['max_inout'] / 1024.0,
                ddr_w_MBps=tot['wbytes'] / 1e6 * ex['fps'], layers=len(L), cycles_M=tot['cycles'] / 1e6)


def print_layers(width, in_w, in_h, classes, lanes, clock, csv_path=None, fuse=False):
    L = build(width, in_w, in_h, classes)
    rows, tot, ex = analyse(L, lanes, clock, fuse)
    print('%-8s %-8s %-12s %12s %10s %10s %10s %12s' % ('layer', 'op', 'out HxWxC', 'MACs', 'w bytes', 'act in B', 'act out B', 'cycles'))
    for r in rows:
        print('%-8s %-8s %-12s %12d %10d %10d %10d %12d' % r)
    print('-' * 100)
    print('total: %.3f M weights (int8), %.1f M MACs, per-channel params %d B, %.2f M engine cycles -> %.1f ms @ %g MHz = %.1f frames/s (lanes %d)' % (
        tot['wbytes'] / 1e6, tot['macs'] / 1e6, tot['pbytes'], tot['cycles'] / 1e6, ex['ms'], clock, ex['fps'], lanes))
    print('largest weight tile (lanes x Cin x k x k): %.1f KB   largest activation map: %.1f KB   largest input+output pair: %.1f KB' % (
        ex['max_tile'] / 1024.0, ex['max_map'] / 1024.0, ex['max_inout'] / 1024.0))
    print('weight traffic from DDR per frame: %.2f MB (every weight read once per frame) = %.1f MB/s at %.1f frames/s' % (
        tot['wbytes'] / 1e6, tot['wbytes'] / 1e6 * ex['fps'], ex['fps']))
    if csv_path:
        with open(csv_path, 'w', newline='', encoding='utf-8') as f:
            wr = csv.writer(f)
            wr.writerow(['layer', 'op', 'out_hxwxc', 'macs', 'weight_bytes', 'act_in_bytes', 'act_out_bytes', 'cycles'])
            wr.writerows(rows)


def sweep(classes, lanes, clock, fuse=False):
    print('%-6s %-8s %6s %9s %9s %9s %8s %10s %10s %10s' % ('width', 'input', 'lanes', 'weights M', 'MACs M', 'cycles M', 'fps', 'tile KB', 'map KB', 'in+out KB'))
    for width in (1.0, 0.5, 0.25):
        for inp in ((160, 96), (256, 160), (320, 192), (416, 416)):
            s = summary_line(width, inp[0], inp[1], classes, lanes, clock, fuse)
            print('%-6g %-8s %6d %9.2f %9.1f %9.2f %8.1f %10.1f %10.1f %10.1f' % (
                s['width'], s['inp'], s['lanes'], s['params_M'], s['macs_M'], s['cycles_M'], s['fps'], s['max_tile_KB'], s['max_map_KB'], s['max_inout_KB']))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--width', type=float, default=1.0)
    ap.add_argument('--input', default='160x96')
    ap.add_argument('--classes', type=int, default=3)
    ap.add_argument('--lanes', type=int, default=16)
    ap.add_argument('--clock', type=float, default=100.0)
    ap.add_argument('--csv')
    ap.add_argument('--sweep', action='store_true')
    ap.add_argument('--fuse-pool', action='store_true', help='stride-2 max-pools are done by the convolution that precedes them (not after the route source conv8)')
    ap.add_argument('--no-pool11', action='store_true', help='leave out the stride-1 max-pool of the original cfg')
    ap.add_argument('--ch', help='explicit channel plan c0,c1,c2,c3,c4,c5,c6,d1,d2,d3,d4 (overrides --width)')
    a = ap.parse_args()
    global DROP_POOL11, CH_OVERRIDE
    DROP_POOL11 = a.no_pool11
    CH_OVERRIDE = tuple(int(x) for x in a.ch.split(',')) if a.ch else None
    if a.sweep:
        for lanes in (8, 16):
            print('\n=== %d lanes @ %g MHz, %d classes ===' % (lanes, a.clock, a.classes))
            sweep(a.classes, lanes, a.clock, a.fuse_pool)
        return 0
    w, h = (int(x) for x in a.input.lower().split('x'))
    print_layers(a.width, w, h, a.classes, a.lanes, a.clock, a.csv, a.fuse_pool)
    return 0


if __name__ == '__main__':
    sys.exit(main())
