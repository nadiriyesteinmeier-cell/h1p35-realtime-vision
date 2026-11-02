#!/usr/bin/env python3
"""make_report.py - draft of the contest work report (Word), built from the project records

    python tools/report/draw_block.py        (system block diagram, PIL)
    python tools/report/make_report.py   ->  docs/report/作品报告_初稿.docx

Every number in here comes from docs/STATUS_FOR_CODEX.md, docs/ISP_COLOR_2026-10-26.md, docs/ADV_2026-10-26.md, docs/YOLO_BOARD_2026-10-24.md,
release/README.txt and logs_custom/soak/. Team names, the school and anything marked 【待填】 are for the team to fill in.
"""
import os
from docx import Document
from docx.enum.section import WD_ORIENT
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
IMG = os.path.join(ROOT, 'docs', 'report', 'img')
OUT = os.path.join(ROOT, 'docs', 'report', (__import__('sys').argv[1] if len(__import__('sys').argv) > 1 else '作品报告_初稿.docx'))

doc = Document()
sec = doc.sections[0]
sec.page_width, sec.page_height = Cm(21.0), Cm(29.7)
sec.left_margin = sec.right_margin = Cm(2.5)
sec.top_margin = sec.bottom_margin = Cm(2.5)


def set_font(style, latin, east, size=None, bold=None, color=None):
    style.font.name = latin
    rpr = style.element.get_or_add_rPr()
    rfonts = rpr.find(qn('w:rFonts'))
    if rfonts is None:
        rfonts = OxmlElement('w:rFonts')
        rpr.append(rfonts)
    rfonts.set(qn('w:eastAsia'), east)
    rfonts.set(qn('w:ascii'), latin)
    rfonts.set(qn('w:hAnsi'), latin)
    if size:
        style.font.size = Pt(size)
    if bold is not None:
        style.font.bold = bold
    if color is not None:
        style.font.color.rgb = color


set_font(doc.styles['Normal'], 'Times New Roman', '宋体', 11)
doc.styles['Normal'].paragraph_format.line_spacing = 1.3
doc.styles['Normal'].paragraph_format.space_after = Pt(4)
for lvl, size in ((1, 16), (2, 13.5), (3, 12)):
    set_font(doc.styles['Heading %d' % lvl], 'Times New Roman', '黑体', size, True, RGBColor(0, 0, 0))
    doc.styles['Heading %d' % lvl].paragraph_format.space_before = Pt(12 if lvl == 1 else 8)
    doc.styles['Heading %d' % lvl].paragraph_format.space_after = Pt(6)
set_font(doc.styles['Title'], 'Times New Roman', '黑体', 22, True, RGBColor(0, 0, 0))
set_font(doc.styles['Caption'], 'Times New Roman', '宋体', 10, False, RGBColor(60, 60, 60))


def para(text, bold=False, align=None, size=None, indent=True):
    p = doc.add_paragraph()
    if indent:
        p.paragraph_format.first_line_indent = Cm(0.74)
    r = p.add_run(text)
    r.bold = bold
    if size:
        r.font.size = Pt(size)
    if align is not None:
        p.alignment = align
    return p


def bullets(items):
    for s in items:
        p = doc.add_paragraph(style='List Bullet')
        p.add_run(s)


def shade(cell, hexcolor):
    tcpr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), hexcolor)
    tcpr.append(shd)


def table(header, rows, widths=None, caption=None):
    if caption:
        c = doc.add_paragraph(caption, style='Caption')
        c.alignment = WD_ALIGN_PARAGRAPH.CENTER
    t = doc.add_table(rows=1, cols=len(header))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    for i, h in enumerate(header):
        cell = t.rows[0].cells[i]
        cell.text = ''
        r = cell.paragraphs[0].add_run(h)
        r.bold = True
        r.font.size = Pt(10)
        shade(cell, 'D9E2F3')
    for row in rows:
        cells = t.add_row().cells
        for i, v in enumerate(row):
            cells[i].text = ''
            r = cells[i].paragraphs[0].add_run(str(v))
            r.font.size = Pt(10)
    if widths:
        t.autofit = False
        grid = t._tbl.tblGrid
        for i, gc in enumerate(grid.findall(qn('w:gridCol'))):
            gc.set(qn('w:w'), str(int(widths[i] * 567)))
        for i, w in enumerate(widths):
            t.columns[i].width = Cm(w)
        for row in t.rows:
            for i, w in enumerate(widths):
                row.cells[i].width = Cm(w)
    doc.add_paragraph()
    return t


def figure(name, caption, width=15.0):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.add_run().add_picture(os.path.join(IMG, name), width=Cm(width))
    c = doc.add_paragraph(caption, style='Caption')
    c.alignment = WD_ALIGN_PARAGRAPH.CENTER


