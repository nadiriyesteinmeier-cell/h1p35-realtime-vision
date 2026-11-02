#!/usr/bin/env python3
"""qref.py - integer reference of the operators of the PH1P35 detector (bit-exact model of rtl_custom/yolo_conv_core.v and friends)

Data format
  activations  int8 (two's complement), symmetric quantisation (zero point 0), layout HWC: element (y, x, c) at (y * W + x) * C + c
  weights      int8, per-output-channel scale, layout [cout][cin][ky][kx] here (the hardware tile layout is built by pack_weights())
  per output channel: bias int32 (already in the accumulator scale), multiplier M uint16, shift S in 0..47
Convolution (stride 1, 'same' zero padding, k = 1 or 3):
  acc  = sum x * w                              (exact, int64 here; the hardware accumulator is 32 bits wide and the generator keeps |acc| < 2^31)
  v    = acc + bias                             (must stay inside int32)
  y    = (v * M + (S > 0 ? 1 << (S - 1) : 0)) >> S      arithmetic shift right = floor, round half up
  z    = clamp(y, -128, 127)
  out  = z                                       (linear layer, act = 0)
       | z >= 0 ? z : (z * 13 + 64) >> 7         (leaky ReLU with slope 13/128 = 0.1016, act = 1; arithmetic shift = floor)
max-pool 2x2 stride 2: max of the four int8 values; max-pool 2x2 stride 1 (darknet 'size=2 stride=1', right / bottom edge replicated): max over (y, x), (y, x+1), (y+1, x), (y+1, x+1)
upsample x2: nearest neighbour; concat: channel concatenation (HWC: per pixel the channels of the first tensor, then the second).
Everything is numpy int64 arithmetic, no floating point.
"""
import numpy as np

LEAKY_NUM = 13
LEAKY_SHIFT = 7


def clamp8(a):
    return np.clip(a, -128, 127)


def requant(v, mult, shift):
    """v int64 array (..., cout); mult, shift per channel (cout,)"""
    v = v.astype(np.int64)
    m = mult.astype(np.int64)
    s = shift.astype(np.int64)
    rnd = np.where(s > 0, np.left_shift(np.int64(1), np.maximum(s - 1, 0)), 0)
    return np.right_shift(v * m + rnd, s)


def leaky(z):
    z = z.astype(np.int64)
    return np.where(z >= 0, z, np.right_shift(z * LEAKY_NUM + (1 << (LEAKY_SHIFT - 1)), LEAKY_SHIFT))


def conv2d(x, w, bias, mult, shift, act, k):
    """x int8 [h, w, cin]; w int8 [cout, cin, k, k]; returns int8 [h, w, cout]"""
    h, wd, cin = x.shape
    cout = w.shape[0]
    assert w.shape == (cout, cin, k, k)
    p = k // 2
    xp = np.zeros((h + 2 * p, wd + 2 * p, cin), dtype=np.int64)
    xp[p:p + h, p:p + wd, :] = x
    acc = np.zeros((h, wd, cout), dtype=np.int64)
    for ky in range(k):
        for kx in range(k):
            win = xp[ky:ky + h, kx:kx + wd, :]                      # [h, w, cin]
            acc += np.tensordot(win, w[:, :, ky, kx].astype(np.int64), axes=([2], [1]))
    v = acc + bias.astype(np.int64)
    assert v.min() >= -(1 << 31) and v.max() < (1 << 31), 'accumulator + bias leaves the int32 range'
    y = requant(v, mult, shift)
    z = clamp8(y)
    out = leaky(z) if act else z
    return out.astype(np.int8)


def maxpool2(x, stride):
    h, w, c = x.shape
    xi = x.astype(np.int16)
    if stride == 2:
        assert h % 2 == 0 and w % 2 == 0
        return np.maximum(np.maximum(xi[0::2, 0::2], xi[0::2, 1::2]), np.maximum(xi[1::2, 0::2], xi[1::2, 1::2])).astype(np.int8)
    xp = np.concatenate([xi, xi[:, -1:, :]], axis=1)
    xp = np.concatenate([xp, xp[-1:, :, :]], axis=0)
    return np.maximum(np.maximum(xp[:-1, :-1], xp[:-1, 1:]), np.maximum(xp[1:, :-1], xp[1:, 1:])).astype(np.int8)


def upsample2(x):
    return np.repeat(np.repeat(x, 2, axis=0), 2, axis=1)


def concat(a, b):
    return np.concatenate([a, b], axis=2)


# ---------------------------------------------------------------- memory images for the hardware core
def pack_weights(w, lanes):
    """weights [cout, cin, k, k] -> list of tile words; tile t, tap (ky, kx, ci) = one word of `lanes` int8 (lane j = output channel t*lanes + j,
    missing channels = 0). Order inside a tile: ky, kx, ci (ci innermost), matching the address generator of yolo_conv_core.v."""
    cout, cin, k, _ = w.shape
    ntiles = (cout + lanes - 1) // lanes
    words = []
    for t in range(ntiles):
        for ky in range(k):
            for kx in range(k):
                for ci in range(cin):
                    word = []
                    for j in range(lanes):
                        oc = t * lanes + j
                        word.append(int(w[oc, ci, ky, kx]) if oc < cout else 0)
                    words.append(word)
    return words


def word_hex(word):
    """lanes int8 -> hex string, lane 0 in the least significant byte"""
    v = 0
    for j, b in enumerate(word):
        v |= (b & 0xFF) << (8 * j)
    return '%0*X' % (2 * len(word), v)


def param_word(bias, mult, shift):
    """{bias[31:0], mult[15:0], shift[5:0]} in 54 bits (14 hex digits)"""
    return '%014X' % (((int(bias) & 0xFFFFFFFF) << 22) | ((int(mult) & 0xFFFF) << 6) | (int(shift) & 0x3F))


def padded_hwc(x, pad):
    h, w, c = x.shape
    out = np.zeros((h + 2 * pad, w + 2 * pad, c), dtype=np.int8)
    out[pad:pad + h, pad:pad + w, :] = x
    return out
