#!/usr/bin/env python3
"""Offline sanity checks of the *contract numbers and oracle methods* used by the
Verilog testbenches in this directory.

What this script does:
  1. Re-derives the numbers written in handoff/FIRST_TASK.md (gray values,
     maximum sum, width limits) with a second, independent calculation.
  2. Shows that the 8-bit-overflow bug in color_segment is a real, detectable
     failure and that the sweeps in tb_color_segment.v cover it (mutant analysis
     done on the arithmetic only).
  3. Checks that the "occupancy scan" oracle used in tb_frame_bbox.v gives the
     same box as a plain min/max on random hit maps (validates the METHOD).

What this script does NOT do: it does not read, simulate or verify any RTL.
Passing here says nothing about rtl_custom/*.v. Seeds are fixed and printed.

Usage:  python contract_check.py        (needs numpy)
Exit code 0 = all checks passed, 1 = at least one failed.
"""
import random
import sys

import numpy as np

SEED = 20261005
fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (f"  [{detail}]" if detail else ""))
    if not cond:
        fails.append(name)


# ---------------------------------------------------------------- 1. gray
print("== rgb_to_gray contract numbers")
y = lambda r, g, b: (77 * r + 150 * g + 29 * b) // 256
check("black = 0", y(0, 0, 0) == 0)
check("red   = 76", y(255, 0, 0) == 76, f"77*255={77*255}")
check("green = 149", y(0, 255, 0) == 149, f"150*255={150*255}")
check("blue  = 28", y(0, 0, 255) == 28, f"29*255={29*255}")
check("white = 255", y(255, 255, 255) == 255)
check("max sum = 65280 < 2^16 (16-bit sum cannot overflow)",
      77 * 255 + 150 * 255 + 29 * 255 == 65280 < 65536)
check("77+150+29 = 256 so (v,v,v) -> v for all v", all(y(v, v, v) == v for v in range(256)))

r = np.arange(1 << 24, dtype=np.uint32)
R, G, B = (r >> 16) & 255, (r >> 8) & 255, r & 255
s = 77 * R + 150 * G + 29 * B
y_shift = s >> 8                                    # what a bit slice gives
y_float = np.floor(s.astype(np.float64) / 256.0)    # independent route
check("floor(sum/256) == sum>>8 for all 2^24 colours", np.array_equal(y_shift, y_float.astype(np.uint32)))
check("Y in 0..255 for all 2^24 colours", int(y_shift.max()) == 255 and int(y_shift.min()) == 0)
check("1280*720 = 921600 fits in 20 bit counter", 1280 * 720 == 921600 < (1 << 20))

# ---------------------------------------------------------------- 2. segment
print("== color_segment: arithmetic mutant analysis (all 2^24 colours)")


def hit_correct(R, G, B, rmin, delta):
    R, G, B = R.astype(np.int32), G.astype(np.int32), B.astype(np.int32)
    return (R >= rmin) & ((R - G) >= delta) & ((R - B) >= delta)


def hit_wrap8(R, G, B, rmin, delta):
    # buggy variant: G+DELTA / B+DELTA computed in 8 bit and wrapped
    R = R.astype(np.int32)
    gd = (G.astype(np.int32) + delta) & 255
    bd = (B.astype(np.int32) + delta) & 255
    return (R >= rmin) & (R >= gd) & (R >= bd)


for name, rmin, delta in (("A default", 80, 30), ("C", 200, 60), ("D", 255, 255)):
    good = hit_correct(R, G, B, rmin, delta)
    bug = hit_wrap8(R, G, B, rmin, delta)
    diff = int(np.count_nonzero(good != bug))
    print(f"      {name}: R_MIN={rmin} DELTA={delta}: hits(correct)={int(good.sum())} "
          f"hits(wrap8 bug)={int(bug.sum())} differing colours={diff}")
    check(f"{name}: the 8-bit wrap bug changes the result (so a test can see it)", diff > 0)

# the exact sweeps used in tb_color_segment.v: R in {79,80,81,110,199,200,254,255}, G sweep with B=0,
# B sweep with G=0, G=B sweep; plus the R x G plane for B in {0,29,30,31,225,226,255}
rs = (79, 80, 81, 110, 199, 200, 254, 255)
v = np.arange(256, dtype=np.uint32)
pts = []
for rr in rs:
    pts += [(rr, g, 0) for g in v] + [(rr, 0, b) for b in v] + [(rr, x, x) for x in v]
for bb in (0, 29, 30, 31, 225, 226, 255):
    pts += [(i, j, bb) for i in range(256) for j in range(256)]
P = np.array(pts, dtype=np.uint32)
for name, rmin, delta in (("A default", 80, 30), ("C", 200, 60)):
    good = hit_correct(P[:, 0], P[:, 1], P[:, 2], rmin, delta)
    bug = hit_wrap8(P[:, 0], P[:, 1], P[:, 2], rmin, delta)
    n = int(np.count_nonzero(good != bug))
    check(f"{name}: TB sweeps contain colours that expose the wrap bug", n > 0, f"{n} of {len(P)} sweep pixels")
# the specific boundary pixels listed in the TB
check("A: (255,226,0) must NOT hit (226+30 = 256)", not hit_correct(np.array([255]), np.array([226]), np.array([0]), 80, 30)[0])
check("A: (255,225,225) must hit (225+30 = 255)", hit_correct(np.array([255]), np.array([225]), np.array([225]), 80, 30)[0])
check("A: (80,50,50) must hit, (80,51,50) and (79,0,0) must not",
      hit_correct(np.array([80]), np.array([50]), np.array([50]), 80, 30)[0]
      and not hit_correct(np.array([80]), np.array([51]), np.array([50]), 80, 30)[0]
      and not hit_correct(np.array([79]), np.array([0]), np.array([0]), 80, 30)[0])

# ---------------------------------------------------------------- 3. bbox oracle method
print("== frame_bbox: occupancy-scan oracle vs plain min/max on random maps")
rnd = random.Random(SEED)
bad = 0
for trial in range(3000):
    w, h = rnd.randint(1, 40), rnd.randint(1, 30)
    p = rnd.choice((0.0, 0.01, 0.05, 0.3, 1.0))
    hm = [[rnd.random() < p for _ in range(w)] for _ in range(h)]
    cnt = sum(map(sum, hm))
    col = [any(hm[y][x] for y in range(h)) for x in range(w)]
    row = [any(hm[y]) for y in range(h)]
    if cnt == 0:
        continue
    box_scan = (col.index(True), w - 1 - col[::-1].index(True), row.index(True), h - 1 - row[::-1].index(True))
    xs = [x for y in range(h) for x in range(w) if hm[y][x]]
    ys = [y for y in range(h) for x in range(w) if hm[y][x]]
    box_minmax = (min(xs), max(xs), min(ys), max(ys))
    if box_scan != box_minmax:
        bad += 1
check("occupancy scan == min/max on 3000 random maps", bad == 0, f"seed={SEED}")
check("centre of full 1280x720 frame = (639,359)", ((0 + 1279) >> 1, (0 + 719) >> 1) == (639, 359))
check("(xmin+xmax) needs 13 bit: 4095+4095 = 8190 < 8192", 4095 + 4095 < 8192)
check("CNT_W=4 saturation value = 15", (1 << 4) - 1 == 15)

print()
if fails:
    print("contract_check: FAILED:", ", ".join(fails))
    sys.exit(1)
print("contract_check: all checks passed (this is NOT an RTL verification)")