def figure_pair(n1, c1, n2, c2, width=7.6, caption=None):
    t = doc.add_table(rows=2, cols=2)
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    for i, (n, c) in enumerate(((n1, c1), (n2, c2))):
        cell = t.rows[0].cells[i]
        cell.paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.CENTER
        cell.paragraphs[0].add_run().add_picture(os.path.join(IMG, n), width=Cm(width))
        cc = t.rows[1].cells[i]
        cc.text = ''
        r = cc.paragraphs[0].add_run(c)
        r.font.size = Pt(9.5)
        cc.paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.CENTER
    if caption:
        p = doc.add_paragraph(caption, style='Caption')
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER


def field(paragraph, instr):
    r = paragraph.add_run()
    b = OxmlElement('w:fldChar'); b.set(qn('w:fldCharType'), 'begin'); r._r.append(b)
    r2 = paragraph.add_run()
    t = OxmlElement('w:instrText'); t.set(qn('xml:space'), 'preserve'); t.text = instr; r2._r.append(t)
    r3 = paragraph.add_run()
    s = OxmlElement('w:fldChar'); s.set(qn('w:fldCharType'), 'separate'); r3._r.append(s)
    r4 = paragraph.add_run('（在 Word 中右键 → 更新域，生成目录 / 页码）')
    r5 = paragraph.add_run()
    e = OxmlElement('w:fldChar'); e.set(qn('w:fldCharType'), 'end'); r5._r.append(e)


def page_break():
    doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)


# ------------------------------------------------------------------ cover
for _ in range(4):
    doc.add_paragraph()
p = doc.add_paragraph('2026 年全国大学生嵌入式芯片与系统设计竞赛', style='Title')
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
p = doc.add_paragraph('FPGA 创新设计赛道 · 安路选题二', style='Title')
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
doc.add_paragraph()
p = para('作 品 设 计 报 告', bold=True, align=WD_ALIGN_PARAGRAPH.CENTER, size=26, indent=False)
doc.add_paragraph()
p = para('基于安路 PH1P35 的全流水线实时视觉处理与机器人联动系统', bold=True, align=WD_ALIGN_PARAGRAPH.CENTER, size=16, indent=False)
for _ in range(5):
    doc.add_paragraph()
cover = [('参赛队伍', '【待填】'), ('队伍成员', '【待填】'), ('指导教师', '【待填】'), ('学　　校', '【待填】'),
         ('开发平台', 'HX1P35A 开发板（PH1P35MDG324）+ SC500CS MIPI 摄像头 + 1280×720 HDMI 显示器'), ('完成日期', '2026 年 10 月')]
t = doc.add_table(rows=0, cols=2)
t.alignment = WD_TABLE_ALIGNMENT.CENTER
for k, v in cover:
    cells = t.add_row().cells
    cells[0].text = k
    cells[1].text = v
    cells[0].width = Cm(3.5)
    cells[1].width = Cm(11)
page_break()

# ------------------------------------------------------------------ abstract
doc.add_heading('摘　要', 1)
para('本作品以安路 HX1P35A 开发板（PH1P35MDG324 FPGA）为核心，实现了一套无需 PC 参与、上电即运行的实时视觉处理系统。'
     'SC500CS 摄像头的 1280×720@60 视频经 MIPI CSI-2 接收、自研 ISP 处理和 DDR 帧缓存，从 HDMI 实时输出。'
     '全部图像处理在 FPGA 内以“每拍一像素”的全流水线硬件实现，所有功能放在同一个位流中，已固化到配置 Flash，并通过断电冷启动验证。')
para('在 ISP 方面，系统完成了黑电平扣除、21×13 节点镜头阴影校正、只统计近中性像素的闭环自动白平衡与数字曝光，以及亮度直方图均衡。'
     '平场测试中，画面边角与中心的颜色比从 1.19 降到 1.02，亮度比从 0.74 提高到 0.96。'
     '在识别方面，系统实现了三色目标分割、去噪、外接框与形状分类、目标跟踪和越线计数，'
     '并在片上部署了 YOLOv3-tiny 派生的 int8 检测网络（每秒 30 次检测，取样到出框 27 ms）。'
     '进阶功能包括 7 个页面的模式切换与状态显示、32×18 单元的硬件帧差运动检测，'
     '以及利用写入帧缓存的时间戳在画面上实时显示“采集→显示”延迟（实测约 35–48 ms，即 2 帧）。'
     '识别结果通过串口驱动 WALL-E 机器人，完成“按颜色做动作、绿行红停蓝退、左右转向”的外部控制。')
para('设计全程采用“参考模型 + 逐位比较 + 变异测试 + 上板验收”的流程。最终版本时序收敛（建立裕量 +0.264 ns），Slice 占用 99.63%。'
     '30 分钟连续运行中串口报文无中断，摄像头与显示帧率分别保持在 59–60 和 60–61 帧/秒。')
para('关键词：FPGA；PH1P35；实时图像处理；ISP；目标检测与跟踪；帧差运动检测；直方图均衡；外部控制', bold=True, indent=False)
page_break()

doc.add_heading('目　录', 1)
field(doc.add_paragraph(), 'TOC \\o "1-3" \\h \\z \\u')
page_break()

