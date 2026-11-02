#!/usr/bin/env python3
"""draw_official.py - extra figures of the official-template report (PIL): design flow, ESP32 firmware flow, YOLO scheduler flow, real-data samples

    F:/yolo_env/Scripts/python.exe tools/report/draw_official.py  ->  docs/report/img/{design_flow,esp32_flow,yolo_flow,yolo_dataset}.png
"""
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
OUT = os.path.join(ROOT, 'docs', 'report', 'img')
FB = ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 26)
FS = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 21)
FT = ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 30)
LINE = (60, 60, 60)
C_FPGA, C_DATA, C_BOARD, C_EXT = (236, 244, 252), (255, 244, 225), (236, 248, 236), (248, 236, 248)


class Canvas:
    def __init__(self, w, h, title):
        self.im = Image.new('RGB', (w, h), 'white')
        self.d = ImageDraw.Draw(self.im)
        self.d.text(((w - self.d.textlength(title, font=FT)) / 2, 16), title, font=FT, fill=(0, 0, 0))

    def box(self, x, y, w, h, title, lines=(), fill=C_FPGA):
        d = self.d
        d.rounded_rectangle([x, y, x + w, y + h], radius=12, fill=fill, outline=LINE, width=3)
        d.text((x + (w - d.textlength(title, font=FB)) / 2, y + 10), title, font=FB, fill=(20, 20, 20))
        for i, s in enumerate(lines):
            d.text((x + (w - d.textlength(s, font=FS)) / 2, y + 48 + 27 * i), s, font=FS, fill=(50, 50, 50))

    def diamond(self, cx, cy, w, h, s, fill=(255, 250, 230)):
        d = self.d
        d.polygon([(cx, cy - h / 2), (cx + w / 2, cy), (cx, cy + h / 2), (cx - w / 2, cy)], fill=fill, outline=LINE)
        d.text((cx - d.textlength(s, font=FS) / 2, cy - 13), s, font=FS, fill=(20, 20, 20))

    def arrow(self, pts, label=None, lab_off=(8, -30), color=LINE):
        d = self.d
        d.line(pts, fill=color, width=4)
        (x1, y1), (x2, y2) = pts[-2], pts[-1]
        a = math.atan2(y2 - y1, x2 - x1)
        d.polygon([(x2, y2), (x2 - 18 * math.cos(a - 0.4), y2 - 18 * math.sin(a - 0.4)), (x2 - 18 * math.cos(a + 0.4), y2 - 18 * math.sin(a + 0.4))], fill=color)
        if label:
            mx, my = (pts[0][0] + pts[-1][0]) / 2, (pts[0][1] + pts[-1][1]) / 2
            d.text((mx + lab_off[0], my + lab_off[1]), label, font=FS, fill=(100, 60, 20))

    def text(self, x, y, s, font=None, fill=(40, 40, 40)):
        self.d.text((x, y), s, font=font or FS, fill=fill)

    def save(self, name):
        self.im.save(os.path.join(OUT, name))
        print('wrote', name)


os.makedirs(OUT, exist_ok=True)

# ------------------------------------------------------------------ design flow
c = Canvas(2300, 900, '设计流程（每个版本都记录仿真、构建、位流哈希与上板反馈）')
steps = [('需求分析', ['赛题与解析对照', '指标与验证方法'], C_DATA), ('测量诊断', ['平场 / 暗场统计', '串口与实拍数据'], C_DATA),
         ('RTL 设计', ['Verilog-2001', 'Python 参考模型'], C_FPGA), ('仿真验证', ['逐位 / 逐像素比较', '变异测试'], C_FPGA),
         ('TD 构建', ['时序 / 资源 / RAM 推断', '工程一致性校验'], C_FPGA), ('SRAM 上板', ['用户实物验收', '串口记录'], C_BOARD),
         ('Flash 固化', ['用户同意后写入', '冷启动 + 30 分钟'], C_BOARD)]
W, G, X0, Y0 = 280, 42, 40, 150
for i, (t, ls, f) in enumerate(steps):
    x = X0 + i * (W + G)
    c.box(x, Y0, W, 150, t, ls, f)
    if i:
        c.arrow([(x - G, Y0 + 75), (x, Y0 + 75)])
