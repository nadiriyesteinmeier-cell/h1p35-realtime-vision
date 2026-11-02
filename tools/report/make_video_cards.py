#!/usr/bin/env python3
"""make_video_cards.py - title / section cards and caption overlays for the demo video (layout after the official reference video:
title -> block-by-block introduction -> "视频展示" -> live demo with captions -> END). No names of people or the school anywhere.

    F:/yolo_env/Scripts/python.exe tools/report/make_video_cards.py   ->  F:/fpga_submit/video/cards/*.png
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
IMG = os.path.join(ROOT, 'docs', 'report', 'img')
OUT = 'F:/fpga_submit/video/cards'
W, H = 1920, 1080
RED = (150, 20, 30)
TITLE = '基于安路 PH1P35 的全流水线实时视觉处理与机器人联动系统'
SUB = '2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 安路选题二'


def font(size, bold=True):
    return ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc' if bold else 'C:/Windows/Fonts/msyh.ttc', size)


def base():
    im = Image.new('RGB', (W, H), 'white')
    d = ImageDraw.Draw(im)
    for y in range(H):                                       # light grey gradient towards the bottom, like the reference
        g = int(255 - 40 * max(0, (y - 600) / 480))
        d.line([(0, y), (W, y)], fill=(g, g, g))
    return im, d


def centered(d, y, s, f, fill=(20, 20, 20)):
    d.text(((W - d.textlength(s, font=f)) / 2, y), s, font=f, fill=fill)


def fit(img, box):
    x0, y0, x1, y1 = box
    im = img.copy()
    im.thumbnail((x1 - x0, y1 - y0), Image.LANCZOS)
    return im, (x0 + (x1 - x0 - im.width) // 2, y0 + (y1 - y0 - im.height) // 2)


os.makedirs(OUT, exist_ok=True)

# title
im, d = base()
d.rectangle([0, 470, 260, 486], fill=RED)
d.rectangle([W - 260, 470, W, 486], fill=RED)
centered(d, 380, TITLE, font(64))
centered(d, 520, SUB, font(34, False), (80, 80, 80))
im.save(f'{OUT}/c0_title.png')


def intro(name, heading, picture, lines, picbox=(80, 170, 1180, 1020)):
    im, d = base()
    d.rectangle([60, 60, 76, 130], fill=RED)
    d.text((100, 58), heading, font=font(54), fill=(20, 20, 20))
    p, at = fit(Image.open(os.path.join(IMG, picture)).convert('RGB'), picbox)
    im.paste(p, at)
    d.rectangle([at[0] - 2, at[1] - 2, at[0] + p.width + 1, at[1] + p.height + 1], outline=(160, 160, 160), width=2)
    y = 260
    for s in lines:
        d.text((1240, y), s, font=font(34, False), fill=(40, 40, 40))
        y += 64
    im.save(f'{OUT}/{name}.png')


intro('c1_block', '分块介绍 · 系统组成', 'system_block.png',
      ['MIPI 摄像头 1280×720@60', '自研 ISP：黑电平 / 阴影校正 / 白平衡', 'DDR2 帧缓存', '传统视觉 + 片上 int8 YOLO', '运动检测 · 延迟测量 · 直方图均衡',
       'OSD 叠加 → FPGA 内 HDMI 输出', '识别结果 → ESP32 → 机器人'])
intro('c2_photo', '分块介绍 · 实物', 'system_photo.png',
      ['HX1P35A 开发板（PH1P35）', 'SC500CS MIPI 摄像头', 'HDMI 显示器', 'ESP32 桥接 + OLED 状态屏', 'WALL-E 机器人（执行机构）', '',
       '全部功能在同一位流中', '已固化 Flash，上电即运行'], picbox=(80, 170, 1180, 1040))
intro('c3_robot', '分块介绍 · 外部控制', 'robot_teardown.png',
      ['FPGA 完成全部识别与检测', 'GPIO 串口单向发送识别结果', 'ESP32 解析结果、生成动作', 'Wi-Fi WebSocket 控制机器人', '',
       '机器人为外购执行机构', '拆解：ESP32-S3 主控、减速电机、', '舵机、眼灯、锂电池'])
im, d = base()
d.rectangle([700, 380, 716, 560], fill=RED)
d.rectangle([1240, 520, W, 536], fill=RED)
centered(d, 430, '视频展示', font(80))
im.save(f'{OUT}/c4_demo.png')
im, d = base()
centered(d, 400, 'END', ImageFont.truetype('C:/Windows/Fonts/timesbd.ttf', 120))
centered(d, 580, TITLE, font(40, False), (60, 60, 60))
im.save(f'{OUT}/c5_end.png')

# captions: (start s, end s, main line, small second line) in the time of the demo clip
CAPS = [
    (0.0, 4.5, '上电即运行：位流已固化在 Flash，开发板不连接电脑', ''),
    (4.5, 14.0, 'MIPI 摄像头 → HDMI 1280×720@60 实时显示', '左上角安路 Logo，左侧识别面板，右上角为采集→显示延迟（约 2 帧）'),
    (14.0, 18.0, '数码管：左侧为越线计数，右侧 F060 为片上测得的摄像头帧率', ''),
    (18.0, 28.0, '颜色识别：TINT 给目标着色，面板显示形状、坐标、面积与越线数', '自研颜色分割 + 光照自适应阈值，与参考例程算法不同'),
    (28.0, 46.0, '拨码切换视图：灰度 / 二值化掩膜 / 边缘 / 素描 / 卡通 / 伪彩色', '按键长按切换分析组与风格组，切换在帧边界生效、不撕裂'),
    (46.0, 64.0, '识别结果经 GPIO 串口单向发给 ESP32，ESP32 通过 Wi-Fi 控制机器人', '目标越过计数线时蜂鸣器提示、数码管计数 +1'),
    (64.0, 82.0, '红色 → 眼灯变红并挥手；绿色 → 眼灯变绿并点头；目标偏左 / 右 → 举对应手臂', '全程不使用电脑；OLED 与三色灯实时显示收到的结果和发出的命令'),
    (82.0, 96.0, '片上 int8 YOLO：检测框 + 类别与置信度，每秒约 30 次，取样到出框约 27 ms', '同样驱动机器人；模型用板上采集的实拍数据微调'),
    (96.0, 124.0, 'WB 页（自研 ISP）：黑电平扣除、镜头阴影校正、闭环自动白平衡与曝光', 'KEY4 切换 AUTO / MAN / OFF，屏幕显示实际增益与中央窗口平均值'),
    (124.0, 131.0, 'MOTION 页：32×18 网格硬件帧差，运动区域染红并框出', ''),
    (131.0, 140.0, 'HIST EQ 页：硬件直方图均衡，左下角实时显示直方图与映射曲线', ''),
    (140.0, 999.0, 'KEY3+KEY4 在 7 个页面间切换，全部功能集成在同一位流中', ''),
]
NOTE = '注：夜间弱光拍摄、显示器色温偏冷，手机拍屏偏蓝，屏幕区域已做后期白平衡校正；板上回传实测白纸 R/G/B = 112/113/113'

# task checklist: (group, [(item, caption segments in which it is being shown)]); green frame = shown now, white frame = shown earlier
TASKS = [
    # group and item names follow the official guide (1.2 基础要求, 1.3 扩展要求, 1.4 进阶要求 = 评分标准里的高阶挑战项)
    ('基础要求', [('1 视频采集与 HDMI 显示', {1}), ('2 FPGA 图像处理算法', {3, 4}), ('3 稳定输出（固化 Flash）', {0}), ('4 OSD 叠加 + 安路 Logo', {1})]),
    ('扩展要求', [('1 风格化 / 视觉增强', {4, 10}), ('2 目标检测与识别', {3, 7}), ('3 应用场景 + 外部控制', {5, 6, 7}), ('4 性能优化', {2}),
              ('5 自主创意', {7, 8})]),
    ('进阶要求（高阶挑战）', [('1 多算法切换 + 状态显示', {4, 11}), ('2 目标跟踪 + 坐标标注', {3}), ('3 处理延迟可视化', {1}), ('4 硬件运动目标检测', {9}),
                    ('5 图像质量自动调节', {8, 10})]),
    ('外设', [('数码管 / 蜂鸣器', {2, 5}), ('ESP32 桥接', {5, 6, 7}), ('OLED 状态屏', {6}), ('三色灯', {6}), ('WALL-E 机器人', {5, 6, 7})]),
]
GREEN = (40, 230, 90, 255)


def panel(d, x0, y0, w, seg, fs, row, alpha):
    """draws the checklist at (x0, y0), width w; returns its height"""
    n_rows = sum(len(items) for _, items in TASKS)
    hh = row + 6                                                        # group header row
    h = len(TASKS) * hh + n_rows * row + 16
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=10, fill=(0, 0, 0, alpha))
    y = y0 + 8
    for group, items in TASKS:
        d.text((x0 + 12, y + hh // 2), group, font=font(fs + 1), fill=(255, 214, 110, 255), anchor='lm')
        y += hh
        for label, segs in items:
            now, before = seg in segs, any(s < seg for s in segs)
            col = (255, 255, 255, 255) if now or before else (170, 170, 170, 255)
            d.text((x0 + 24, y + row // 2), label, font=font(fs, now), fill=col, anchor='lm')
            if now or before:
                d.rounded_rectangle([x0 + 14, y + 1, x0 + w - 10, y + row - 2], radius=5, outline=GREEN if now else (255, 255, 255, 230),
                                    width=3 if now else 2)
            y += row
    return h


LAYOUT = sys.argv[1] if len(sys.argv) > 1 else 'side'                   # side: video 80 %, checklist in a right column (final); overlay: on the video, top right
VW, VH = 1536, 864                                                      # video area in the side layout
for i, (a, b, s1, s2) in enumerate(CAPS):
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if LAYOUT == 'side':
        d.rectangle([VW, 0, W, H], fill=(28, 30, 34, 255))
        d.rectangle([0, VH, VW, H], fill=(28, 30, 34, 255))
        d.text((VW + 22, 18), '赛题任务完成情况', font=font(28), fill=(255, 255, 255, 255))
        panel(d, VW + 10, 64, W - VW - 20, i, 23, 37, 0)
        d.text(((VW - d.textlength(s1, font=font(36))) / 2, VH + 22), s1, font=font(36), fill=(255, 255, 255, 255))
        if s2:
            d.text(((VW - d.textlength(s2, font=font(27, False))) / 2, VH + 78), s2, font=font(27, False), fill=(225, 225, 225, 255))
        if i in (1, 2, 3):
            d.text(((VW - d.textlength(NOTE, font=font(20, False))) / 2, VH + 130), NOTE, font=font(20, False), fill=(190, 190, 190, 255))
    else:
        h = 120 if s2 else 78
        d.rectangle([0, H - h - 20, W, H - 20], fill=(0, 0, 0, 150))
        d.text(((W - d.textlength(s1, font=font(40))) / 2, H - h - 8), s1, font=font(40), fill=(255, 255, 255, 255))
        if s2:
            d.text(((W - d.textlength(s2, font=font(28, False))) / 2, H - h + 48), s2, font=font(28, False), fill=(230, 230, 230, 255))
        if i in (1, 2, 3):
            d.rectangle([0, 0, W, 46], fill=(0, 0, 0, 120))
            d.text(((W - d.textlength(NOTE, font=font(24, False))) / 2, 8), NOTE, font=font(24, False), fill=(255, 255, 255, 255))
        pw = 272
        panel(d, W - pw - 12, 56, pw, i, 18, 26, 140)
    im.save(f'{OUT}/cap_{i:02d}.png')
open(f'{OUT}/layout.txt', 'w').write(LAYOUT + '\n')
open(f'{OUT}/captions.txt', 'w', encoding='utf-8').write('\n'.join('%g %g' % (a, b) for a, b, _, _ in CAPS) + '\n')
print('cards and %d captions -> %s' % (len(CAPS), OUT))