# ------------------------------------------------------------------ 1
doc.add_heading('第1章 作品概述', 1)
doc.add_heading('1.1 设计目标', 2)
para('选题二要求在 PH1P35 上完成实时数字图像处理，包括：摄像头采集与 HDMI 显示、FPGA 端图像算法、稳定输出和带安路 Logo 的 OSD（基础项），'
     '以及风格化、目标识别与文字说明、外部控制、性能优化、自主创意（扩展项）和五个进阶项。'
     '赛题解析还规定：最终设计必须固化在开发板上、上电即运行，所有功能必须在同一个镜像中。'
     '本作品的目标是在同一个位流中完成全部基础、扩展和进阶项，并给出可复现的量化证据。')
doc.add_heading('1.2 功能与要求对照', 2)
table(['赛题要求', '本作品的实现', '实物验证'], [
    ['基础1 MIPI 采集 + HDMI 实时显示', 'SC500CS 两 lane MIPI → 自研 ISP → DDR 帧缓存 → HDMI 1280×720@60', '是'],
    ['基础2 FPGA 图像算法（不同于例程）', '三色分割与自适应阈值、灰度、Sobel 边缘、ISP、直方图均衡等', '是'],
    ['基础3 稳定输出', '全流水线不阻塞视频；30 分钟连续运行无中断', '是'],
    ['基础4 OSD + 安路 Logo', '每个页面都叠加安路 Logo；中英文状态、识别面板、目标框、计数线', '是'],
    ['扩展1 风格化', '素描、卡通（8 级色阶 + 黑边）、边缘叠加、伪彩色等 8 种视图', '是'],
    ['扩展2 检测识别 + 文字', '三色目标定位、形状分类、坐标与计数面板；片上 YOLO 框与置信度标签', '是'],
    ['扩展3 应用 + 外部控制', '串口报告 → 桥接 → WALL-E 机器人动作与移动；数码管、蜂鸣器', '是'],
    ['扩展4 性能优化', '单时钟域流水线；资源与时序优化；片上测量帧率与延迟', '是'],
    ['扩展5 自主创意', '片上 ISP 与镜头阴影标定、片上 int8 YOLO、机器人联动', '是'],
    ['进阶1 多算法切换 + 状态显示', 'KEY3+KEY4 切换 7 个页面，拨码切换视图，OSD 显示当前模式', '是'],
    ['进阶2 目标跟踪 + 坐标标注', '跟踪器（保持、丢失、重捕获）、外接框、中心坐标、越线计数', '是'],
    ['进阶3 采集→显示延迟可视化', '帧首写入微秒时间戳与帧号，读出时计算延迟，右上角实时显示', '是'],
    ['进阶4 硬件帧差运动检测', '32×18 单元帧差，显示运动格、外接框与运动单元数', '是'],
    ['进阶5 AE / AWB / 直方图均衡', '闭环白平衡与数字曝光（近中性像素统计）+ 直方图均衡页', '是'],
    ['规则：固化 Flash、单一镜像', 'adv03 位流写入配置 Flash，断电冷启动通过', '是'],
], widths=[4.2, 9.0, 2.0], caption='表1-1 赛题要求与实现对照')
doc.add_heading('1.3 主要指标', 2)
table(['指标', '数值', '来源'], [
    ['视频格式', '1280×720@60，RGB888', '设计'],
    ['摄像头 / 显示帧率', '均值 59.52 / 60.61 帧/秒（30 分钟）', '片上帧率计 + 串口记录'],
    ['采集→显示延迟', '约 35–48 ms（2 帧），64 帧窗口最大 50.7 ms', '片上时间戳测量（屏幕显示）'],
    ['YOLO 检测', '每秒 30 次，取样到出框 27 ms，int8，3.1 万参数', '片上计数器'],
    ['连续运行', '30 分钟，8569 行报文，0 秒中断，0 行格式错误', 'logs_custom/soak'],
    ['平场颜色均匀性', '边角/中心 R/G 1.19→1.02，B/G 1.18→1.03，亮度 0.74→0.96', '白纸平场实测'],
    ['资源（最终版 adv03）', 'Slice 99.63%，LUT 96.26%，FF 48.08%，ERAM 107/108，DSP 37/40', 'TD 6.2.1 报告'],
    ['时序', '建立裕量 +0.264 ns，保持裕量 +0.020 ns，0 违例', 'TD 6.2.1 报告'],
], widths=[3.8, 8.0, 3.4], caption='表1-2 主要实测指标')
page_break()

# ------------------------------------------------------------------ 2
doc.add_heading('第2章 系统总体设计', 1)
doc.add_heading('2.1 硬件平台', 2)
bullets(['FPGA：安路 PH1P35MDG324-3（HX1P35A 开发板），板载 DDR、配置 SPI Flash、USB-JTAG/UART、4 个拨码、4 个按键、8 位数码管、蜂鸣器。',
         '摄像头：SC500CS（MIPI CSI-2 两 lane，RAW10，配置为 1280×720@60）。',
         '显示：HDMI 1280×720 显示器。',
         '外部设备：WALL-E 机器人（ESP32-S3，局域网 WebSocket 控制）。',
         '开发工具：TD 6.2.1（综合、布局布线、位流），BitWriter（下载 / 写 Flash），Icarus Verilog 与 ModelSim（仿真），Python（参考模型、训练、桥接）。'])
