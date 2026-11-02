#!/usr/bin/env python3
"""draw_wiring.py - wiring diagram of the ESP32 bridge / local status terminal (PIL)

    F:/yolo_env/Scripts/python.exe tools/report/draw_wiring.py  ->  docs/report/img/esp32_wiring.png

Pins follow esp32/walle_esp32_bridge/walle_esp32_bridge.ino; the expansion board rows are drawn outer -> inner as S V G, like the silkscreen.
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
OUT = os.path.join(ROOT, 'docs', 'report', 'img')
FB = ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 24)
FS = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 20)
FP = ImageFont.truetype('C:/Windows/Fonts/consola.ttf', 19)
FT = ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 32)
SIG, VCC, GND, V5 = (230, 120, 0), (220, 30, 30), (30, 30, 30), (150, 0, 120)

W, H = 2400, 1500
im = Image.new('RGB', (W, H), 'white')
d = ImageDraw.Draw(im)
title = 'ESP32 桥接与本地状态终端接线图（扩展板跳线帽插 3.3V）'
d.text(((W - d.textlength(title, font=FT)) / 2, 18), title, font=FT, fill=(0, 0, 0))

# ------------------------------------------------------------------ expansion board with the DevKit
BX0, BX1, TOP, DY = 900, 1500, 250, 52
LEFT = ['EN', 'VP', 'VN', 'D34', 'D35', 'D32', 'D33', 'D25', 'D26', 'D27', 'D14', 'D12', 'D13', 'GND', 'VIN']
RIGHT = ['D23', 'D22', 'TX0', 'RX0', 'D21', 'D19', 'D18', 'D5', 'TX2', 'RX2/D16', 'D4', 'D2', 'D15', 'GND', '3V3']
d.rounded_rectangle([BX0, TOP - 70, BX1, TOP + 15 * DY + 120], radius=16, fill=(30, 30, 34), outline=(0, 0, 0), width=3)
d.rounded_rectangle([BX0 + 190, TOP - 30, BX1 - 190, TOP + 15 * DY - 10], radius=8, fill=(55, 55, 62))
for i, s in enumerate(['ESP32', 'DevKit V1', '（插在 30P', '扩展板上）', '', '天线端', '朝上', '', 'USB 口', '朝下']):
    d.text(((BX0 + BX1 - d.textlength(s, font=FS)) / 2, TOP + 10 + 34 * i), s, font=FS, fill=(230, 230, 230))
SQ = {}


def pin_row(side, i, name):
    y = TOP + i * DY + 16
    xs = [930, 965, 1000] if side == 'L' else [1470, 1435, 1400]          # outer -> inner: S V G
    for k, x in zip('SVG', xs):
        d.rectangle([x - 12, y - 12, x + 12, y + 12], fill=(250, 220, 90) if k == 'S' else (200, 60, 60) if k == 'V' else (120, 120, 120))
        SQ[(name, k)] = (x, y)
    if side == 'L':
        d.text((1020, y - 12), name, font=FP, fill=(255, 255, 255))
    else:
        d.text((1380 - d.textlength(name, font=FP), y - 12), name, font=FP, fill=(255, 255, 255))


for i, s in enumerate(LEFT):
    pin_row('L', i, s)
for i, s in enumerate(RIGHT):
    pin_row('R', i, s)
d.text((928, TOP - 62), 'S V G', font=FP, fill=(255, 255, 255))
d.text((1398, TOP - 62), 'G V S', font=FP, fill=(255, 255, 255))
# power header (2 x 4 block right of D13, as on the user's board): top row 5V 5V V V, bottom row GND x 4
PY = TOP + 15 * DY + 62
d.text((BX0 + 30, PY - 12), '电源排针（2×4）：', font=FS, fill=(255, 255, 255))
PXS = [1160, 1215, 1270, 1325]
for i, x in enumerate(PXS):
    d.rectangle([x - 12, PY - 12, x + 12, PY + 12], fill=(200, 60, 60) if i < 2 else (230, 150, 60))
    d.rectangle([x - 12, PY + 26, x + 12, PY + 50], fill=(120, 120, 120))
d.text((1187 - d.textlength('5V', font=FP) / 2, PY - 42), '5V', font=FP, fill=(255, 255, 255))
d.text((1297 - d.textlength('V=3.3V', font=FP) / 2, PY - 42), 'V=3.3V', font=FP, fill=(255, 255, 255))
d.text((1345, PY + 26), 'GND', font=FP, fill=(255, 255, 255))
SQ[('PWR', '5V')] = (PXS[1], PY)


def wire(pts, col):
    d.line(pts, fill=col, width=5, joint='curve')
    x1, y1 = pts[-1]
    d.ellipse([x1 - 7, y1 - 7, x1 + 7, y1 + 7], fill=col)


def to_s(p0, p1, lane, col):
    """module pin -> board square: horizontal, vertical at x = lane, horizontal"""
    wire([p0, (lane, p0[1]), (lane, p1[1]), p1], col)


def module(x, y, w, title, pins, sub=None, fill=(236, 244, 252)):
    h = 54 + 36 * len(pins) + (30 if sub else 0)
    d.rounded_rectangle([x, y, x + w, y + h], radius=12, fill=fill, outline=(60, 60, 60), width=3)
    d.text((x + 14, y + 10), title, font=FB, fill=(20, 20, 20))
    if sub:
        d.text((x + 14, y + 42), sub, font=FS, fill=(90, 90, 90))
    out = {}
    for i, (p, col) in enumerate(pins):
        py = y + 62 + (30 if sub else 0) + 36 * i
        d.text((x + 14, py - 13), p, font=FS, fill=col)
        out[p] = (x, py)
    return out


# ------------------------------------------------------------------ right side: buzzer, OLED, servo, FPGA (signal wires drawn, power / ground written)
MX, MW, K = 1740, 420, (40, 40, 40)
bz = module(MX, 100, MW, '蜂鸣器模块（可选，未接）', [('I/O', SIG), ('VCC → D23 排 V（3.3V）', VCC), ('GND → D23 排 G', K)])
to_s(bz['I/O'], SQ[('D23', 'S')], 1640, SIG)
ol = module(MX, 300, MW, '0.96" OLED（I2C）', [('SCL', SIG), ('SDA', (0, 140, 200)), ('VCC → D21 排 V（3.3V）', VCC), ('GND → D21 排 G', K)],
            '四个脚的顺序以模块丝印为准')
to_s(ol['SCL'], SQ[('D22', 'S')], 1590, SIG)
to_s(ol['SDA'], SQ[('D21', 'S')], 1680, (0, 140, 200))
# 2026-10-31: the MG90S pointer servo (D18 + 5 V pin) was dropped: on a USB-powered board its start-up current reset the ESP32 (brownout)
fp = module(MX, 620, MW, 'FPGA 开发板 J1（只接两根）', [('第 1 脚 V2（串口 TX）', SIG), ('第 30 脚 GND → GND', K)], fill=(236, 248, 236))
to_s(fp['第 1 脚 V2（串口 TX）'], SQ[('RX2/D16', 'S')], 1610, SIG)
module(MX, 860, MW, '供电 / 烧录', [('ESP32 板上 Micro-USB → 电脑或充电器', K)], fill=(248, 236, 248))

# ------------------------------------------------------------------ left side: LEDs on the breadboard
d.rounded_rectangle([60, 520, 760, 950], radius=12, fill=(250, 248, 240), outline=(60, 60, 60), width=3)
d.text((80, 530), '面包板：三色指示灯', font=FB, fill=(20, 20, 20))
leds = [('D25', '220Ω', (230, 30, 30), '红'), ('D26', '100Ω', (20, 170, 60), '绿'), ('D27', '100Ω', (30, 80, 230), '蓝')]
for i, (pin, r, col, nm) in enumerate(leds):
    y = 610 + 90 * i
    sx, sy = SQ[(pin, 'S')]
    wire([(560, y), (840 - 20 * i, y), (840 - 20 * i, sy), (sx, sy)], col)
    d.rectangle([420, y - 12, 520, y + 12], fill=(220, 200, 150), outline=(60, 60, 60), width=2)
    d.text((432, y - 12), r, font=FP, fill=(0, 0, 0))
    d.line([(520, y), (560, y)], fill=(60, 60, 60), width=3)
    d.line([(330, y), (420, y)], fill=(60, 60, 60), width=3)
    d.polygon([(330, y - 18), (330, y + 18), (296, y)], fill=col, outline=(0, 0, 0))   # LED: anode (long leg) on the resistor side
    d.line([(292, y - 18), (292, y + 18)], fill=(0, 0, 0), width=4)
    d.line([(292, y), (200, y)], fill=GND, width=3)
    d.text((300, y + 18), nm + '灯：长脚接电阻', font=FS, fill=(60, 60, 60))
d.line([(200, 600), (200, 800)], fill=GND, width=5)
d.text((80, 860), '三个短脚 → 面包板负极排 → 扩展板任一 G 针', font=FS, fill=GND)
d.text((80, 895), '（负极排就是标 “−” 的长条孔）', font=FS, fill=(90, 90, 90))

# ------------------------------------------------------------------ notes
notes = ['1. 全部断电后接线；黄色跳线帽套住 “3.3V” 和 “V” 两根针（出厂即如此），所有 V 针都是 3.3V。',
         '2. FPGA 与 ESP32 必须共地（J1 第 30 脚 → GND）。FPGA 的 5V、3.3V 都不要接到 ESP32。',
         '3. 一次只用一路供电：ESP32 板上 Micro-USB（电脑或充电器）。舵机指针已取消：USB 供电下其启动电流使 ESP32 欠压复位。',
         '4. 本地终端（OLED、三色灯）可选：不接时桥接照常工作。三色灯必须串电阻（红 220Ω，绿 / 蓝 100Ω）。']
for i, s in enumerate(notes):
    d.text((60, 1330 + 36 * i), s, font=FS, fill=(40, 40, 40))
os.makedirs(OUT, exist_ok=True)
im.save(os.path.join(OUT, 'esp32_wiring.png'))
print('wrote esp32_wiring.png')
