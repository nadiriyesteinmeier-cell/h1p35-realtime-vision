#!/usr/bin/env python3
"""mininet.py - a small network with the topology and the memory plan of the PH1P35 detector, run through the integer reference and written as memory images
for the testbench tb_custom/tb_yolo_net.v (rtl_custom/yolo_net_engine.v = sequencer + yolo_conv_core + yolo_aux_core + four activation banks)

The topology is the pruned YOLOv3-tiny-derived one of yolo_budget.py / yolo_memplan.py (conv0..conv14, two detection heads, the 1x1 + upsample + concat branch,
stride-1 pool of the original cfg left out) on a small input so that the simulation takes seconds; the channel counts are NOT multiples of the lane count on purpose.
Weights, biases and requantisation constants are RANDOM - this proves the data flow (addresses, banks, padding, borders, route / concat, fused and standalone
pooling, upsampling, partial tiles) bit for bit against qref.py, it is not a trained network.

Memory plan (bank = ping-pong A / B, C = concat buffer, D = detection head outputs; a layer reads one bank and writes another one):
  A: IN T3 T7 T10 T13 T21      B: T1 T5 T9 T12 T14 T18      C: CAT = [upsampled conv18 | conv8 output] (also the route source of pool9)      D: H1 H2
Every tensor that a 3x3 convolution reads is stored with a one-pixel zero border; because tensors of different size reuse the same bank, the border is cleared
by two `fill` descriptors (rows 0 / H+1, columns 0 / W+1) before the tensor is produced - the bank contents of the previous tenant would otherwise act as padding.

Files written for a case <prefix>: _cfg.txt (nlayers n_exp in_size), _desc.hex (208 bit per layer), _wt.hex, _pm.hex, _in.hex (the padded input map, loaded into
bank A by the host port), _exp.hex (48 bit per line {layer[47:40], bank[39:36], addr[35:8], value[7:0]}: what a bank must hold when that layer is done).
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import qref
import gen_conv_vectors as gcv

A, B, C, D = 0, 1, 2, 3
OP_CONV, OP_COPY, OP_UP, OP_POOL2, OP_POOL1, OP_FILL = 0, 1, 2, 3, 4, 5


class T(object):
    """a tensor in a bank: h x w x c logical, stored with `pad` border pixels, `ct` channels per pixel, channel offset `coff`, at byte offset `base`"""

    def __init__(self, name, bank, h, w, ct, coff, c, pad, base=0):
        self.name, self.bank, self.h, self.w, self.ct, self.coff, self.c, self.pad, self.base = name, bank, h, w, ct, coff, c, pad, base

    @property
    def row(self):
        return (self.w + 2 * self.pad) * self.ct

    @property
    def pix(self):
        return self.ct

    @property
    def origin(self):                    # address of interior element (0, 0, channel 0 of this view)
        return self.base + (self.pad * (self.w + 2 * self.pad) + self.pad) * self.ct + self.coff

    @property
    def corner(self):                    # address of the padded corner (-1, -1) at this view's channel offset (3x3 convolutions start here)
        return self.base + self.coff

    @property
    def size(self):
        return (self.h + 2 * self.pad) * (self.w + 2 * self.pad) * self.ct

    def view(self, name, coff, c):
        return T(name, self.bank, self.h, self.w, self.ct, coff, c, self.pad, self.base)

    def addr(self, y, x, ch):
        return self.origin + y * self.row + x * self.pix + ch


def pack_desc(op, src, dst, h, w, cin, cout, k3, act, pool, in_base, in_row, in_pix, out_base, out_row, out_pix, wt_base, pm_base):
    v = 0
    for val, lo, width in ((op, 0, 3), (src, 3, 2), (dst, 5, 2), (h, 7, 12), (w, 19, 12), (cin, 31, 11), (cout, 42, 11), (k3, 53, 1), (act, 54, 1), (pool, 55, 1),
                           (in_base, 56, 20), (in_row, 76, 20), (in_pix, 96, 20), (out_base, 116, 20), (out_row, 136, 20), (out_pix, 156, 20),
                           (wt_base, 176, 14), (pm_base, 190, 11)):
        assert 0 <= val < (1 << width), (val, lo, width)
        v |= val << lo
    return v


def conv_acc(x, wt, k):
    h, w, _ = x.shape
    xp = qref.padded_hwc(x, k // 2).astype(np.int64)
    acc = np.zeros((h, w, wt.shape[0]), dtype=np.int64)
    for ky in range(k):
        for kx in range(k):
            acc += np.tensordot(xp[ky:ky + h, kx:kx + w, :], wt[:, :, ky, kx].astype(np.int64), axes=([2], [1]))
    return acc


class Net(object):
    def __init__(self, lanes, seed, qparams=None):
        self.lanes = lanes
        self.qp = qparams or {}                 # layer name -> (weights int8 [cout, cin, k, k], bias int64, mult, shift) from quantize.py; layers not listed get random ones
        self.rng = np.random.default_rng(seed)
        self.layers = []          # dict(desc=int, name=str, exp=[(bank, addr, val)])
        self.wt_words = []
        self.pm_lines = []
        self.val = {}             # name -> int8 [h, w, c]
        self.acc_worst = {}       # name -> largest |acc| + |bias| seen (external parameters only; must stay below 2^31)

    # ---------------------------------------------------------------- layers
    def conv(self, name, src, dst, cout, k, act, pool):
        """src / dst: T views; pool = fused 2x2 max-pool (dst is then the pooled map)"""
        rng = self.rng
        x = self.val[src.name]
        h, w, cin = x.shape
        assert cin == src.c and dst.c == cout
        if name in self.qp:
            wt, bias, mult, shift = (np.asarray(v) for v in self.qp[name])
            wt, bias, mult, shift = wt.astype(np.int8), bias.astype(np.int64), mult.astype(np.int64), shift.astype(np.int64)
            assert wt.shape == (cout, cin, k, k), (name, wt.shape, (cout, cin, k, k))
            acc = conv_acc(x, wt, k)
            worst = int((np.abs(acc).reshape(-1, cout).max(axis=0) + np.abs(bias)).max())
            if worst >= (1 << 31):                                   # the 32-bit accumulator of the core would wrap
                raise ValueError('layer %s: |acc| + |bias| = %d does not fit 32 bits' % (name, worst))
            self.acc_worst[name] = worst
        else:
            wt = rng.integers(-128, 128, size=(cout, cin, k, k)).astype(np.int8)
            acc = conv_acc(x, wt, k)
            accmax = np.abs(acc).reshape(-1, cout).max(axis=0)
            bias = np.array([int(rng.uniform(-0.5, 0.5) * max(1, int(a))) for a in accmax], dtype=np.int64)
            mult, shift = gcv.choose_requant(accmax + np.abs(bias), cout, rng, 90)
        out = qref.conv2d(x, wt, bias, mult, shift, act, k)
        if pool:
            out = qref.maxpool2(out, 2)
        assert out.shape == (dst.h, dst.w, cout), (name, out.shape, (dst.h, dst.w, cout))
        words = qref.pack_weights(wt, self.lanes)
        wt_base, pm_base = len(self.wt_words), len(self.pm_lines)
        self.wt_words += list(words)
        for c in range(cout):
            self.pm_lines.append(qref.param_word(bias[c], mult[c], shift[c]))
        in_base = src.corner if k == 3 else src.origin
        if k == 3:
            assert src.pad == 1
        desc = pack_desc(OP_CONV, src.bank, dst.bank, h, w, cin, cout, 1 if k == 3 else 0, 1 if act else 0, 1 if pool else 0,
                         in_base, src.row, src.pix, dst.origin, dst.row, dst.pix, wt_base, pm_base)
        self.val[dst.name] = out
        self.layers.append(dict(desc=desc, name=name, exp=self._exp_tensor(dst, out)))

    def aux(self, name, op, src, dst):
        x = self.val[src.name]
        if op == OP_COPY:
            out = x.copy()
        elif op == OP_UP:
            out = qref.upsample2(x)
        elif op == OP_POOL2:
            out = qref.maxpool2(x, 2)
        else:
            out = qref.maxpool2(x, 1)
        ho, wo, co = out.shape
        assert (ho, wo, co) == (dst.h, dst.w, dst.c), (name, out.shape, (dst.h, dst.w, dst.c))
        desc = pack_desc(op, src.bank, dst.bank, ho, wo, co, 0, 0, 0, 0, src.origin, src.row, src.pix, dst.origin, dst.row, dst.pix, 0, 0)
        self.val[dst.name] = out
        self.layers.append(dict(desc=desc, name=name, exp=self._exp_tensor(dst, out)))

    def fill_rect(self, name, bank, base, h, w, ct, row, pix):
        """one fill descriptor: h x w pixels of ct channels set to 0, starting at byte `base`, row / pixel strides in bytes"""
        d = pack_desc(OP_FILL, 0, bank, h, w, ct, 0, 0, 0, 0, 0, 0, 0, base, row, pix, 0, 0)
        exp = [(bank, base + y * row + x * pix + ch, 0) for y in range(h) for x in range(w) for ch in range(ct)]
        self.layers.append(dict(desc=d, name=name, exp=exp))

    def fill(self, name, t):
        """clear the one-pixel border of the padded tensor t (all channels): two descriptors"""
        assert t.pad == 1
        H, W, ct = t.h, t.w, t.ct
        exp = []
        # rows 0 and H + 1
        d1 = pack_desc(OP_FILL, 0, t.bank, 2, W + 2, ct, 0, 0, 0, 0, 0, 0, 0, t.base, (H + 1) * t.row, ct, 0, 0)
        for y in (0, H + 1):
            for x in range(W + 2):
                for ch in range(ct):
                    exp.append((t.bank, t.base + y * t.row + x * ct + ch, 0))
        self.layers.append(dict(desc=d1, name=name + '_rows', exp=exp))
        # columns 0 and W + 1 of rows 1 .. H
        d2 = pack_desc(OP_FILL, 0, t.bank, H, 2, ct, 0, 0, 0, 0, 0, 0, 0, t.base + t.row, t.row, (W + 1) * ct, 0, 0)
        exp = []
        for y in range(1, H + 1):
            for x in (0, W + 1):
                for ch in range(ct):
                    exp.append((t.bank, t.base + y * t.row + x * ct + ch, 0))
        self.layers.append(dict(desc=d2, name=name + '_cols', exp=exp))

    @staticmethod
    def _exp_tensor(dst, out):
        exp = []
        h, w, c = out.shape
        for y in range(h):
            for x in range(w):
                for ch in range(c):
                    exp.append((dst.bank, dst.addr(y, x, ch), int(out[y, x, ch]) & 0xFF))
        return exp


def build(in_w, in_h, ch, lanes, seed, classes=3, qparams=None, image=None, letterbox=None):
    """ch = (c0 .. c6, d1, d2, d3, d4); returns (Net, input tensor, dict of tensors)"""
    c0, c1, c2, c3, c4, c5, c6, d1, d2, d3, d4 = ch
    head = 3 * (5 + classes)
    n = Net(lanes, seed, qparams)
    h1, w1 = in_h // 2, in_w // 2
    h2, w2 = h1 // 2, w1 // 2
    h3, w3 = h2 // 2, w2 // 2
    h4, w4 = h3 // 2, w3 // 2
    h5, w5 = h4 // 2, w4 // 2
    IN = T('IN', A, in_h, in_w, 3, 0, 3, 1)
    T1 = T('T1', B, h1, w1, c0, 0, c0, 1)
    T3 = T('T3', A, h2, w2, c1, 0, c1, 1)
    T5 = T('T5', B, h3, w3, c2, 0, c2, 1)
    T7 = T('T7', A, h4, w4, c3, 0, c3, 1)
    CAT = T('CAT', C, h4, w4, d3 + c4, 0, d3 + c4, 1)
    CUP = CAT.view('CUP', 0, d3)
    C8 = CAT.view('C8', d3, c4)
    T9 = T('T9', B, h5, w5, c4, 0, c4, 1)
    T10 = T('T10', A, h5, w5, c5, 0, c5, 1)
    T12 = T('T12', B, h5, w5, c6, 0, c6, 0)
    T13 = T('T13', A, h5, w5, d1, 0, d1, 1)
    T14 = T('T14', B, h5, w5, d2, 0, d2, 0)
    T18 = T('T18', B, h5, w5, d3, 0, d3, 0)
    T21 = T('T21', A, h4, w4, d4, 0, d4, 0)
    H1 = T('H1', D, h5, w5, head, 0, head, 0, 0)
    H2 = T('H2', D, h4, w4, head, 0, head, 0, H1.size)
    x = n.rng.integers(-128, 128, size=(in_h, in_w, 3)).astype(np.int8) if image is None else np.asarray(image).astype(np.int8)
    assert x.shape == (in_h, in_w, 3), x.shape
    n.val['IN'] = x
    if letterbox is not None:
        # board configuration: the downscaler writes only the image rows (pad_top + 1 .. pad_top + img_rows of the padded map); the letterbox rows, the border rows
        # and the border columns are cleared here (int8 0 = mid grey) - three descriptors at the start of every inference
        pad_top, img_rows = letterbox
        r = IN.row
        n.fill_rect('lb_top', A, IN.base, pad_top + 1, in_w + 2, 3, r, 3)
        n.fill_rect('lb_bottom', A, IN.base + (pad_top + 1 + img_rows) * r, in_h + 1 - pad_top - img_rows, in_w + 2, 3, r, 3)
        n.fill_rect('lb_sides', A, IN.base + (pad_top + 1) * r, img_rows, 2, 3, r, (in_w + 1) * 3)
    n.fill('fill_T1', T1)
    n.conv('conv0', IN, T1, c0, 3, True, True)
    n.fill('fill_T3', T3)
    n.conv('conv2', T1, T3, c1, 3, True, True)
    n.fill('fill_T5', T5)
    n.conv('conv4', T3, T5, c2, 3, True, True)
    n.fill('fill_T7', T7)
    n.conv('conv6', T5, T7, c3, 3, True, True)
    n.fill('fill_CAT', CAT)
    n.conv('conv8', T7, C8, c4, 3, True, False)
    n.fill('fill_T9', T9)
    n.aux('pool9', OP_POOL2, C8, T9)
    n.fill('fill_T10', T10)
    n.conv('conv10', T9, T10, c5, 3, True, False)
    n.conv('conv12', T10, T12, c6, 3, True, False)
    n.fill('fill_T13', T13)
    n.conv('conv13', T12, T13, d1, 1, True, False)
    n.conv('conv14', T13, T14, d2, 3, True, False)
    n.conv('head1', T14, H1, head, 1, False, False)
    n.conv('conv18', T13, T18, d3, 1, True, False)
    n.aux('upsample', OP_UP, T18, CUP)
    n.val['CAT'] = qref.concat(n.val['CUP'], n.val['C8'])        # channel order of the concat buffer: [upsampled | conv8]
    n.conv('conv21', CAT, T21, d4, 3, True, False)
    n.conv('head2', T21, H2, head, 1, False, False)
    tens = dict(IN=IN, T1=T1, T3=T3, T5=T5, T7=T7, CAT=CAT, T9=T9, T10=T10, T12=T12, T13=T13, T14=T14, T18=T18, T21=T21, H1=H1, H2=H2)
    return n, IN, tens, x


def write_case(prefix, in_w, in_h, ch, lanes, seed, qparams=None, image=None, letterbox=None):
    n, IN, tens, x = build(in_w, in_h, ch, lanes, seed, qparams=qparams, image=image, letterbox=letterbox)
    os.makedirs(os.path.dirname(prefix), exist_ok=True)
    # the CAT view tensors carry the same logical content as the parts: the value of CAT itself (concat) is checked through conv21 and head2
    img = np.zeros(IN.size, dtype=np.uint8)
    for y in range(in_h):
        for xx in range(in_w):
            for c in range(3):
                img[IN.addr(y, xx, c)] = int(x[y, xx, c]) & 0xFF
    with open(prefix + '_in.hex', 'w') as f:
        for v in img:
            f.write('%02X\n' % v)
    with open(prefix + '_desc.hex', 'w') as f:
        for l in n.layers:
            f.write('%052X\n' % l['desc'])
    with open(prefix + '_wt.hex', 'w') as f:
        for wd in n.wt_words:
            f.write(qref.word_hex(wd) + '\n')
    with open(prefix + '_pm.hex', 'w') as f:
        for p in n.pm_lines:
            f.write(p + '\n')
    n_exp = 0
    with open(prefix + '_exp.hex', 'w') as f:
        for li, l in enumerate(n.layers):
            for (bank, addr, val) in l['exp']:
                f.write('%02X%X%07X%02X\n' % (li, bank, addr, val))
                n_exp += 1
    with open(prefix + '_cfg.txt', 'w') as f:
        f.write('%d %d %d %d %d\n' % (len(n.layers), n_exp, img.size, len(n.wt_words), len(n.pm_lines)))
    sizes = {}
    for t in tens.values():
        sizes[t.bank] = max(sizes.get(t.bank, 0), t.base + t.size)
    return dict(layers=[l['name'] for l in n.layers], n_exp=n_exp, bank_bytes=sizes, wt_words=len(n.wt_words), pm=len(n.pm_lines), heads=(n.val['H1'].shape, n.val['H2'].shape),
                head1=n.val['H1'], head2=n.val['H2'])


# small topology: 96 x 64 input; the channel counts are not multiples of 8 / 16 lanes on purpose
CASES = [
    ('net_a', 96, 64, (8, 8, 16, 16, 24, 32, 40, 16, 32, 8, 24), 7),
    ('net_b', 64, 32, (8, 16, 8, 24, 16, 20, 28, 12, 20, 12, 18), 8),
]


def main():
    lanes = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    outdir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, '..', '..', 'logs_custom', 'yolo_vec', 'net%d' % lanes)
    for (nm, w, h, ch, seed) in CASES:
        r = write_case(os.path.join(os.path.normpath(outdir), nm), w, h, ch, lanes, seed)
        print('%-6s %dx%d ch=%s: %d layers, %d expected bytes, banks %s, %d weight words, %d parameter lines' % (nm, w, h, ch, len(r['layers']), r['n_exp'], r['bank_bytes'], r['wt_words'], r['pm']))


if __name__ == '__main__':
    main()