figure('board_setup.jpg', '图2-1 实物平台（HX1P35A 开发板、SC500CS 摄像头、WALL-E 机器人）', 11.5)
doc.add_heading('2.2 系统框图', 2)
figure('system_block.png', '图2-2 系统总体框图', 16.0)
doc.add_heading('2.3 时钟域与数据流', 2)
para('系统分为两个主要时钟域。摄像头时钟域（MIPI 字节时钟）负责接收、解包、去马赛克和自研 ISP，4 像素一拍写入 DDR 帧缓存；'
     '显示时钟域（HDMI 像素时钟约 75 MHz）负责读出帧缓存并完成全部分析、识别和叠加。'
     '两个域之间只通过帧缓存和少量格雷码 / 握手同步的状态量交换数据，包括白平衡增益读回、时间戳和帧号；SDC 中已声明相应的异步时钟组。'
     '显示域的所有算法都只“旁听”读出流，每拍处理一个像素，延迟固定，不会让 HDMI 停顿。')
doc.add_heading('2.4 操作界面', 2)
table(['操作', '功能'], [
    ['KEY3 + KEY4 同时按', '页面循环：CV → YOLO → CV+YOLO → CAPTURE → WB（白平衡）→ MOTION（运动检测）→ HIST EQ（直方图均衡）'],
    ['SW1', '处理后画面 / 原图'],
    ['SW2、SW3', '显示视图：原图、灰度、掩膜、涂色；风格页的素描、卡通、边缘、伪彩色'],
    ['SW4', '显示计数线、目标框与十字'],
    ['KEY1 / KEY2（CV 页）', '识别面板开关 / 自适应阈值开关；长按 KEY2 切换风格页；KEY1+KEY2 清零计数'],
    ['KEY1–KEY4（WB 页）', '增益减 / 增、选择 R/G/B、AUTO → 手动（一键白平衡）→ 关闭'],
    ['屏幕右上角', 'LAT（采集→显示延迟，ms，帧数）与 MAX（最近窗口最大值），所有页面都显示'],
    ['串口（USB 与 J1 第 1 脚）', '每 0.2 s 一行识别报告：颜色、形状、坐标、面积、越线数、摄像头 / 显示帧率'],
], widths=[4.0, 11.2], caption='表2-1 操作方式')
page_break()

# ------------------------------------------------------------------ 3
doc.add_heading('第3章 关键模块设计', 1)
doc.add_heading('3.1 自研 ISP（isp_color）', 2)
para('ISP 位于去马赛克之后、帧缓存之前，每拍处理 4 个像素，固定延迟 27 个时钟。每个通道的处理顺序是：扣黑电平 → 乘以“白平衡增益 × 镜头阴影系数” → 饱和截断。')
bullets(['黑电平：暗场实测 R/G/B ≈ 17.8 / 18.6 / 17.4，按 18 / 19 / 17 扣除。',
         '镜头阴影校正：对白纸平场的 16×9 格统计，用 4 次二维多项式拟合每个通道，再在 21×13 个节点（64 像素间距）上求出“中心值 / 节点值”增益，存成 Q2.10 格式 ROM。'
         '节点之间，竖直方向用移位相加插值，水平方向用逐拍累加器插值；每拍只做一次“增益 × 阴影系数”乘法，共 3 个 DSP。拟合残差 RMS 小于 1%。',
         '闭环白平衡与数字曝光：在输出端统计 R、G、B 三个和与有效像素数 n。下一帧的增益估计为 er_c = g_c · (110·n) / Σc，即把近中性像素的平均亮度拉到 110，并使三通道一致。'
         '若最大估计超过 8.0，三路按同一比例缩小，保持红绿蓝比例不变；每次只走一半（IIR），防止振荡。',
         '有效像素：输入 G 高于黑电平 4 以上、三通道都低于 250（不取噪声和过曝像素），并且输出满足 |R−G|、|B−G| ≤ G/2（只取近中性像素）。'
         '有效像素少于 1% 时保持原增益。这样，大片彩色物体或灯光光晕不会把白平衡带偏。',
         '模式：AUTO / 手动（Q4.12 增益）/ 关闭（原始画面），由 WB 页切换；实际施加的增益读回到显示域并显示在屏幕上。'])
