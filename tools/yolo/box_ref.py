#!/usr/bin/env python3
"""box_ref.py - integer reference of the input preprocessing of the PH1P35 detector (bit-exact model of rtl_custom/yolo_box_down.v)

A frame of IN_W x IN_H RGB pixels (8 bit per channel, raster order) is reduced by averaging non-overlapping BOX x BOX blocks:
    avg = (sum * RM + RA) >> RS          sum = the BOX * BOX values of one channel   (round half up of sum / BOX^2; for BOX = 10: RM 5243, RA 2^18, RS 19, exact for every sum 0 .. 25500)
    value = avg - 128                    int8, the network input (zero point 128; the letterbox rows and the zero border of the padded input map are 0 = mid grey)
The averaged image (IN_H / BOX rows) is placed PAD_TOP rows below the top of the network input (letterbox: 1280 x 720 -> 128 x 72 inside 128 x 96 for BOX = 10, PAD_TOP = 12).
Memory layout written by the downscaler: the padded input map (NET_H + 2) x (NET_W + 2) x 3 bytes, element (y, x, c) of the INTERIOR at ((y + 1) * (NET_W + 2) + x + 1) * 3 + c;
only the bytes of the averaged image are written; the letterbox rows and the border are cleared by `fill` descriptors of the engine (yolo_aux_core.v mode 4).
"""
import numpy as np


def avg_params(box):
    """(RM, RA, RS) of the round-half-up divide by box * box, verified exhaustively"""
    n = box * box
    for rs in range(4, 26):
        for rm in range(max(1, (1 << rs) // n - 2), (1 << rs) // n + 3):
            ra = (1 << rs) // 2
            if all(((s * rm + ra) >> rs) == ((2 * s + n) // (2 * n)) for s in range(0, n * 255 + 1)):
                return rm, ra, rs
    raise ValueError(box)


def downscale(frame, box, rm, ra, rs):
    """frame uint8 [H, W, 3] -> int8 [H / box, W / box, 3]"""
    h, w, _ = frame.shape
    s = frame.astype(np.int64).reshape(h // box, box, w // box, box, 3).sum(axis=(1, 3))
    avg = (s * rm + ra) >> rs
    return (avg - 128).astype(np.int8)


def padded_bytes(out, net_w, net_h, pad_top):
    """dict address -> byte of the interior writes"""
    d = {}
    oh, ow, _ = out.shape
    for y in range(oh):
        for x in range(ow):
            for c in range(3):
                d[(((y + pad_top + 1) * (net_w + 2)) + x + 1) * 3 + c] = int(out[y, x, c]) & 0xFF
    return d


if __name__ == '__main__':
    print('BOX 10:', avg_params(10), ' BOX 8:', avg_params(8), ' BOX 5:', avg_params(5))
