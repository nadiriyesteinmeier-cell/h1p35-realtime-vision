#!/usr/bin/env python3
"""draw_block.py - system block diagram for the contest report (PIL only; no matplotlib on this PC)

    python tools/report/draw_block.py   ->  docs/report/img/system_block.png
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
OUT = os.path.join(ROOT, 'docs', 'report', 'img', 'system_block.png')
FONT = 'C:/Windows/Fonts/msyh.ttc'
FONTB = 'C:/Windows/Fonts/msyhbd.ttc'

W, H = 2400, 1500
img = Image.new('RGB', (W, H), 'white')
d = ImageDraw.Draw(img)
f_t = ImageFont.truetype(FONTB, 34)
f_b = ImageFont.truetype(FONTB, 26)
f_s = ImageFont.truetype(FONT, 21)
f_l = ImageFont.truetype(FONT, 22)

C_CAM = (232, 242, 252)
C_DDR = (240, 240, 240)
C_DSP = (236, 248, 236)
C_NEW = (255, 244, 225)
C_EXT = (248, 236, 248)
LINE = (60, 60, 60)


def box(x, y, w, h, title, lines=(), fill=C_CAM):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14, fill=fill, outline=LINE, width=3)
    tw = d.textlength(title, font=f_b)
    d.text((x + (w - tw) / 2, y + 12), title, font=f_b, fill=(20, 20, 20))
    for i, s in enumerate(lines):
        sw = d.textlength(s, font=f_s)
        d.text((x + (w - sw) / 2, y + 52 + 28 * i), s, font=f_s, fill=(50, 50, 50))
    return (x, y, w, h)


def arrow(x1, y1, x2, y2, label=None, width=4):
    d.line([x1, y1, x2, y2], fill=LINE, width=width)
    import math
    a = math.atan2(y2 - y1, x2 - x1)
    L = 18
    p1 = (x2 - L * math.cos(a - 0.4), y2 - L * math.sin(a - 0.4))
    p2 = (x2 - L * math.cos(a + 0.4), y2 - L * math.sin(a + 0.4))
    d.polygon([(x2, y2), p1, p2], fill=LINE)
    if label:
        d.text(((x1 + x2) / 2 + 6, (y1 + y2) / 2 - 30), label, font=f_s, fill=(90, 90, 90))


title = '系统总体框图（安路 PH1P35，全部功能在同一位流中，固化于 Flash 上电即运行）'
d.text(((W - d.textlength(title, font=f_t)) / 2, 22), title, font=f_t, fill=(0, 0, 0))

# ---------------- camera clock domain
d.text((40, 90), '摄像头时钟域（MIPI 字节时钟）', font=f_l, fill=(30, 80, 150))
y0 = 130
box(40, y0, 250, 150, 'SC500CS', ['MIPI CSI-2 两 lane', 'RAW10 1280×720@60'])
arrow(290, y0 + 75, 340, y0 + 75)
box(340, y0, 250, 150, 'MIPI D-PHY 接收', ['字节对齐 / 通道对齐', 'RAW10 解包'])
arrow(590, y0 + 75, 640, y0 + 75)
box(640, y0, 230, 150, '去马赛克', ['双线性插值', '4 像素 / 拍'])
arrow(870, y0 + 75, 920, y0 + 75)
box(920, y0, 470, 150, '自研 ISP：isp_color', ['黑电平扣除 · 21×13 节点镜头阴影校正', '闭环白平衡 / 数字曝光（只用近中性像素）', '等比例限幅 · 少于 1% 有效像素时保持'], fill=C_NEW)
arrow(1390, y0 + 75, 1440, y0 + 75)
box(1440, y0, 320, 150, '时间戳写入', ['ts_stamp：每帧首字写入', '微秒时间 + 摄像头帧号'], fill=C_NEW)
arrow(1760, y0 + 75, 1810, y0 + 75)
box(1810, y0, 540, 150, 'DDR 帧缓存', ['video_in → DDR 控制器 → video_out', '摄像头与显示两个时钟域解耦'], fill=C_DDR)

# ---------------- display domain
d.text((40, 330), '显示时钟域（HDMI 像素时钟约 75 MHz），每拍一像素、全流水线、不阻塞视频', font=f_l, fill=(30, 120, 60))
arrow(2080, y0 + 150, 2080, 390, '读出')
y1 = 390
box(1810, y1, 540, 120, '读出位置适配', ['video_pos_adapter：x / y / 帧首 / 行尾', '色彩微调（饱和度 / 提亮）'], fill=C_DSP)
# branches
arrow(1810, y1 + 60, 1700, y1 + 60)
d.line([1700, y1 + 60, 1700, 1180], fill=LINE, width=4)

bx = 1060
items = [
    (420, '传统视觉：contest_vision_v2', ['三色分割（自适应阈值）· 开运算去噪 · 边框屏蔽', '外接框 · 形状分类 · 跟踪 · 越线计数', '灰度 / Sobel 边缘 / 素描 / 卡通 / 伪彩色 8 种视图', '识别面板 OSD · 串口报告 · 数码管 · 蜂鸣器'], C_DSP, 190),
    (630, '片上 YOLO：yolo_top', ['10×10 平均取样 128×72 · int8 CNN（3.1 万参数）', '两检测头解码 + NMS · 每秒 30 次 · 27 ms 出框'], C_DSP, 120),
    (770, '帧差运动检测：motion_det', ['32×18 单元均值 · 与上一帧比较 · 运动图 / 计数 / 外接框'], C_NEW, 95),
    (885, '延迟测量：lat_meter', ['读回帧首时间戳 → 采集到显示延迟（µs / 帧）· 最大值'], C_NEW, 95),
    (1000, '直方图均衡：he_eq', ['亮度直方图 → CDF 映射表 · 应用到 RGB · 直方图与曲线显示'], C_NEW, 95),
    (1115, '白平衡页：wb_ctrl / wb_osd', ['AUTO / 手动 / 关闭 · 一键白平衡 · 测量窗读数'], C_DSP, 95),
]
for (yy, t, ls, col, hh) in items:
    box(bx, yy, 620, hh, t, ls, fill=col)
    arrow(1700, yy + hh / 2, 1680, yy + hh / 2)

# overlay chain
y2 = 1290
box(40, y2, 2310, 110, '叠加与输出链', ['识别 OSD → YOLO 框与状态行 → 白平衡页 → 直方图均衡页 → top_osd（每页安路 Logo · LAT / MAX 延迟 · 运动格与外接框）→ HDMI 1280×720@60'], fill=C_DSP)
arrow(1370, 1210, 1370, y2)

# pages / UI
box(40, 420, 560, 200, '7 个页面（KEY3+KEY4 切换）', ['CV · YOLO · CV+YOLO · CAPTURE', 'WB · MOTION · HIST EQ', '拨码 SW1–SW4、KEY1–KEY4 选择视图与模式', 'LED / 8 位数码管 / 蜂鸣器状态指示'], fill=C_EXT)

# external control
box(40, 700, 560, 230, '外部控制（扩展 3）', ['J1 第 1 脚串口（单向，FPGA 只发不收）', '→ ESP32 桥接（不需要电脑）', '→ Wi-Fi WebSocket → WALL-E 机器人', '按颜色挥手 / 点头 / 举臂 / 眼灯，可选移动规则'], fill=C_EXT)
arrow(1060, 520, 600, 800, '识别结果')

legend = [(C_NEW, '本作品新增的自研模块'), (C_DSP, '自研处理 / 显示模块'), (C_CAM, '采集链路'), (C_EXT, '人机交互与外部控制')]
lx = 40
for col, s in legend:
    d.rectangle([lx, 1440, lx + 40, 1470], fill=col, outline=LINE, width=2)
    d.text((lx + 52, 1440), s, font=f_s, fill=(40, 40, 40))
    lx += 360

os.makedirs(os.path.dirname(OUT), exist_ok=True)
img.save(OUT)
print('wrote', OUT)