doc.add_heading('3.2 传统视觉识别链路（contest_vision_v2）', 2)
bullets(['三色分割：按通道比例判断红 / 绿 / 蓝目标，并设置随上一帧平均亮度变化的噪声下限（自适应阈值），可与固定阈值现场切换对比。',
         '去噪：一维开运算（连续命中长度 ≥ 5），并屏蔽画面四周 4 像素宽的边框，排除帧缓存首行的边缘伪像。',
         '统计：每种颜色逐帧求命中数、外接框与中心坐标；形状分类根据填充率和宽高比判断矩形、圆、三角、椭圆。',
         '跟踪：target_track 对外接框做抖动抑制（2 像素以内不重画）、跳变判定（24 像素以上直接跳），目标短暂丢失时保持 15 帧（虚线框），并统计捕获、保持、丢失、重捕获次数。',
         '越线计数：带死区回差，并需要连续若干帧确认；每次越线时蜂鸣器提示，数码管显示累计数。',
         '显示与报告：8 种视图、识别面板（颜色、形状、坐标、计数、帧率）、计数线；同时通过串口每 0.2 s 输出一行。'])
doc.add_heading('3.3 片上 YOLO 检测（yolo_top）', 2)
para('检测器全部运行在显示时钟域，只旁听帧缓存读出流，不访问 DDR，也不阻塞视频。')
bullets(['取样：1280×720 按 10×10 平均得到 128×72，上下补灰边成 128×96 的 int8 输入。',
         '网络：由 YOLOv3-tiny 裁剪而来，共 15 个卷积层、两个检测头（stride 32 / 16，各 3 个 anchor，3 个类别），31,496 个参数；权重为逐通道对称 int8，存放在片上 ROM。',
         '引擎：描述符驱动的 8 lane 卷积核，激活值存放在 4 个片上 RAM bank；sigmoid / exp 用查表实现；NMS 后最多输出 8 个框。',
         '节奏：推理约 10.9 ms，每 2 帧出一次结果，即每秒 30 次检测；取样到出框约 27 ms。框和“类别 + 置信度%”标签叠加在画面上。',
         '训练：PyTorch 合成数据集（训练 / 验证 / 测试各 24000 / 2000 / 2000 张）。int8 测试集 mAP50 为 0.585，量化损失 0.002。用真实零件数据微调的工作【进行中，完成后补充真实测试集指标】。',
         'CAPTURE 页：把网络输入图经串口发到 PC，用于采集真实训练数据。'])
doc.add_heading('3.4 帧差运动检测（motion_det，进阶4）', 2)
para('画面划分为 32×18 个 40×40 的单元。每个单元取 10×10 个采样点（x、y 都为 4n+2），计算亮度 Y=(R+2G+B)/4 的和，取高 8 位作为单元均值，'
     '与上一帧同一单元的值（存于 1 块 ERAM）比较，差值 ≥ 6 即判为运动。累加使用 32 项的移位环（SRL），每个单元行结束时由一个 64 拍的状态机完成比较和写回，'
     '运动位图写入一块 32×32 的 RAM，供叠加层逐行读取。每帧输出运动单元数和外接框；MOTION 页把运动单元染红，并画出黄色外接框。整个模块只用了约 100 个 LUT 和 2 块 ERAM。')
figure('motion_page.jpg', '图3-1 MOTION 页：手部运动单元被染红并框出（右上角为延迟读数）', 11.0)
doc.add_heading('3.5 采集→显示延迟测量（lat_probe，进阶3）', 2)
para('50 MHz 晶振驱动一个微秒计数器，以格雷码分别送到摄像头域和显示域（两级同步后转回二进制）。'
     'ISP 输出每帧第一个 128 位字时，ts_stamp 把当时的时间和摄像头帧号写进该字的 5 个像素位置，它们随画面一起经过 DDR 帧缓存。'
     '显示端读到第 0 行前 4 个像素时取回时间戳，与当前时间相减，就得到这一帧在“ISP 输出 → HDMI 读出”之间花的时间。显示值每 8 帧刷新一次，同时给出 64 帧窗口内的最大值，'
     '以“LAT xx.xMS nF / MAX xx.xMS”显示在每个页面右上角。时间戳像素在显示前被涂黑。')
doc.add_heading('3.6 直方图均衡（he_eq，进阶5）', 2)
para('在读出流上，对 x、y 都为偶数的像素（每帧 230400 个）统计 256 级亮度直方图。每帧结束后，在场消隐期间按级累加出 CDF，并计算映射表 lut(v)=min(255,(CDF·74274+2²⁵)>>26)；'
     '这一步每级一个时钟，3 级流水线，同时清零直方图。HIST EQ 页对每个通道施加 c′=clamp(c+lut(Y)−Y)，使亮度均衡而色差不变。左下角显示上一帧直方图（灰色柱）和映射曲线（黄线）。'
     '三张表都放在 LUT 分布式 RAM 中，不占用 ERAM。')
doc.add_heading('3.7 白平衡页：自动 / 手动 / 一键白平衡（wb_ctrl、wb_osd）', 2)
para('白平衡页是 KEY3+KEY4 页面循环中的第 5 页，用于现场查看和调整 ISP 的白平衡与曝光增益。'
     '这一页显示 ISP 的原始输出：色彩微调关闭，也不叠加识别框，所以测量窗读数就是后续算法看到的颜色。'
     '在这一页设定的模式和增益，离开后继续生效。')
