#!/usr/bin/env python3
"""draw_robot_photos.py - annotated photos for the report: the whole system, and the WALL-E robot taken apart (user photos 2026-10-29)

    F:/yolo_env/Scripts/python.exe tools/report/draw_robot_photos.py docs/report/photos_src      (the user photos 64.jpg .. 67.jpg)
        ->  docs/report/img/{system_photo,robot_teardown}.png

Privacy (template rule: nothing that names the school): 65.jpg is cropped to the robot head (a bag with embroidered text is behind it);
in 67.jpg the mouse pad printing (text and line drawing) is blurred and the laptop at the top is cropped away. Labels name only what is visible;
chips that cannot be identified from the photo are not labelled.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
OUT = os.path.join(ROOT, 'docs', 'report', 'img')
SRC = sys.argv[1]
F = ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 34)
FS = ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 26)


def label(im, text, at, tip, font=F, fill=(255, 255, 255), fg=(20, 20, 20), line=(230, 40, 40)):
    """a text box at `at` (top-left) with an arrow to `tip`"""
    d = ImageDraw.Draw(im)
    w = d.textlength(text, font=font)
    h = font.size + 14
    x, y = at
    cx, cy = x + w / 2 + 10, y + h / 2
    d.line([(cx, cy), tip], fill=line, width=5)
    d.ellipse([tip[0] - 9, tip[1] - 9, tip[0] + 9, tip[1] + 9], fill=line)
    d.rounded_rectangle([x, y, x + w + 20, y + h], radius=8, fill=fill, outline=line, width=3)
    d.text((x + 10, y + 5), text, font=font, fill=fg)


def load(n):
    return Image.open(os.path.join(SRC, n)).convert('RGB')


# ------------------------------------------------------------------ whole system (64.jpg, 1440 x 1920)
im = load('64.jpg')
label(im, '显示器：YOLO 页（左上安路 Logo，右上延迟读数）', (40, 470), (900, 330))
label(im, 'HX1P35A 开发板 + SC500CS 摄像头', (40, 1500), (800, 1380))
label(im, 'ESP32 桥接板（J1 两根线）', (60, 1800), (790, 1750))
label(im, 'WALL-E 机器人', (60, 820), (300, 1000))
label(im, '识别目标（绿色铁框）', (330, 120), (200, 220))
label(im, '电脑：仅给 ESP32 供电并记录日志，不参与识别与控制', (560, 1020), (1300, 1500), font=FS)
im = im.resize((1080, 1440), Image.LANCZOS)
im.save(os.path.join(OUT, 'system_photo.png'))
print('wrote system_photo.png')

# ------------------------------------------------------------------ teardown panel
# (a) parts overview, 66.jpg 1440 x 1920
a = load('66.jpg')
label(a, '主控板', (980, 560), (850, 800))
label(a, '履带', (300, 380), (520, 450))
label(a, '3D 打印结构件', (330, 1520), (930, 1330))
label(a, '自攻螺丝', (180, 1130), (580, 1215))
a = a.resize((720, 960), Image.LANCZOS)
# (b) main board close-up from 66.jpg
b = load('66.jpg').crop((600, 690, 940, 960)).resize((1020, 810), Image.LANCZOS)
label(b, 'ESP32-S3 模组（屏蔽罩 + 板载天线）', (20, 20), (420, 300), font=FS)
label(b, '电源开关', (700, 20), (820, 250), font=FS)
label(b, 'USB Type-C', (690, 700), (830, 520), font=FS)
label(b, '屏幕排线座', (10, 560), (140, 360), font=FS)
label(b, 'JST 接插件（电机、舵机、电池等）', (150, 730), (420, 640), font=FS)
b = b.resize((720, 572), Image.LANCZOS)
# (c) board + battery + gear motor, 67.jpg 1920 x 1440: blur the mouse pad printing, crop the laptop away
c = load('67.jpg')
arr = np.asarray(c).astype(np.int16)
blur = np.asarray(c.filter(ImageFilter.GaussianBlur(28))).astype(np.int16)
H, W = arr.shape[:2]
yy, xx = np.mgrid[0:H, 0:W]
r, g, bb = arr[..., 0], arr[..., 1], arr[..., 2]
yellow = (r > 170) & (g > 130) & (bb < 110)
dark = (r < 90) & (g < 90) & (bb < 90)
zone = ((xx >= 1240) & (yy >= 230)) & ~((xx >= 1380) & (xx <= 1800) & (yy >= 600) & (yy <= 1130))
text_zone = (xx >= 1290) & (xx <= 1650) & (yy >= 260) & (yy <= 460)
m = (zone & ~yellow & ~dark) | text_zone
arr[m] = blur[m]
c = Image.fromarray(arr.clip(0, 255).astype(np.uint8)).crop((380, 170, 1920, 1440))
o = (380, 170)


def lc(t, at, tip):
    label(c, t, (at[0] - o[0], at[1] - o[1]), (tip[0] - o[0], tip[1] - o[1]))


lc('电源开关', (420, 200), (700, 300))
lc('USB Type-C（USB 串口 / 供电）', (400, 420), (770, 520))
lc('主控板（侧面）', (400, 640), (860, 700))
lc('锂电池', (1100, 300), (1000, 560))
lc('减速电机（履带驱动）', (1250, 1180), (1650, 950))
lc('电机连接线', (420, 1180), (650, 1000))
c = c.resize((720, int(720 * c.height / c.width)), Image.LANCZOS)
# (d) head, 65.jpg cropped to the robot (embroidered bag behind it)
dd = load('65.jpg').crop((0, 470, 1000, 1500))
label(dd, '眼部组件（WS2812 眼灯在内）', (300, 20), (420, 250), font=FS)
label(dd, '三线连接线（舵机 / 眼灯）', (420, 880), (150, 900), font=FS)
dd = dd.resize((720, int(720 * dd.height / dd.width)), Image.LANCZOS)

FT = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 26)
pad = 14
col_h = [a.height + 40 + c.height + 40, b.height + 40 + dd.height + 40]
P = Image.new('RGB', (720 * 2 + pad * 3, max(col_h) + pad * 2), 'white')
dP = ImageDraw.Draw(P)
for (img, cap, x, y) in ((a, '(a) 拆开后的零件', pad, pad), (c, '(c) 主控板、锂电池与减速电机', pad, pad + a.height + 40),
                         (b, '(b) 主控板（局部放大）', 2 * pad + 720, pad), (dd, '(d) 眼部组件', 2 * pad + 720, pad + b.height + 40)):
    P.paste(img, (x, y))
    dP.text((x, y + img.height + 4), cap, font=FT, fill=(40, 40, 40))
P.save(os.path.join(OUT, 'robot_teardown.png'))
print('wrote robot_teardown.png', P.size)