c.arrow([(X0 + 5 * (W + G) + W / 2, Y0 + 150), (X0 + 5 * (W + G) + W / 2, Y0 + 230), (X0 + 2 * (W + G) + W / 2, Y0 + 230), (X0 + 2 * (W + G) + W / 2, Y0 + 152)],
        '实物问题 → 回到测量 / 设计', (-380, 8), (160, 60, 60))
ystep = [('CAPTURE 页采集', ['板上网络真实输入', '128×72，经串口'], C_BOARD), ('自动标注 + 复核', ['剪影 + 颜色种子', '逐帧拼图检查'], C_DATA),
         ('训练 / 微调', ['PyTorch，含反例', '数据增强'], C_DATA), ('int8 量化 + 导出', ['与 RTL 逐位一致', 'ROM + 模型常数'], C_FPGA)]
c.text(X0, 520, 'YOLO 数据支线：', FB)
for i, (t, ls, f) in enumerate(ystep):
    x = X0 + 260 + i * (W + 60)
    c.box(x, 580, W, 150, t, ls, f)
    if i:
        c.arrow([(x - 60, 655), (x, 655)])
c.arrow([(X0 + 4 * (W + G) + W / 2, 580), (X0 + 4 * (W + G) + W / 2, Y0 + 152)], '新 ROM', (10, -10))
c.text(X0, 800, '图例：', FB)
for i, (f, s) in enumerate(((C_DATA, '数据 / 分析'), (C_FPGA, 'FPGA 设计与验证'), (C_BOARD, '实物操作'))):
    c.d.rectangle([X0 + 100 + i * 330, 800, X0 + 140 + i * 330, 830], fill=f, outline=LINE)
    c.text(X0 + 150 + i * 330, 802, s)
c.save('design_flow.png')

# ------------------------------------------------------------------ ESP32 firmware flow
c = Canvas(2300, 1250, 'ESP32 桥接固件流程（walle_esp32_bridge.ino）')
c.box(60, 110, 360, 110, '上电', ['读 NVS 设置', '初始化本地终端'], C_EXT)
c.diamond(240, 330, 360, 130, '已配置 Wi-Fi？')
c.arrow([(240, 220), (240, 265)])
c.box(520, 275, 440, 120, '设置模式', ['热点 WALLE-BRIDGE', '网页 192.168.4.1 保存到 NVS'], C_DATA)
c.arrow([(420, 330), (520, 330)], '否', (-20, -34))
c.box(60, 460, 360, 120, '连接 Wi-Fi', ['STA 模式'], C_EXT)
c.arrow([(240, 395), (240, 460)], '是', (10, -10))
c.box(60, 640, 360, 220, '查找瓦力', ['1 设置页填写的 IP', '2 上次连通的 IP', '3 mDNS wali.local', '4 扫描本网段 “WALI”'], C_EXT)
c.arrow([(240, 580), (240, 640)])
c.box(60, 930, 360, 120, 'WebSocket 连接', ['ws://IP/ws，1.5 s 心跳', '断线 1–15 s 退避重连'], C_EXT)
c.arrow([(240, 860), (240, 930)])
c.box(560, 470, 1680, 700, '主循环（每次循环都执行）', [], (250, 250, 250))
c.box(600, 540, 420, 150, 'UART2 读一行', ['GPIO16，115200 8N1', 'FPGA 单向发送'], C_FPGA)
c.diamond(1250, 615, 340, 130, '报告类型？')
c.arrow([(1020, 615), (1080, 615)])
c.box(1500, 520, 680, 90, '传统报告：R/G/B 形状、X、面积、越线数', [], C_FPGA)
c.box(1500, 630, 680, 90, 'YOLO 报告：每类取最高分框的中心与面积', [], C_FPGA)
c.arrow([(1420, 600), (1500, 565)])
c.arrow([(1420, 630), (1500, 675)])
c.box(600, 770, 760, 190, '规则 decide()', ['主导颜色（1.5 倍面积，连续 2 份）', '左 / 中 / 右（回差、防抖，出现后 2.5 s 不举手）', '越线、消失（连续 10 份无目标）'], C_DATA)
c.arrow([(1840, 720), (1840, 740), (980, 740), (980, 770)])
c.box(1440, 770, 760, 190, '命令队列', ['动作一次一条，等“完成”或 8 s', '只保留最新待发；眼灯 / 急停立即发', '手势规则 / 移动规则（BOOT 短按切换）'], C_EXT)
c.arrow([(1360, 865), (1440, 865)])
c.box(600, 1010, 1600, 120, '同时：心跳与重连、本地终端（OLED、三色灯、蜂鸣器、舵机）、BOOT 长按 3 s 回到设置模式、USB 每 5 s 状态行', [], (240, 240, 240))
c.arrow([(420, 990), (600, 615)])
c.save('esp32_flow.png')