table(['按键 / 显示', '功能'], [
    ['KEY4 单按', '模式循环 AUTO → MAN → OFF → AUTO。AUTO：闭环自动白平衡与曝光（3.1 节）；MAN：手动增益；OFF：关闭校正，显示传感器原始画面'],
    ['一键白平衡', '在 AUTO 下对准白纸或灰卡按 KEY4，进入 MAN 时接管 ISP 当前的自动增益并固定下来'],
    ['KEY1 / KEY2', '选中通道的增益 −0.01 / +0.01（Q4.12 精确换算）；按住 0.5 s 后连续调（每秒 16 次），按住 2 s 后每步 0.05；范围 0.25–8.00。在 AUTO 或 OFF 下按，会先从当前实际增益切到 MAN，画面不跳变'],
    ['KEY3 单按', '选择要调的通道：R → G → B'],
    ['KEY4 按住 1 s', '进入 MAN，R/G/B 全部回到 1.00'],
    ['屏幕', '中央 128×128 黄框测量窗；底部显示模式、选中通道、ISP 实际施加的三路增益（从摄像头域读回），以及测量窗的 R/G/B 平均值。对白纸调到三数相等，即为中性'],
], widths=[3.2, 12.0], caption='表3-1 白平衡页操作')
para('白平衡页本身经过 776 个手动增益值的全扫描测试（每个值都与 round(h·4096/100) 一致），以及按键连发、加速、和弦、一键接管、钳位等定向测试；变异测试 35/35。'
     '第 5.4 节的白平衡对比照片都是在这一页拍摄的。')
doc.add_heading('3.8 OSD 与多页面', 2)
para('叠加链依次是：识别 OSD（Logo 之外的中英文文字、面板、框、十字、计数线）→ YOLO 框与状态行 → 白平衡页 → 直方图均衡页 → top_osd。'
     'top_osd 在每个页面画出安路 Logo（带半透明白色底板）、延迟读数，以及运动页的运动格与外接框。Logo 的 ROM 只有一份，因此所有页面都有 Logo，同时不增加存储。'
     '字体和文字都用 LUT 逻辑生成，字符定位采用逐像素计数器，以节省面积。')
figure('cv_page_coldboot.jpg', '图3-2 断电冷启动后的 CV 页：安路 Logo、中文标题、识别面板、右上角延迟读数', 12.0)
doc.add_heading('3.9 外部控制：机器人联动（扩展3）', 2)
para('FPGA 每 0.2 s 输出一行识别报告。桥接程序（walle_bridge.py）解析报告，生成以下事件：主导颜色出现或切换（新颜色面积需大于原颜色的 1.5 倍，且连续 2 行）、目标在左 / 中 / 右（带回差）、越线、全部消失；'
     '然后通过机器人自带的局域网 WebSocket 发出命令（瓦力固件的 self.wali.* 工具）。动作类命令一次只发一条，等机器人回复“完成”后再发下一条，只保留最新的待发命令。')
bullets(['手势规则：红色 → 眼灯变红并挥手；绿色 → 点头；蓝色 → 眼灯变蓝并呼吸闪烁；目标在左 / 右 → 举左臂 / 右臂；越线 → 眼灯闪烁。',
         '移动规则（红绿灯 + 方向盘）：绿色 → 前进，目标在左 / 右时转向；蓝色 → 后退；红色 → 立即停止。每段移动 0.5–0.7 s、速度 40/90，链路断开时机器人会自行停下。',
         'FPGA 在 J1 第 1 脚额外输出一路串口，后续可由 ESP32 直接读取并控制机器人，不再需要电脑【进行中】。'])
figure('walle.jpg', '图3-3 联动的 WALL-E 机器人（ESP32-S3，局域网控制）', 7.0)
page_break()

# ------------------------------------------------------------------ 4
doc.add_heading('第4章 验证方法', 1)
doc.add_heading('4.1 分层验证流程', 2)
bullets(['模块级：每个自研模块都有自检测试台。算法类模块配有独立参考模型（Python 或测试台内模型），逐像素、逐位比较。',
         '变异测试：在 RTL 中逐个植入小错误（改常数、改比较方向、删一项条件等），检查测试台能否抓到。抓不到的，要么补测试，要么论证为等价变异。',
         '系统级：contest_vision_v2 在真实 1280×720 时序下仿真 20 帧（ModelSim），YOLO 检测器整机仿真与整数参考逐位一致；ISP 的 ROM 初值经门级网表仿真确认。',
         '构建：TD 6.2.1 命令行完整构建，检查时序（建立 / 保持）、资源和 RAM 推断（无 SYN-5105 告警）；工程校验脚本核对源码与发布位流的一致性和 SHA256。',
         '上板：先只写 SRAM 验收；用户确认后写 Flash；最后做断电冷启动验证和 30 分钟连续运行记录。'])
