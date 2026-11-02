#!/usr/bin/env python3
"""draw_diagrams.py - principle diagrams for the report (PIL): AWB / AE loop, latency measurement, external control architecture

    F:/yolo_env/Scripts/python.exe tools/report/draw_diagrams.py  ->  docs/report/img/{awb_loop,latency_probe,control_arch}.png
"""
import math
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
OUT = os.path.join(ROOT, 'docs', 'report', 'img')
FB = ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 26)
FS = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 21)
FT = ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc', 30)
LINE = (60, 60, 60)


class Canvas:
    def __init__(self, w, h, title):
        self.im = Image.new('RGB', (w, h), 'white')
        self.d = ImageDraw.Draw(self.im)
        self.d.text(((w - self.d.textlength(title, font=FT)) / 2, 16), title, font=FT, fill=(0, 0, 0))

    def box(self, x, y, w, h, title, lines=(), fill=(236, 244, 252)):
        d = self.d
        d.rounded_rectangle([x, y, x + w, y + h], radius=12, fill=fill, outline=LINE, width=3)
        d.text((x + (w - d.textlength(title, font=FB)) / 2, y + 10), title, font=FB, fill=(20, 20, 20))
        for i, s in enumerate(lines):
            d.text((x + (w - d.textlength(s, font=FS)) / 2, y + 48 + 27 * i), s, font=FS, fill=(50, 50, 50))

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

# ------------------------------------------------------------------ AWB / AE closed loop
c = Canvas(2200, 860, '闭环自动白平衡与数字曝光（isp_color，每帧更新一次）')
c.box(40, 120, 300, 130, '去马赛克输出', ['RGB，4 像素 / 拍'])
c.arrow([(340, 185), (400, 185)])
c.box(400, 110, 420, 150, '扣黑电平', ['R/G/B − 18 / 19 / 17', '（暗场实测）'])
c.arrow([(820, 185), (880, 185)])
c.box(880, 110, 520, 150, '乘法：增益 × 阴影系数', ['eff_c = g_c × LSC_c(x, y)', '每拍 1 次乘法 / 通道，饱和到 255'])
c.arrow([(1400, 185), (1460, 185)])
c.box(1460, 120, 300, 130, '输出到帧缓存', ['同时送统计单元'])
c.arrow([(1610, 250), (1610, 330)])
c.box(1330, 330, 820, 190, '统计（只取有效像素）', ['输入：G ≥ 黑电平 + 4，R/G/B < 250（排除噪声与过曝）',
                                                 '输出：|R − G|、|B − G| ≤ G / 2（只取近中性像素）',
                                                 '累加 ΣR、ΣG、ΣB 与像素数 n'], fill=(255, 244, 225))
c.arrow([(1330, 425), (1160, 425)])
c.box(360, 330, 800, 190, '帧尾计算（顺序除法器，几百个时钟）', ['估计 er_c = g_c × (110 × n) / Σc   （目标亮度 110，三路一致）',
                                                   '若 max(er) > 8.0：三路同乘 8.0 / max（保持比例）',
                                                   'est ≥ 0.25；新增益 = (g + est + 1) / 2（半步，防振荡）'], fill=(255, 244, 225))
c.arrow([(760, 330), (760, 290), (1150, 290), (1150, 262)], '下一帧的增益 g_c', (-180, -34))
c.box(360, 600, 800, 150, '保护', ['有效像素 < 1% 帧面积：保持上一帧增益（大片彩色 / 全黑 / 全白不乱跳）',
                                   '上电初值：中性增益 R 3.2 / G 2.0 / B 4.0'], fill=(248, 236, 248))
c.arrow([(760, 600), (760, 522)])
c.box(1330, 600, 820, 150, 'WB 页', ['AUTO：上述闭环；MAN：手动增益（一键接管当前自动值）', 'OFF：增益 1.0 且关闭 LSC，显示原始画面'], fill=(236, 248, 236))
c.arrow([(1330, 675), (1160, 675), (1160, 600)], None)
c.save('awb_loop.png')

