#!/usr/bin/env python3
"""draw_overview.py - the submission's overview photo (作品全貌图) with every part of the final system in view: a frame of the 2026-10-31 demo
recording (the only picture that also shows the ESP32 status terminal: OLED and three LEDs), monitor white-balanced like the video, numbered
markers and a legend underneath.

    F:/yolo_env/Scripts/python.exe tools/report/draw_overview.py <demo recording>     ->  docs/report/submit/作品全貌图.jpg, docs/report/img/system_overview.jpg
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import screen_wb                                                         # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
OUT = os.path.join(ROOT, 'docs', 'report', 'submit', '作品全貌图.jpg')
T = 72.75                                                                # sharpest frame with all parts in view (robot segment, green target held up)
CROP_H = 1000                                                            # cut off most of the PC keyboard in the foreground (not part of the system)

raw = subprocess.run([screen_wb.FF, '-loglevel', 'error', '-ss', str(T), '-i', sys.argv[1], '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                     stdout=subprocess.PIPE, check=True).stdout
frame = np.frombuffer(raw, np.uint8).reshape(1080, 1920, 3).copy()
box = screen_wb.find_box(frame[::4, ::4])
if box is not None:
    frame = screen_wb.correct(frame, box)
im = Image.fromarray(frame[:CROP_H])

# (number, legend text, marker position)
PARTS = [
    (1, '显示器（CV 页：安路 Logo + 目标跟踪框）', (840, 330)),
    (2, 'HX1P35A 开发板（PH1P35，配置 Flash 已固化位流）', (1020, 545)),
    (3, 'SC500CS MIPI 摄像头（支架上，排线接开发板）', (1385, 290)),
    (4, '数码管（越线计数 + 帧率）/ 蜂鸣器', (1290, 528)),
    (5, 'ESP32 桥接板（J1 两根线：串口信号 + 地）', (265, 955)),
    (6, 'OLED 状态屏（报告、事件、命令）', (935, 905)),
    (7, '三色灯（蓝 / 绿 / 红，对应颜色目标）', (770, 700)),
    (8, 'WALL-E 机器人（Wi-Fi 接收 ESP32 的命令）', (150, 600)),
    (9, '识别目标：绿色铁框（另有红色收纳盒、蓝色泡沫块）', (1660, 262)),
]
F = ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 30)
FL = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 27)
d = ImageDraw.Draw(im)
for n, _, (x, y) in PARTS:
    d.ellipse([x - 24, y - 24, x + 24, y + 24], fill=(220, 30, 30), outline=(255, 255, 255), width=4)
    d.text((x, y), str(n), font=F, fill=(255, 255, 255), anchor='mm')

rows = (len(PARTS) + 1) // 2
LH = 46
canvas = Image.new('RGB', (1920, CROP_H + rows * LH + 30), 'white')
canvas.paste(im, (0, 0))
d = ImageDraw.Draw(canvas)
for k, (n, text, _) in enumerate(PARTS):
    x = 30 + (k % 2) * 960
    y = CROP_H + 16 + (k // 2) * LH + LH // 2
    d.ellipse([x, y - 16, x + 32, y + 16], fill=(220, 30, 30))
    d.text((x + 16, y), str(n), font=ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 22), fill=(255, 255, 255), anchor='mm')
    d.text((x + 44, y), text, font=FL, fill=(30, 30, 30), anchor='lm')
canvas.save(OUT, quality=92)
canvas.save(os.path.join(ROOT, 'docs', 'report', 'img', 'system_overview.jpg'), quality=92)          # the same picture in the report (3.1)
print('wrote', OUT, canvas.size, 'screen box', None if box is None else (box * 4).astype(int).tolist())
