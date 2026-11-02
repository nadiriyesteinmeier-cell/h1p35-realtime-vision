#!/usr/bin/env python3
"""Independent golden model of osd_overlay for tb_osd_overlay.v.

It is written from the specification in rtl_custom/osd_overlay.v's header / docs/ALGORITHM_INTERFACE.md,
it does not read any RTL. Inputs are the font and logo assets (tb_custom/osd_assets/*.npy) only.

For every scenario (osd state) it renders the full 1280x720 expected frame on top of a synthetic
background and writes, into tb_custom/osd_assets/golden/:
  state_<k>.hex  one line, the 128-bit osd state, packed as
                 {flags[4:0], mode[1:0], valid, xmin[11:0], xmax[11:0], ymin[11:0], ymax[11:0],
                  cx[11:0], cy[11:0], count[19:0], line_x[11:0], cross[15:0]}
  exp_<k>.hex    sparse list of the pixels that differ from the background, ascending pixel index
                 (y*1280+x), one 48-bit word per line {index[23:0], rgb[23:0]}, padded with FFFFFF000000 terminators up to 131072 words.

Background (identical formula in the testbench): R=(5x+3y)&255, G=(x^y)&255, B=(2x+(y>>1))&255.
Run:  python gen_osd_golden.py     (numpy only; deterministic)
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "osd_assets")
OUT = os.path.join(ASSETS, "golden")

W, H = 1280, 720
SP_DEPTH = 131072          # depth of the sparse array in tb_osd_overlay.v
# defaults of osd_overlay
LOGO_X, LOGO_Y = 16, 16
TEXT_X, TEXT_Y = 200, 16
SCALE = 1
COLS, ROWS = 22, 6
TEXT_COLOR, BOX_COLOR, CROSS_COLOR, LINE_COLOR, PLATE_COLOR = 0xFFFFFF, 0x00FF40, 0xFF3030, 0x00E5FF, 0xFFFFFF
PLATE_A = 12
ARM = 12
NAVY, RED = (28, 45, 78), (237, 28, 36)

# (flags, mode, valid, xmin, xmax, ymin, ymax, cx, cy, count, line_x, cross)
# The order matters: consecutive frames differ in exactly the fields that the first pixel (0,0) of the next
# frame must already see (the controls are sampled on the pixel with in_sof, that pixel uses the NEW values):
#   S0 -> S1: S1 enables the counting line and puts it at x = 0, S0 had it off      (flags / line_x at pixel (0,0))
#   S4 -> S5: S5 enables the box and its outer frame covers pixel (0,0), S4 had everything off  (flags/valid/xmin/ymin)
SCENARIOS = [
    dict(flags=0b10111, mode=0, valid=1, xmin=300, xmax=500, ymin=120, ymax=260, cx=400, cy=190, count=20000, line_x=640, cross=7),
    dict(flags=0b11111, mode=2, valid=1, xmin=100, xmax=260, ymin=40, ymax=150, cx=180, cy=95, count=1048575, line_x=0, cross=65535),
    dict(flags=0b11111, mode=3, valid=0, xmin=700, xmax=800, ymin=300, ymax=400, cx=750, cy=350, count=0, line_x=100, cross=0),
    dict(flags=0b11110, mode=1, valid=1, xmin=1270, xmax=1279, ymin=710, ymax=719, cx=1274, cy=714, count=5, line_x=1279, cross=1234),
    # valid=0 here and valid=1 (box frame touching pixel (0,0)) in the next state: the first pixel of frame 5 must already
    # use the NEW valid, otherwise that pixel misses the box corner (kills 'osd_first_pixel_old_valid')
    dict(flags=0b00000, mode=0, valid=0, xmin=10, xmax=20, ymin=10, ymax=20, cx=15, cy=15, count=99, line_x=50, cross=3),
    dict(flags=0b00110, mode=0, valid=1, xmin=2, xmax=60, ymin=2, ymax=60, cx=31, cy=31, count=777, line_x=300, cross=9),
    dict(flags=0b00001, mode=1, valid=1, xmin=500, xmax=600, ymin=500, ymax=600, cx=550, cy=550, count=123456, line_x=700, cross=42),
]


def pack_state(s):
    v = 0
    for val, width in ((s["flags"], 5), (s["mode"], 2), (s["valid"], 1), (s["xmin"], 12), (s["xmax"], 12),
                       (s["ymin"], 12), (s["ymax"], 12), (s["cx"], 12), (s["cy"], 12), (s["count"], 20),
                       (s["line_x"], 12), (s["cross"], 16)):
        assert 0 <= val < (1 << width), (val, width)
        v = (v << width) | val
    return v


def background():
    y, x = np.mgrid[0:H, 0:W].astype(np.int64)
    r = (x * 5 + y * 3) & 255
    g = (x ^ y) & 255
    b = (x * 2 + (y >> 1)) & 255
    return np.stack([r, g, b], axis=-1)


def rgb_tuple(c):
    return ((c >> 16) & 255, (c >> 8) & 255, c & 255)


def text_rows(s):
    valid = s["valid"]
    rows = []
    r0 = [0x80, 0x81, 0x82, 0x83, 0x20] + [ord(c) for c in "PH1P35"] + [0x20] + list(range(0x84, 0x8C))
    rows.append(r0)
    rows.append([ord(c) for c in "MODE:" + ["ORIG", "GRAY", "MASK", "TINT"][s["mode"]]])
    rows.append([ord(c) for c in "TARGET:" + ("FOUND" if valid else "LOST ")])
    xs = "%04d" % s["cx"] if valid else "----"
    ys = "%04d" % s["cy"] if valid else "----"
    rows.append([ord(c) for c in "X:" + xs + " Y:" + ys])
    rows.append([ord(c) for c in "AREA:" + "%06d" % min(s["count"], 999999)])
    rows.append([ord(c) for c in "CROSS:" + "%05d" % s["cross"]])
    return [r + [0x20] * (COLS - len(r)) for r in rows]


def render(s, font, logo, bg=None):
    v = background() if bg is None else bg.copy()
    flags = s["flags"]
    text_on, box_on, cross_on, line_on, logo_on = [(flags >> i) & 1 for i in range(5)]
    tw, th = (COLS * 8) << SCALE, (ROWS * 16) << SCALE
    lw, lh = logo.shape[1], logo.shape[0]
    assert (lw, lh) == (160, 94), "osd_overlay assumes the 160x94 logo"

    def rect(x0, x1, y0, y1):          # half-open, clipped to the frame
        return slice(max(y0, 0), max(min(y1, H), 0)), slice(max(x0, 0), max(min(x1, W), 0))

    # 1 text backing
    if text_on:
        ys, xs = rect(TEXT_X - 8, TEXT_X + tw + 8, TEXT_Y - 8, TEXT_Y + th + 8)
        v[ys, xs] = v[ys, xs] >> 1
    # 2 logo plate
    if logo_on:
        ys, xs = rect(LOGO_X - 6, LOGO_X + lw + 6, LOGO_Y - 6, LOGO_Y + lh + 6)
        pc = np.array(rgb_tuple(PLATE_COLOR), dtype=np.int64)
        v[ys, xs] = (v[ys, xs] * (16 - PLATE_A) + pc * PLATE_A) >> 4
    # 3 counting line
    if line_on:
        for x in (s["line_x"], s["line_x"] + 1):
            if 0 <= x < W:
                v[:, x] = rgb_tuple(LINE_COLOR)
    # 4 box: frame of 2 px outside [xmin..xmax]x[ymin..ymax]
    if box_on and s["valid"]:
        ys, xs = rect(s["xmin"] - 2, s["xmax"] + 3, s["ymin"] - 2, s["ymax"] + 3)
        saved = v[max(s["ymin"], 0):s["ymax"] + 1, max(s["xmin"], 0):s["xmax"] + 1].copy()
        v[ys, xs] = rgb_tuple(BOX_COLOR)
        v[max(s["ymin"], 0):s["ymax"] + 1, max(s["xmin"], 0):s["xmax"] + 1] = saved
    # 5 crosshair
    if cross_on and s["valid"]:
        cx, cy = s["cx"], s["cy"]
        for (x0, x1, y0, y1) in ((cx - ARM, cx + ARM + 1, cy - 1, cy + 2), (cx - 1, cx + 2, cy - ARM, cy + ARM + 1)):
            ys, xs = rect(x0, x1, y0, y1)
            v[ys, xs] = rgb_tuple(CROSS_COLOR)
    # 6 logo
    if logo_on:
        for ly in range(lh):
            for lx in range(lw):
                px = int(logo[ly, lx])
                a, cls = px & 31, (px >> 7) & 1
                if a == 0:
                    continue
                y, x = LOGO_Y + ly, LOGO_X + lx
                if 0 <= y < H and 0 <= x < W:
                    c = np.array(RED if cls else NAVY, dtype=np.int64)
                    v[y, x] = (v[y, x] * (16 - a) + c * a) >> 4
    # 7 text
    if text_on:
        tc = rgb_tuple(TEXT_COLOR)
        rows = text_rows(s)
        for r in range(ROWS):
            for c in range(COLS):
                code = rows[r][c]
                for gy in range(16):
                    bits = int(font[code, gy])
                    if not bits:
                        continue
                    for gx in range(8):
                        if (bits >> (7 - gx)) & 1:
                            y0 = TEXT_Y + ((r * 16 + gy) << SCALE)
                            x0 = TEXT_X + ((c * 8 + gx) << SCALE)
                            for dy in range(1 << SCALE):
                                for dx in range(1 << SCALE):
                                    v[y0 + dy, x0 + dx] = tc
    return v


# ---------------------------------------------------------------------------------------------------
# End-to-end chain (tb_osd_chain.v): real uivtc 1280x720 -> video_pos_adapter -> color_segment ->
# frame_bbox -> osd_overlay. The video is the synthetic image of tb_vtc_chk.v (IMAGE_MODE 1): frame k has
# a 0xFF2010 target rectangle number k%3, a green block and a dark-red block (R=79). The OSD of frame k
# must show the statistics of frame k-1 (one frame lag); frame 0 has no result yet.
# OSD controls in the chain testbench: flags 11111, mode 0, line_x 640, cross 3.
CHAIN_RECTS = [(100, 299, 50, 149), (900, 1000, 600, 700), (0, 15, 0, 15)]
CHAIN_FRAMES = 4


def chain_image(k):
    img = np.zeros((H, W, 3), dtype=np.int64)
    img[:, :] = (0x40, 0x40, 0x40)
    img[300:401, 400:801] = (0x10, 0xFF, 0x20)            # green block: not a hit
    img[300:311, 200:211] = (0x4F, 0x20, 0x20)            # R = 79: just below R_MIN
    x0, x1, y0, y1 = CHAIN_RECTS[k % 3]
    img[y0:y1 + 1, x0:x1 + 1] = (0xFF, 0x20, 0x10)        # target rectangle (drawn last: wins any overlap)
    return img


def chain_state(k):
    st = dict(flags=0b11111, mode=0, line_x=640, cross=3)
    if k == 0:
        st.update(valid=0, xmin=0, xmax=0, ymin=0, ymax=0, cx=0, cy=0, count=0)
    else:
        x0, x1, y0, y1 = CHAIN_RECTS[(k - 1) % 3]
        st.update(valid=1, xmin=x0, xmax=x1, ymin=y0, ymax=y1, cx=(x0 + x1) // 2, cy=(y0 + y1) // 2,
                  count=(x1 - x0 + 1) * (y1 - y0 + 1))
    return st


def write_sparse(path, img, bgimg):
    diff = np.any(img != bgimg, axis=-1)
    ys, xs = np.nonzero(diff)
    idx = ys * W + xs
    order = np.argsort(idx)
    lines = []
    for i in order:
        y, x = ys[i], xs[i]
        rgb = (int(img[y, x, 0]) << 16) | (int(img[y, x, 1]) << 8) | int(img[y, x, 2])
        lines.append("%06X%06X" % (int(idx[i]), rgb))
    assert len(lines) < SP_DEPTH, "sparse list longer than the testbench array"
    lines += ["FFFFFF000000"] * (SP_DEPTH - len(lines))
    open(path, "w").write("\n".join(lines) + "\n")
    return len(order)


def main():
    font = np.load(os.path.join(ASSETS, "font.npy"))
    logo = np.load(os.path.join(ASSETS, "logo.npy"))
    os.makedirs(OUT, exist_ok=True)
    bg = background()
    total = 0
    for k, s in enumerate(SCENARIOS):
        img = render(s, font, logo)
        n = write_sparse(os.path.join(OUT, "exp_%d.hex" % k), img, bg)
        open(os.path.join(OUT, "state_%d.hex" % k), "w").write("%032X\n" % pack_state(s))
        total += n
        print("scenario %d: flags=%s mode=%d valid=%d  differing pixels %d" % (k, format(s["flags"], "05b"), s["mode"], s["valid"], n))
    print("scenarios:", len(SCENARIOS), " total differing pixels:", total)
    for k in range(CHAIN_FRAMES):
        bgk = chain_image(k)
        img = render(chain_state(k), font, logo, bg=bgk)
        n = write_sparse(os.path.join(OUT, "chain_exp_%d.hex" % k), img, bgk)
        print("chain frame %d: differing pixels %d" % (k, n))


if __name__ == "__main__":
    sys.exit(main())
