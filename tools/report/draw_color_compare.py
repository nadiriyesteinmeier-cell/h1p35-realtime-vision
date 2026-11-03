#!/usr/bin/env python3
"""draw_color_compare.py - "why the screen looks blue in the demo video": the small demo monitor (raw frame of the 2026-10-31 recording, no
correction) next to the same board on a desktop monitor (user photo 2026-11-03, same phone, no grading)

    F:/yolo_env/Scripts/python.exe tools/report/draw_color_compare.py <demo recording> docs/report/photos_src/bigmonitor_20261103.jpg
        ->  docs/report/img/color_compare.jpg            (report figure: the two pictures with labels)
            F:/fpga_submit/video/cards/c3b_color.png      (video card: the same plus a title and the explanation)

Privacy: the printed mouse pad in the photo (bottom left) shows a school emblem and text, and the red label on the monitor bezel is a lab sticker;
both are blurred hard before anything is written.
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
FF = 'E:/Ultimate Vocal Remover/ffmpeg.exe'
T = 44.0                                                                 # demo recording: small monitor fully in view, CV page (ORIG view)
CARD = 'F:/fpga_submit/video/cards/c3b_color.png'
BLUR = [(0, 748, 415, 955), (560, 688, 725, 732)]                        # photo: mouse pad (with the mouse), bezel sticker


def font(size, bold=False):
    return ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc' if bold else 'C:/Windows/Fonts/msyh.ttc', size)


raw = subprocess.run([FF, '-loglevel', 'error', '-ss', str(T), '-i', sys.argv[1], '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                     stdout=subprocess.PIPE, check=True).stdout
small = Image.fromarray(np.frombuffer(raw, np.uint8).reshape(1080, 1920, 3))
photo = Image.open(sys.argv[2]).convert('RGB')
for box in BLUR:
    region = photo.crop(box)
    photo.paste(region.resize((max(1, region.width // 24), max(1, region.height // 24))).resize(region.size).filter(ImageFilter.GaussianBlur(12)), box)

LEFT = '① 演示所用小显示器（10 月 31 日夜间拍摄，原始画面，未校正）'
RIGHT = '② 同一块开发板接电脑显示器（11 月 3 日补拍，同一部手机，未调色）'


def pair(height, gap, label_size):
    a = small.resize((round(small.width * height / small.height), height), Image.LANCZOS)
    b = photo.resize((round(photo.width * height / photo.height), height), Image.LANCZOS)
    w = a.width + gap + b.width
    im = Image.new('RGB', (w, height + label_size * 2 + 10), 'white')
    im.paste(a, (0, 0))
    im.paste(b, (a.width + gap, 0))
    d = ImageDraw.Draw(im)
    for x0, x1, s in ((0, a.width, LEFT), (a.width + gap, w, RIGHT)):
        d.text(((x0 + x1) / 2, height + 8 + label_size), s, font=font(label_size), fill=(30, 30, 30), anchor='mm')
    return im


os.makedirs(os.path.join(ROOT, 'docs', 'report', 'img'), exist_ok=True)
pair(1080, 30, 34).save(os.path.join(ROOT, 'docs', 'report', 'img', 'color_compare.jpg'), quality=92)

# video card, 1920 x 1080, same style as the other cards
W, H = 1920, 1080
card = Image.new('RGB', (W, H), 'white')
d = ImageDraw.Draw(card)
for y in range(H):
    g = int(255 - 40 * max(0, (y - 600) / 480))
    d.line([(0, y), (W, y)], fill=(g, g, g))
d.rectangle([60, 46, 76, 116], fill=(150, 20, 30))
d.text((100, 44), '关于屏幕偏蓝的说明', font=font(54, True), fill=(20, 20, 20))
p = pair(600, 24, 22)
card.paste(p, ((W - p.width) // 2, 150))
lines = ['板上回传的帧缓存数据（CAPTURE 页）对白纸为 R/G/B = 112/113/113：FPGA 输出的颜色本身是中性的。',
         '同一路 HDMI 信号接到电脑显示器，用同一部手机拍摄，颜色正常。',
         '偏蓝来自演示用小显示器偏冷的白点和夜间弱光下的手机拍屏，与 FPGA 设计无关；演示中小显示器的屏幕区域已做后期白平衡校正。']
y = 150 + p.height + 26
for s in lines:
    d.ellipse([110, y + 12, 124, y + 26], fill=(150, 20, 30))
    d.text((140, y), s, font=font(30), fill=(30, 30, 30))
    y += 52
card.save(CARD)
print('wrote color_compare.jpg', 'and', CARD, 'pair', p.size, 'text bottom', y)