doc.add_heading('4.2 变异测试结果', 2)
table(['模块', '测试台', '变异体结果'], [
    ['isp_color（ISP）', '15 帧逐位比较（Python 参考模型）', '34/34 被发现'],
    ['isp_color 灰像素门限', '同上，开启门限与中性初值', '9/9'],
    ['wb_ctrl（白平衡页）', '776 个手动增益值全扫描', '35/35'],
    ['motion_det（帧差）', '8 帧逐单元比较', '17/20，其余 3 个经论证与原电路等价'],
    ['lat_probe（延迟）', '跨时钟同步、时间戳、测量逻辑', '18/18'],
    ['top_osd（叠加）', '2 帧逐像素比较 + 文字校验和', '19/19'],
    ['he_eq（直方图均衡）', '5 帧逐像素比较', '21/21'],
    ['osd_overlay（早期 OSD）', '黄金图像比较', '61/61'],
    ['cross_counter（越线）', '定向场景', '30/32，其余 2 个等价'],
], widths=[4.2, 6.6, 4.4], caption='表4-1 变异测试统计')
para('变异测试多次暴露测试台的覆盖缺口，例如没有覆盖“增益下限生效”的场景、窗口最大值恰好在最后一帧、两位相同数字对调等，补测后全部被发现。'
     '同时也发现过真实的 RTL 缺陷，例如直方图曲线高度在 7 位加法时回绕，已修复，并把错误写法加入变异集。')
page_break()

# ------------------------------------------------------------------ 5
doc.add_heading('第5章 测试结果', 1)
doc.add_heading('5.1 资源与时序', 2)
table(['资源', '使用 / 总量', '占用率'], [
    ['Slice', '21138 / 21216', '99.63%'],
    ['LUT6', '20423 / 21216', '96.26%'],
    ['寄存器', '20403 / 42432', '48.08%'],
    ['ERAM（20 Kbit）', '107 / 108', '99.07%'],
    ['DSP', '37 / 40', '92.50%'],
], widths=[4.0, 5.0, 3.0], caption='表5-1 最终版（adv03）资源占用')
para('最终版建立时间裕量 +0.264 ns、保持时间裕量 +0.020 ns，0 违例端点。为把全部功能装进同一器件，去掉了仅用于调试的平场诊断与测试图案；'
     '把文字定位改为计数器，把直方图曲线的常数乘法改为移位；运动检测的累加改用移位环（SRL），直方图三张表放在 LUT RAM 中，节约了 ERAM。')
doc.add_heading('5.2 实时性', 2)
table(['项目', '结果'], [
    ['摄像头 / 显示帧率', '59–60 / 60–61 帧/秒（片上 50 MHz 晶振时基测量）'],
    ['采集→显示延迟', '约 35–48 ms，即 2 帧；64 帧窗口最大 50.7 ms（屏幕实时显示）'],
    ['识别报告', '每 0.2 s 一行串口报告'],
    ['YOLO', '每秒 30 次检测，取样到出框 27 ms'],
    ['显示路径', '每拍一像素，固定延迟，不阻塞视频'],
], widths=[4.0, 11.2], caption='表5-2 实时性指标')
doc.add_heading('5.3 稳定性', 2)
para('最终固化方案冷启动后，用 tools/board/uart_soak.py 连续记录 30 分钟串口：共 8569 行报告（4.76 行/秒），格式错误 0 行，没有出现“一秒内无报告”的情况；'
     '片上帧率计显示摄像头 59–60 帧/秒（均值 59.52）、显示 60–61 帧/秒（均值 60.61）。每秒的记录保存在 logs_custom/soak/。')
doc.add_heading('5.4 画质：镜头阴影与白平衡', 2)
table(['白纸平场（边角 / 中心）', '校正前', '校正后'], [
    ['R/G', '1.19', '1.02'],
    ['B/G', '1.18', '1.03'],
    ['亮度', '0.74', '0.96'],
], widths=[5.5, 3.0, 3.0], caption='表5-3 镜头阴影校正效果（白纸平场实测）')
para('白平衡改为“只统计近中性像素”之前，大片蓝色板会把增益带偏到 R6.88 / G2.32 / B0.77，旁边的中性区域被染成橙红。'
     '改进后，面对同一块蓝板，增益保持在 R4.58 / G2.51 / B4.28 不变；普通场景测量窗平均值为 R126 / G126 / B127，对着灯时灯本身为白色，'
     '三个场景的增益比例都稳定在 R/G≈1.82、B/G≈1.71。')
figure_pair('wb_adv02_blueboard.jpg', '改进前：蓝板把增益带偏（B 0.77），右侧被染成橙红',
            'wb_adv03_blueboard.jpg', '改进后：增益保持不变（R4.58 G2.51 B4.28）', 7.6, '图5-1 白平衡改进前后对比（WB 页读数）')
figure_pair('wb_adv03_normal.jpg', '普通场景：测量窗 R126 G126 B127', 'wb_adv03_coldboot.jpg', '冷启动后：R116 G117 B118', 7.6, '图5-2 最终版白平衡实测')
page_break()