# ------------------------------------------------------------------ latency probe
c = Canvas(2200, 760, '采集→显示延迟测量（lat_probe）：时间戳随画面经过帧缓存')
c.box(40, 120, 380, 150, '50 MHz 晶振', ['微秒计数器（20 位）', '→ 格雷码'], fill=(240, 240, 240))
c.arrow([(420, 160), (560, 160)], '格雷码 + 两级同步', (-60, -34))
c.arrow([(420, 240), (500, 240), (500, 560), (1560, 560), (1560, 470)], '格雷码 + 两级同步', (-560, -10))
c.box(560, 110, 520, 170, '摄像头域：ts_stamp', ['每帧第一个 128 位字：', '像素 0/1/4 ← {A, 时间 t0}', '像素 2/3 ← {5A, 摄像头帧号}'], fill=(255, 244, 225))
c.arrow([(1080, 195), (1180, 195)])
c.box(1180, 110, 380, 170, 'DDR 帧缓存', ['与画面一起写入、读出', '（双缓冲 / 三缓冲）'], fill=(240, 240, 240))
c.arrow([(1560, 195), (1640, 195)])
c.box(1640, 110, 520, 170, '显示域：lat_meter', ['读出第 0 行像素 0..3', '校验标记 → 取 t0、帧号', '延迟 = t_now − t0'], fill=(255, 244, 225))
c.arrow([(1900, 280), (1900, 340)])
c.box(1380, 340, 780, 130, '显示：top_osd 右上角', ['LAT xx.xMS nF（每 8 帧刷新）  /  MAX xx.xMS（64 帧窗口最大值）'], fill=(236, 248, 236))
c.text(40, 620, '说明：测的是 ISP 输出该帧第一个字 → HDMI 读出该帧第一个像素的时间，即帧缓存 + FIFO 的延迟，精度约 1 µs；不含传感器曝光与显示器内部处理。')
c.text(40, 660, '时间戳像素在显示前涂黑；数值跨时钟域只用格雷码（每次只变 1 位），SDC 中已有相应的异步时钟组 / false path。')
c.save('latency_probe.png')

# ------------------------------------------------------------------ external control architecture
c = Canvas(2200, 900, '外部控制系统：FPGA 识别结果 → 机器人动作')
c.box(40, 140, 520, 230, 'FPGA（PH1P35）', ['识别：颜色 / 形状 / 坐标 / 面积 / 越线', '每 0.2 s 一行串口报告 115200 8N1', 'R:形状,X,Y,A,N;G:…;B:…;CAM,DSP'], fill=(236, 248, 236))
c.arrow([(560, 220), (760, 220)], 'USB 串口（COM）', (-80, -36))
c.arrow([(560, 320), (760, 500)], 'J1 第 1 脚（V2，3.3 V）', (-150, 6))
c.box(760, 120, 620, 220, '方案 A：电脑桥接（开发调试用）', ['walle_bridge.py：解析报告 → 事件', '主导颜色 / 左中右（回差）/ 越线 / 消失', '动作排队：一次一条，等“完成”再发'], fill=(236, 244, 252))
c.box(760, 420, 620, 220, '方案 B：ESP32 桥接（演示方案，已实测）', ['UART RX 接 J1 第 1 脚，GND 接第 30 脚', '同样的事件规则，固件内实现', '不需要电脑，真正“上电即运行”'], fill=(255, 244, 225))
c.arrow([(1380, 230), (1560, 330)], None)
c.arrow([(1380, 530), (1560, 420)], None)
c.text(1400, 390, 'Wi-Fi', fill=(100, 60, 20)); c.text(1400, 420, 'WebSocket', fill=(100, 60, 20))
c.box(1560, 250, 600, 280, 'WALL-E 机器人（ESP32-S3）', ['ws://<IP>/ws，局域网控制', '动作：挥手 / 点头 / 举左右臂 / 表情', '眼灯颜色、表情', '移动：前进 / 后退 / 左右转（定时 0.5–0.7 s）'], fill=(248, 236, 248))
c.text(40, 700, '手势规则：红 → 眼灯红 + 挥手；绿 → 点头；蓝 → 眼灯蓝 + 闪烁 + 双臂举起；目标在左 / 右 → 举左 / 右臂；越线 → 闪灯；消失 → 平静。')
c.text(40, 740, '移动规则（红绿灯 + 方向盘）：绿 → 前进并按目标左右转向；蓝 → 后退；红 → 立即停止；消失 → 停止。每段移动定时结束，链路断开也会自停。')
c.text(40, 780, '事件判定：主导颜色需大于原颜色 1.5 倍面积且持续 2 行才切换；左 / 右分界 520 / 760 像素，回差 30；同类事件至少间隔 1.5 s。')
c.save('control_arch.png')