# ------------------------------------------------------------------ YOLO scheduler flow
c = Canvas(2300, 760, '片上 YOLO 调度流程（yolo_top，HDMI 像素时钟 75 MHz，与视频并行）')
ys = [('ARM', ['等下一帧开始'], C_FPGA), ('CAP 取样', ['10×10 平均 → 128×72', '写输入 bank，16.7 ms'], C_FPGA),
      ('NET 推理', ['34 条描述符：卷积 / 池化', '上采样 / 填充，约 10.9 ms'], C_FPGA), ('DEC 解码', ['sigmoid / exp 查表', '阈值 0.70 + NMS，≤ 8 框'], C_FPGA),
      ('LATCH', ['锁存框、帧号', '取样→出框延迟'], C_FPGA)]
W, G = 360, 70
for i, (t, ls, f) in enumerate(ys):
    x = 40 + i * (W + G)
    c.box(x, 140, W, 160, t, ls, f)
    if i:
        c.arrow([(x - G, 220), (x, 220)])
c.arrow([(40 + 4 * (W + G) + W / 2, 300), (40 + 4 * (W + G) + W / 2, 380), (40 + W / 2, 380), (40 + W / 2, 302)], '每 2 帧一次（每秒 30 次）', (-300, 6))
c.box(40 + (W + G), 450, W, 150, 'CAPTURE 页', ['取样后经串口导出', '训练数据（2.4 s / 帧）'], C_DATA)
c.arrow([(40 + (W + G) + W / 2, 300), (40 + (W + G) + W / 2, 450)], '模式 3', (10, -20))
c.box(40 + 3 * (W + G), 450, 2 * W + G, 150, '输出', ['yolo_osd：类别着色框 + “字母 + 置信度%” 标签 + 状态行', 'UART：每 200 ms “Y n 帧号 延迟” + n 行框（ESP32 可解析）'], C_EXT)
c.arrow([(40 + 4 * (W + G) + W / 2, 380), (40 + 4 * (W + G) + W / 2, 450)])
c.text(40, 650, '权重 3,883 个 64 位字、参数 240 组全部在片上 ROM；4 个激活 bank 在片上 RAM；不访问 DDR，不阻塞视频。', FS)
c.save('yolo_flow.png')