# ------------------------------------------------------------------ 6
doc.add_heading('第6章 问题分析与解决', 1)
issues = [
    ('画面中心偏绿、四周偏红',
     '没有直接叠加全局通道增益，而是先用片上平场诊断模块取数据：白纸平场 16×9 格统计和暗场黑电平测量。结果确认是镜头颜色阴影加上未扣黑电平，排除了“帧内 AWB 漂移”和“通道顺序错误”两种假设。'
     '据此设计了黑电平扣除和多项式拟合的 21×13 节点阴影校正，边角 / 中心颜色比从 1.19 降到 1.02。'),
    ('暗场景整片发绿',
     '原因是闭环增益逐通道截在 4.0：暗场景下三路都被截住、彼此相等，白平衡失效。改为“三路等比例限幅”，上限提高到 8.0，统计也只取有效像素。图6-1 为修复前的现场照片。'),
    ('大面积彩色物体使白平衡失效',
     'WB 页读数证实了灰度世界算法的固有缺陷：大片蓝板把 B 增益压到 0.77。改为只统计近中性像素（|R−G|、|B−G| ≤ G/2），近中性像素不足时保持原增益，并用实测中性增益作为上电初值。'),
    ('目标 Y 坐标常为 0',
     '串口一直报一个 X≈640、Y=0、面积约 1900 的“红色目标”，而画面中并没有红色物体。按 cy=(ymin+ymax)/2 推算，命中只在第 0..1 行；结合面积约 1.5 行 × 1280 列，判断为帧缓存最上面几行的偏色伪像。'
     '它还把真实目标的 ymin 拉到 0。在统计前屏蔽画面四周 4 像素宽的边框后，问题消失，ModelSim 系统回归在屏蔽前后都通过。'),
    ('偶发整幅纯红或纯蓝画面',
     '排查确认不是逻辑问题：摄像头排线弯折时，其中一条 MIPI lane 接触不良，画面只剩一个颜色通道；换回旧位流也能复现。重新插紧并固定排线后问题消失。'
     '同时也验证了新白平衡的鲁棒性：异常数据下增益保持不变，而旧版本会被推到 8.0 上限。'),
    ('资源紧张与写 Flash 失败',
     '加入灰像素门限后，Slice 需求超过器件 34 个。通过“文字定位改计数器、曲线去乘法”回收面积，最终占用 99.63%。'
     '写 Flash 时遇到 USB-JTAG 枚举不完整和擦除等待不足导致的校验错误，改为直连 USB、确认设备枚举完整、擦除等待 180 s 后写入成功，并通过冷启动验证。'),
]
for i, (t, s) in enumerate(issues, 1):
    doc.add_heading('6.%d %s' % (i, t), 2)
    para(s)
    if i == 2:
        figure('isp02_green.jpg', '图6-1 修复前：暗场景下整片发绿（isp02，WB 增益全被截在 4.0）', 9.5)
page_break()

# ------------------------------------------------------------------ 7
doc.add_heading('第7章 总结与展望', 1)
para('本作品在一片 PH1P35 中，以全流水线硬件实现了从 MIPI 采集、自研 ISP 到识别、检测、运动分析、延迟测量和外部控制的完整实时视觉系统，覆盖了选题二的全部基础、扩展和进阶要求。'
     '所有功能都在同一个位流中，已固化到 Flash，上电即运行。设计过程坚持数据驱动和可复现：画质问题先测量再修改，每个模块都有参考模型和变异测试，'
     '每次构建记录时序、资源和位流哈希，每次上板记录用户的实物反馈。')
para('后续工作：用真实零件数据微调片上 YOLO 并给出真实测试集指标；用 ESP32 代替电脑完成机器人桥接，使外部控制也脱离 PC；'
     '在传感器侧实现曝光与模拟增益闭环，降低暗场景下的数字增益噪声。')

doc.add_heading('附录 A 版本与文件', 1)
table(['项目', '内容'], [
    ['最终位流', 'release/contest_work_v3_20261027_adv03.bit（SHA256 c81d8d21dd37e6a9…be5623）'],
    ['工程', 'contest_work_v3_adv（TD 6.2.1，top = design_top_wrapper，PH1P35MDG324-3）'],
    ['自研 RTL', 'rtl_custom/：isp_color、contest_vision_v2 及子模块、yolo_*、motion_det、lat_probe、he_eq、top_osd、wb_ctrl、wb_osd 等'],
    ['测试台与工具', 'tb_custom/（自检测试台、ModelSim 脚本）、tools/wb/wb_mutants.py（变异测试）、tools/shade（平场 / LSC / 参考模型）、tools/yolo（训练 / 导出）'],
    ['上板工具', 'tools/board/program_sram.ps1、program_flash.ps1、uart_soak.py；机器人：tools/robot/'],
], widths=[3.2, 12.0], caption='表A-1 版本与文件')

os.makedirs(os.path.dirname(OUT), exist_ok=True)
doc.save(OUT)
print('wrote', OUT)