# ------------------------------------------------------------------ real-data samples with labels
cap = 'F:/yolo_capture'
pick = [('s01b', 30), ('s01b', 80), ('s02', 20), ('s02', 95), ('s03', 25), ('s03', 70), ('s04', 40), ('s04', 75), ('s05', 12), ('s06', 50), ('s06', 64), ('s07neg', 18)]
col = {0: (255, 50, 50), 1: (40, 230, 40), 2: (70, 140, 255)}
names = {0: '红盒', 1: '绿框', 2: '蓝块'}
S, cols = 3, 4
tw, th = 128 * S, 72 * S
im = Image.new('RGB', (cols * (tw + 12) + 12, 3 * (th + 50) + 80), 'white')
d = ImageDraw.Draw(im)
d.text((12, 12), '实拍训练数据样例（CAPTURE 页采集的板上网络输入 128×72，框为复核后的标注；最后一张为反例：无目标）', font=FS, fill=(0, 0, 0))
for k, (s, i) in enumerate(pick):
    f = np.load(os.path.join(cap, s, 'frames.npy'))[i]
    lab = json.load(open(os.path.join(cap, s, 'labels.json')))[i]
    t = Image.fromarray(f[12:84]).resize((tw, th), Image.NEAREST)
    td = ImageDraw.Draw(t)
    for (cl, cx, cy, w, h) in lab:
        cl = int(cl)
        td.rectangle([(cx - w / 2) * S, (cy - 12 - h / 2) * S, (cx + w / 2) * S, (cy - 12 + h / 2) * S], outline=col[cl], width=3)
    x, y = 12 + (k % cols) * (tw + 12), 60 + (k // cols) * (th + 50)
    im.paste(t, (x, y))
    tag = '%s #%d：%s' % (s, i, '、'.join(names[int(b[0])] for b in lab) if lab else '无目标')
    d.text((x, y + th + 6), tag, font=FS, fill=(60, 60, 60))
im.save(os.path.join(OUT, 'yolo_dataset.png'))
print('wrote yolo_dataset.png')

# ------------------------------------------------------------------ WALL-E robot: composition and interface (facts from its boot log over USB and its own tools/list reply)
c = Canvas(2300, 1180, 'WALL-E 机器人组成与控制接口（依据：机器人 USB 串口开机日志、WebSocket tools/list 实测）')
c.box(40, 150, 470, 260, '本作品（自研）', ['FPGA：识别、检测、串口报告', 'ESP32 桥接固件：', '报告解析、规则、动作队列、', '查找机器人、重连'], C_FPGA)
c.arrow([(510, 280), (700, 280)], 'Wi-Fi 局域网', (-90, -40))
for k, s_ in enumerate(('协议：WebSocket ws://IP/ws', '消息：JSON（move、MCP tools/call）', '每 1.5 s 心跳 ping，断线自动重连', '只用机器人公开的局域网接口')):
    c.text(50, 450 + 34 * k, s_, FS, (100, 60, 20))
c.d.rounded_rectangle([700, 110, 2260, 1130], radius=16, outline=LINE, width=3, fill=(252, 250, 246))
c.text(720, 120, 'WALL-E 机器人（成品，固件未修改）', FB, (20, 20, 20))
c.box(1180, 200, 600, 300, '主控 ESP32-S3', ['8 MB 八线 PSRAM，QIO Flash', 'Wi-Fi（STA）、USB 串口 / JTAG', '固件：小智 AI v2.4.2（ESP-IDF 5.5.2）', 'SKU linxia-wali', '内置控制台网页 + WebSocket 服务', 'MCP 工具 self.wali.*'], C_EXT)
c.box(760, 600, 460, 220, 'DRV8833 双 H 桥', ['LEDC PWM 20 kHz / 10 位', '左：速度 GPIO17，方向 GPIO18', '右：速度 GPIO13，方向 GPIO14'], C_BOARD)
c.box(760, 900, 460, 160, '左 / 右履带电机', ['move：前进 / 后退 / 转向', '速度 20–100，可定时'], C_BOARD)
c.arrow([(990, 820), (990, 900)])
c.box(1290, 600, 440, 220, '舵机（双臂、头部）', ['左臂、右臂：抬起约 60°', '自然约 120°，放下约 170°', '头部只能俯仰：平视约 120°'], C_BOARD)
c.box(1290, 900, 440, 160, '动作（固件内置）', ['wave / arm_left / arm_right', 'nod / dance / stop'], C_BOARD)
c.arrow([(1510, 820), (1510, 900)])
c.box(1800, 600, 420, 220, 'WS2812 眼灯 ×2', ['RMT 驱动，GPIO8', 'color / pulse / flash', 'blink / off / mood'], C_BOARD)
c.box(1800, 900, 420, 160, '其他', ['ILI9341 屏幕、按键', '音频编解码（语音对话）'], C_BOARD)
for x in (990, 1510, 2010):
    c.arrow([(1480, 500), (1480, 550), (x, 550), (x, 600)])
c.arrow([(700, 280), (1180, 300)])
c.save('robot_block.png')
