#!/usr/bin/env python3
"""make_report_official.py - the contest report filled into the OFFICIAL template (docs/report/template/official_template.docx)

    F:/yolo_env/Scripts/python.exe tools/report/draw_block.py ; draw_diagrams.py ; draw_official.py      (figures)
    python tools/report/make_report_official.py [out.docx]          (default docs/report/作品报告_官方模板.docx; needs python-docx: system Python)

The template's headings, numbering and styles are kept; every hint paragraph ("800字内", "400字内（可加重要图）；" ...) is replaced by content.
No school, team or teacher names anywhere (template rule). Numbers come from docs/STATUS_FOR_CODEX.md, docs/YOLO_REAL_2026-10-28.md,
docs/ESP32_BRIDGE_2026-10-27.md, docs/ADV_2026-10-26.md, docs/ISP_COLOR_2026-10-26.md, release/README.txt, logs_custom/soak/ and the TD
reports of cli_advy03 (the bitstream in the configuration flash since 2026-10-28). 【待补】 = a photo the team still has to take.
At the end the script prints the character count of every section that has a limit in the template.
"""
import os
import re
import sys

import docx
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
IMG = os.path.join(ROOT, 'docs', 'report', 'img')
TPL = os.path.join(ROOT, 'docs', 'report', 'template', 'official_template.docx')
OUT = os.path.join(ROOT, 'docs', 'report', sys.argv[1] if len(sys.argv) > 1 else '作品报告_官方模板.docx')
D = docx.Document(TPL)
COUNT = {}                    # section -> [limit, characters of its body paragraphs]
FIG = [0]
TAB = [0]


def set_run(r, size=12, bold=False, east='宋体', color=None):
    r.font.name = 'Times New Roman'
    r.font.size = Pt(size)
    r.bold = bold
    rpr = r._r.get_or_add_rPr()
    rf = rpr.find(qn('w:rFonts'))
    if rf is None:
        rf = OxmlElement('w:rFonts')
        rpr.insert(0, rf)
    for k in ('w:ascii', 'w:hAnsi'):
        rf.set(qn(k), 'Times New Roman')
    rf.set(qn('w:eastAsia'), east)
    if color is not None:
        r.font.color.rgb = color


def borders(tbl):
    tblpr = tbl._tbl.tblPr
    b = OxmlElement('w:tblBorders')
    for side in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'):
        e = OxmlElement('w:' + side)
        e.set(qn('w:val'), 'single'); e.set(qn('w:sz'), '6'); e.set(qn('w:space'), '0'); e.set(qn('w:color'), '808080')
        b.append(e)
    tblpr.append(b)


def shade(cell, fill):
    tcpr = cell._tc.get_or_add_tcPr()
    s = OxmlElement('w:shd')
    s.set(qn('w:val'), 'clear'); s.set(qn('w:color'), 'auto'); s.set(qn('w:fill'), fill)
    tcpr.append(s)


class At:
    """inserts new blocks after an anchor element, in order; `sec` names the counted section"""

    def __init__(self, el, sec=None):
        self.el, self.sec = el, sec

    def _put(self, el):
        self.el.addnext(el)
        self.el = el

    def p(self, text, size=12, bold=False, indent=True, align=None, color=None, count=True, east='宋体'):
        para = D.add_paragraph()
        pf = para.paragraph_format
        if indent:
            pf.first_line_indent = Cm(0.85)
        pf.line_spacing = 1.35
        pf.space_after = Pt(3)
        if align is not None:
            para.alignment = align
        for k, seg in enumerate(re.split(r'\*\*', text)):              # **bold** segments
            if seg:
                set_run(para.add_run(seg), size, bold or k % 2 == 1, east, color)
        if self.sec and count:
            COUNT[self.sec][1] += len(re.sub(r'\s', '', text.replace('**', '')))
        self._put(para._p)
        return para

    def sub(self, text):
        return self.p(text, 12, True, indent=False, count=False, east='黑体')

    def items(self, rows):
        for i, s in enumerate(rows, 1):
            para = self.p('（%d）%s' % (i, s))
            para.paragraph_format.first_line_indent = Cm(0.85)

    def code(self, lines):
        for s in lines:
            para = D.add_paragraph()
            para.paragraph_format.space_after = Pt(0)
            para.paragraph_format.left_indent = Cm(0.5)
            r = para.add_run(s)
            set_run(r, 8.5, east='宋体')
            r.font.name = 'Consolas'
            self._put(para._p)

    def todo(self, text):
        self.p('【待补】' + text, 11, color=RGBColor(0xC0, 0x30, 0x30), count=False)

    def fig(self, name, caption, width=14.5):
        FIG[0] += 1
        para = D.add_paragraph()
        para.alignment = WD_ALIGN_PARAGRAPH.CENTER
        para.add_run().add_picture(os.path.join(IMG, name), width=Cm(width))
        para.paragraph_format.keep_with_next = True                     # picture stays on the page of its caption
        self._put(para._p)
        self.p('图%d  %s' % (FIG[0], caption), 10.5, indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, count=False)

    def fig_pair(self, a, ca, b, cb, caption, width=7.3):
        FIG[0] += 1
        t = D.add_table(rows=2, cols=2)
        t.alignment = WD_TABLE_ALIGNMENT.CENTER
        for i, (n, c) in enumerate(((a, ca), (b, cb))):
            cp = t.rows[0].cells[i].paragraphs[0]
            cp.alignment = WD_ALIGN_PARAGRAPH.CENTER
            cp.add_run().add_picture(os.path.join(IMG, n), width=Cm(width))
            lp = t.rows[1].cells[i].paragraphs[0]
            lp.alignment = WD_ALIGN_PARAGRAPH.CENTER
            set_run(lp.add_run(c), 10)
        self._put(t._tbl)
        self.p('图%d  %s' % (FIG[0], caption), 10.5, indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, count=False)

    def fig_grid(self, items, caption, width=7.3):
        """items: [(image, label), ...] laid out two per row, one caption for the whole figure"""
        FIG[0] += 1
        rows = (len(items) + 1) // 2
        t = D.add_table(rows=2 * rows, cols=2)
        t.alignment = WD_TABLE_ALIGNMENT.CENTER
        for k, (n, c) in enumerate(items):
            r, col = 2 * (k // 2), k % 2
            cp = t.rows[r].cells[col].paragraphs[0]
            cp.alignment = WD_ALIGN_PARAGRAPH.CENTER
            cp.add_run().add_picture(os.path.join(IMG, n), width=Cm(width))
            lp = t.rows[r + 1].cells[col].paragraphs[0]
            lp.alignment = WD_ALIGN_PARAGRAPH.CENTER
            set_run(lp.add_run(c), 10)
        self._put(t._tbl)
        self.p('图%d  %s' % (FIG[0], caption), 10.5, indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, count=False)

    def table(self, header, rows, widths, caption):
        TAB[0] += 1
        self.p('表%d  %s' % (TAB[0], caption), 10.5, True, indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, count=False).paragraph_format.keep_with_next = True
        t = D.add_table(rows=1, cols=len(header))
        t.alignment = WD_TABLE_ALIGNMENT.CENTER
        borders(t)
        for i, h in enumerate(header):
            c = t.rows[0].cells[i]
            set_run(c.paragraphs[0].add_run(h), 10, True)
            shade(c, 'D9E2F3')
        for row in rows:
            cells = t.add_row().cells
            for i, v in enumerate(row):
                set_run(cells[i].paragraphs[0].add_run(str(v)), 10)
        t.autofit = False
        grid = t._tbl.tblGrid
        for i, gc in enumerate(grid.findall(qn('w:gridCol'))):
            gc.set(qn('w:w'), str(int(widths[i] * 567)))
        for row in t.rows:
            for i, w in enumerate(widths):
                row.cells[i].width = Cm(w)
        self._put(t._tbl)
        sp = D.add_paragraph()
        self._put(sp._p)


def paras():
    return list(D.paragraphs)


def find(text, start=0):
    ps = paras()
    for i in range(start, len(ps)):
        if ps[i].text.strip().startswith(text):
            return ps[i]
    raise KeyError(text)


def set_text(p, text):
    runs = p.runs
    runs[0].text = text
    for r in runs[1:]:
        r._r.getparent().remove(r._r)


def remove(p):
    p._p.getparent().remove(p._p)


def page_break_before(p):
    p.paragraph_format.page_break_before = True                        # a property, not a break paragraph: no blank page when the previous page is full
    prev = p._p.getprevious()                                          # empty spacer paragraphs right before the part would overflow onto a blank page
    while prev is not None and prev.tag == qn('w:p') and not ''.join(prev.itertext()).strip() and not prev.findall('.//' + qn('w:drawing')):
        nxt = prev.getprevious()
        prev.getparent().remove(prev)
        prev = nxt


def hint_after(heading_text, sec=None, limit=None):
    """At() positioned on the hint paragraph that follows a template heading; the hint itself is removed"""
    h = find(heading_text)
    ps = paras()
    k = [q._p for q in ps].index(h._p) + 1                             # proxies are recreated on every access: compare the elements
    while not ps[k].text.strip():
        k += 1
    hint = ps[k]
    at = At(hint._p, sec)
    if sec:
        COUNT[sec] = [limit, 0]
    return at, hint


# ================================================================== title / abstract
title = find('作品名称')
set_text(title, '基于安路 PH1P35 的全流水线实时视觉处理与机器人联动系统')
remove(find('（不要出现任何涉及学校名称等内容）'))

at, hint = hint_after('摘要', '摘要', 800)
at.p('本作品用安路 HX1P35A 开发板（PH1P35MDG324）做了一套实时视觉处理与机器人联动系统，上电即运行，演示时不接电脑。'
     'SC500CS 摄像头输出 1280×720@60 视频，经 MIPI CSI-2 接收、自研 ISP 和 DDR2 帧缓存后，由 FPGA 内的 HDMI 发送逻辑输出。'
     '显示端的图像处理都是每个像素时钟处理一个像素的流水线，各分析模块只读取视频流，不会让画面停顿。全部功能在同一个位流里，已固化到配置 Flash。')
at.p('ISP 是先测量再设计的：片上诊断模块取到白纸平场和暗场数据后，我们做了黑电平扣除、21×13 节点镜头阴影校正，以及只统计近中性像素的闭环白平衡与数字曝光，'
     '白纸平场四角 R/G 相对中心由 1.21 降到 1.02。识别方面有三色分割、形状分类、目标跟踪和越线计数，另外在片上部署了由 YOLOv3-tiny 裁剪而来的 int8 检测网络。'
     '这个网络只用合成图训练时，实拍 mAP50 只有 0.04；改用板上 CAPTURE 页采集的实拍数据并加入反例微调后，实拍验证集 mAP50 为 0.84，'
     '从取样到出框 27 ms，头和手不再被误检。进阶部分有 7 个页面的切换与状态显示、32×18 单元的硬件帧差运动检测、采集到显示的延迟实时显示（约 35 ms，即 2 帧）和直方图均衡。'
     '识别结果从一根 GPIO 串口单向发给 ESP32，ESP32 再通过 Wi-Fi 让 WALL-E 机器人挥手、点头、举臂、改变眼灯颜色，传统识别和 YOLO 都能驱动。')
at.p('每个自研模块都有参考模型和逐位比对的测试台，并用变异测试检查测试台本身有没有漏查。最终版本建立时间裕量 +0.144 ns，Slice 占用 99.58%；'
     '从 Flash 冷启动后连续运行 30 分钟，串口报告没有中断，摄像头与显示帧率分别保持在 59～60 和 60～61 帧/秒。')
at.p('**关键词：**FPGA；实时图像处理；ISP；YOLO；目标检测；外部控制', indent=False)
remove(hint)

# ================================================================== part 1
at, hint = hint_after('功能与特性', '1.1 功能与特性', 400)
at.p('从图像采集到外部控制，所有环节都在一片 PH1P35 上完成。选题二的基础、扩展和进阶要求逐项在实物上验证过：')
at.items(['视频链路：MIPI 摄像头 1280×720@60 采集，经自研 ISP 和 DDR2 帧缓存后由 HDMI 实时输出；',
          '图像处理：三色分割（固定阈值，或随场景亮度变化的自适应阈值）、灰度、二值化、Sobel 边缘，以及素描、卡通、伪彩色等风格化视图，共 8 种显示；',
          '检测识别：三色目标定位、形状分类、跟踪与越线计数；片上 int8 YOLO 检测三种实物；',
          '进阶分析：硬件帧差运动检测、采集到显示的延迟测量、直方图均衡、白平衡调节页；',
          '人机交互：KEY3+KEY4 在 7 个页面间切换，每页都叠加安路 Logo、状态文字和检测框；',
          '外部控制：识别结果经 ESP32 控制 WALL-E 机器人。'])
at.p('位流已写入配置 Flash，断电后重新上电直接进入工作状态。')
at.fig('cv_page_coldboot.jpg', '断电冷启动后的 CV 页（安路 Logo、中文标题、识别面板、右上角延迟读数）', 11.0)
remove(hint)

at, hint = hint_after('应用领域', '1.2 应用领域', 400)
at.items(['工业分拣与产线计数。颜色、形状识别加越线计数，可以统计传送带上各类物料的数量，再把结果交给外部控制器去驱动分拣机构。',
          '机器人和小车的视觉前端。FPGA 负责看和判断，执行端的处理器只需要解析一行文本报告，本作品里的 ESP32 就是这样工作的。',
          '运动监测。帧差检测在硬件里逐帧完成，画面延迟可以实时读出，适合需要知道画面“有多旧”的监控场合。',
          '教学实验。ISP 的每一级、int8 网络的每一步都有对应的显示页面或串口输出，可以用来讲解从数据采集、训练到硬件推理的过程。'])
at.p('系统不依赖电脑，开发板加摄像头的体积和功耗都适合嵌入式部署。')
remove(hint)

at, hint = hint_after('主要技术特点', '1.3 主要技术特点', 400)
at.items(['流水线结构，延迟固定。显示域每个时钟处理一个像素，识别、YOLO、运动检测等模块只读取帧缓存读出的视频流，视频不用等它们；YOLO 与视频在同一时钟域，不需要额外的跨时钟逻辑。',
          'ISP 参数来自测量。先用片上诊断模块拍白纸平场和暗场，再确定黑电平、阴影校正表（多项式拟合）和白平衡的统计方法，没有凭照片去调全局增益。',
          '检测网络完全在片上运行。卷积、解码和 NMS 都在 FPGA 内完成，权重放在片上 ROM，不访问 DDR；从训练、量化到 RTL，结果逐位一致。',
          '实时性能直接看到。帧缓存每帧写入微秒时间戳，屏幕右上角显示延迟；帧率计以板上 50 MHz 晶振为时基。',
          'Slice 用到 99.58% 时时序仍然收敛。'])
remove(hint)

at, hint = hint_after('主要性能指标', '1.4 主要性能指标', 200)
at.table(['指标', '实测值'], [
    ['视频', '1280×720@60，RGB888'],
    ['帧率（30 分钟均值）', '摄像头 59.52 / 显示 60.61 帧/秒'],
    ['采集→显示延迟', '约 35 ms（2 帧），最大约 51 ms'],
    ['YOLO', '取样到出框 27 ms；实拍 mAP50 0.84'],
    ['稳定性', '30 分钟 8569 行报文，0 秒中断'],
    ['平场均匀性', '四角 R/G 1.21→1.02'],
    ['资源 / 时序', 'Slice 99.58%，ERAM 107/108；+0.144 ns'],
], [4.6, 9.4], '主要性能指标')
remove(hint)

at, hint = hint_after('主要创新点', '1.5 主要创新点', 200)
at.items(['ISP 先测量后校正，白平衡只统计近中性像素，大片彩色物体不会把它带偏；',
          '整个 int8 YOLO 都在 FPGA 内运行，用板上采集的实拍数据和反例微调，实拍 mAP50 由 0.04 提高到 0.84；',
          '在帧缓存里写时间戳，把采集到显示的延迟实时显示在屏幕上；',
          '识别结果单向输出，ESP32 不经电脑直接控制机器人，传统识别和 YOLO 都能驱动。'])
remove(hint)

at, hint = hint_after('设计流程', '1.6 设计流程', 200)
at.p('流程依次是需求分析、测量诊断、RTL 与 Python 参考模型、逐位仿真与变异测试、TD 完整构建、SRAM 上板验收，最后写入 Flash 做冷启动和 30 分钟稳定性测试。'
     '上板发现的问题回到测量和设计环节重新走一遍。YOLO 另有一条数据支线：板上采集，自动标注加人工复核，微调训练，int8 量化后导出 ROM。')
at.fig('design_flow.png', '设计流程', 15.5)
remove(hint)

# ================================================================== part 2
p2 = find('第二部分')
page_break_before(p2)
remove(find('阐述具体的设计细节'))
at, hint = hint_after('整体介绍')
at.fig('system_block.png', '系统总体框图', 15.8)
at.p('系统分为两个时钟域和一个外部控制部分：')
at.items(['摄像头时钟域（MIPI 字节时钟）：MIPI 接收与解包 → 去马赛克 → 自研 ISP（isp_color：黑电平、镜头阴影校正、闭环白平衡与数字曝光）→ 时间戳写入（ts_stamp）→ DDR2 帧缓存，每拍 4 个像素。',
          '显示时钟域（HDMI 像素时钟 75 MHz）：读出帧缓存 → 位置适配，之后传统视觉（三色分割、形状、跟踪、越线计数、风格化）、片上 YOLO、帧差运动检测、延迟测量、直方图均衡和白平衡页同时读取这一路视频 → 逐级叠加（识别 OSD → YOLO 框 → 白平衡页 → top_osd：每页的 Logo 与延迟读数）→ FPGA 内 HDMI 发送。',
          '外部控制：识别报告同时从 USB 串口和 J1 第 1 脚输出；J1 这一路接 ESP32，ESP32 通过 Wi-Fi WebSocket 控制 WALL-E 机器人。',
          '人机交互：KEY3+KEY4 切换 7 个页面，拨码切换视图，按键调节白平衡与计数线；LED、数码管和蜂鸣器给出提示。'])
at.p('两个时钟域之间只通过帧缓存和少量格雷码 / 握手同步的状态量交换数据（白平衡增益读回、时间戳、帧号），SDC 中声明了对应的异步时钟组。')
remove(hint)

h = find('2.2.1 硬件整体介绍')
at = At(h._p)
set_text(h, '2.2.1 硬件整体介绍')
h.runs[0].bold = True
at.table(['部件', '型号 / 说明'], [
    ['FPGA 开发板', 'HX1P35A（安路 PH1P35MDG324-3，42,432 DFF / 38,189 LUT），板载 DDR2、配置 SPI Flash、USB-JTAG/UART、拨码、按键、数码管、蜂鸣器、40 针扩展口 J1'],
    ['摄像头', 'SC500CS，MIPI CSI-2 两 lane，RAW10，配置为 1280×720@60'],
    ['显示器', 'HDMI 1280×720'],
    ['外部控制器', 'ESP32 DevKit V1（ESP-WROOM-32，CP2102 USB 串口）+ 30P 扩展板'],
    ['执行设备', 'WALL-E 机器人（ESP32-S3，局域网 WebSocket 控制，双臂、点头、眼灯、履带移动）'],
    ['演示网络', '手机或电脑热点（2.4 GHz），只作为局域网，不运行任何程序'],
], [3.0, 11.5], '硬件组成')
at.fig('board_setup.jpg', '实物平台（HX1P35A 开发板与 SC500CS 摄像头）', 10.5)

h = find('2.2.2 机械设计介绍')
at = At(h._p)
set_text(h, '2.2.2 机械设计介绍')
h.runs[0].bold = True
at.p('本作品不涉及专门的机械结构设计。摄像头模组用排线连接开发板，演示时镜头朝上拍摄，由人手持目标物体在镜头上方移动；'
     'WALL-E 为成品机器人；ESP32 与开发板之间只用两根杜邦线连接（信号与地）。'
     '摄像头排线弯折时曾出现单条 MIPI lane 接触不良（画面只剩一个颜色通道），因此演示时需要固定摄像头和排线。', count=False)

h = find('2.2.3 电路各模块介绍')
at = At(h._p)
set_text(h, '2.2.3 电路各模块介绍')
h.runs[0].bold = True
at.p('FPGA 与外部控制器之间只有一路单向 3.3 V 串口和一根地线，FPGA 只发不收：', count=False)
at.table(['信号', 'FPGA 端', 'ESP32 端', '说明'], [
    ['识别报告 TX', 'J1 第 1 脚（GPIOA_0，FPGA 引脚 V2）', 'D16（UART2 RX）', 'LVCMOS33，115200 8N1，与 USB 串口内容相同'],
    ['地', 'J1 第 30 脚（GND）', '电源排针 GND', '必须共地；FPGA 的 5V 不接到 ESP32'],
    ['供电', '开发板电源适配器', 'Micro-USB（充电头 / 充电宝）', '两块板各自供电'],
], [2.4, 4.6, 3.2, 4.8], 'FPGA 与 ESP32 的连接')
at.fig('esp32_wiring.png', 'ESP32 接线图（含本地状态终端：OLED 与三色灯）', 15.5)
at.p('ESP32 上还接了一个自己做的本地状态终端，机器人没反应时，先看它就知道控制链路断在哪一环：'
     '0.96 寸 OLED（I2C，SDA/SCL 接 GPIO21/22，驱动为自写的 SSD1306 页寻址程序和 5×7 字库）实时显示规则模式与机器人连接状态、IP、'
     '每秒收到的报告行数与数据来源（传统识别或 YOLO）、红绿蓝各自的位置与面积、最近的事件和最近发给机器人的命令；'
     '红、绿、蓝三色 LED（GPIO25/26/27，分别串 220 Ω、100 Ω、100 Ω）在对应颜色的目标有效时点亮。'
     '原计划的舵机指针在 USB 供电下启动电流过大，使 ESP32 欠压复位，因此没有采用。', count=False)
at.p('开发板侧使用的其他引脚：按键 KEY1～KEY4（D5、A9、B9、C7），拨码 SW1～SW4，LED1～LED4，蜂鸣器（C12），USB 串口 TX（H1），J1 串口副本（V2），均按开发板手册的引脚分配约束。', count=False)

at.sub('2.2.4 外部执行设备：WALL-E 机器人的组成与接口')
at.p('WALL-E 是外购的成品桌面机器人，在本作品中只作为执行设备，相当于赛题 Q&A 中所说的“小车、机械臂等复杂外设”。'
     '我们没有修改它的固件，只使用其固件自带的局域网控制接口；识别、决策和命令生成全部由 FPGA 与自研的 ESP32 固件完成。'
     '为了说明它不是“黑箱”，下面给出它的组成、接口和实测行为，依据是：机器人 USB 串口输出的开机日志、它自带控制台网页的脚本，'
     '以及它通过 WebSocket 返回的工具列表（tools/list）。', count=False)
at.fig('robot_block.png', 'WALL-E 机器人组成与控制接口', 15.8)
at.table(['部件', '型号 / 参数', '依据'], [
    ['主控', 'ESP32-S3（芯片版本 v0.2），8 MB 八线 PSRAM，QIO SPI Flash，Wi-Fi', '开机日志'],
    ['电机驱动', 'DRV8833 双 H 桥，LEDC PWM 20 kHz / 10 位；左轮速度 GPIO17、方向 GPIO18，右轮速度 GPIO13、方向 GPIO14', '开机日志'],
    ['执行机构', '左右履带由减速电机驱动；双臂与头部舵机（头部只能俯仰）', '开机日志（arms=1 head=1）、拆解照片、舵机工具实测'],
    ['眼灯', 'WS2812 × 2，RMT 驱动，GPIO8', '开机日志'],
    ['供电', '锂电池；主控板上有电源开关和 USB Type-C', '拆解照片'],
    ['其他', 'ILI9341 屏幕、按键、音频编解码（语音对话）', '开机日志'],
    ['固件', '小智 AI v2.4.2（ESP-IDF 5.5.2），SKU linxia-wali；内置控制台网页与 WebSocket 服务', '开机日志、控制台网页'],
    ['调试接口', 'ESP32-S3 自带 USB 串口 / JTAG（VID 303A，PID 1001），本作品只用它读取日志', '设备管理器'],
], [2.2, 9.6, 3.2], '机器人主要部件（实测）')
at.table(['消息 / 工具', '格式与参数', '本作品的用法'], [
    ['心跳', '文本 ping，每 1.5 s 一次', '保持连接；6 s 收不到回应即判定断线，按 1～4 s 退避重连'],
    ['move', '{"type":"move","dir":forward / backward / left / right / spinleft / spinright / stop,"speed":20～100}', '急停（stop）'],
    ['self.wali.action', 'action = wave / arm_left / arm_right / nod / dance / stop；动作做完才回复', '红色挥手、绿色点头、目标偏左 / 右举左 / 右臂'],
    ['self.wali.eye', 'action = color（#RRGGBB）/ pulse / flash / blink / off / mood', '眼灯随目标颜色变化；蓝色闪烁 3 次；越线闪烁'],
    ['self.wali.mood', '21 种表情，同时改变眼灯和身体动作', '只用 neutral（目标消失后恢复平静）；其余会带动轮子，桌面演示不用'],
    ['self.wali.servo', '{servo: left_arm / right_arm / head, angle 0～180}，立即回复', '蓝色：双臂举到 60°，1.8 s 后放回 120°'],
    ['self.wali.move', '{direction, speed, duration 毫秒} 定时移动', '移动规则：绿行、蓝退、左右转向（0.5～0.7 s，速度 40）'],
    ['回复', 'JSON-RPC result：“ok”或“<动作> 动作执行完成”', 'ESP32 收到“完成”后才发下一个动作'],
], [2.8, 6.6, 5.6], '机器人控制接口（局域网 WebSocket ws://IP/ws）')
at.p('实测动作时长：挥手约 6.5 s，举右臂约 4 s，点头约 2.2 s。'
     '下面是一次完整的“识别 → 命令 → 执行 → 回复”记录（ESP32 串口日志节选，CV 页红色物体出现，2026-10-27），'
     '“->”为 ESP32 发出的命令，“<-”为机器人的回复，左列为秒：', count=False)
at.code(['52.4 event: appear R',
         '52.4 -> self.wali.eye {"action":"color","color":"#FF0000"}',
         '52.4 -> self.wali.action {"action":"wave"}',
         '52.6 <- {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}],"isError":false}}',
         '58.9 <- {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"wave 动作执行完成"}],"isError":false}}',
         '58.9 -> self.wali.mood {"mood":"neutral"}'])
at.table(['部分', '来源', '内容'], [
    ['视频采集、ISP、识别、YOLO、OSD', '自研（FPGA）', '全部检测与赛题指标都在 FPGA 内完成'],
    ['识别报告与串口输出', '自研（FPGA）', '传统报告 / YOLO 报告，115200 8N1，单向发送'],
    ['ESP32 桥接固件', '自研', '报告解析、主导颜色与左右判断、防抖、动作排队、WebSocket 客户端、自动查找机器人'],
    ['ESP32 本地状态终端', '自研（OLED 驱动、显示与指示逻辑）', 'OLED 显示收到的报告、事件与发出的命令；三色灯按颜色点亮'],
    ['控制规则', '自研', '颜色 → 动作的对应关系，手势 / 移动两套，BOOT 键切换'],
    ['WALL-E 机器人', '外购成品，固件未修改', '接收命令并执行动作，不参与识别与决策'],
    ['ESP32 开发板、杜邦线、热点', '外购通用器件', '只负责供电、连线和组网'],
], [4.2, 3.4, 7.4], '自研与外购部分的边界')
at.p('我们把机器人拆开核对了内部结构（图%d）：' % (FIG[0] + 1) + '主控板上是带屏蔽罩和板载天线的 ESP32-S3 模组，板边有电源开关、USB Type-C 和多路 JST 接插件；'
     '机身内是锂电池和带金属齿轮箱的减速电机（驱动履带）；眼部组件经三线连接线接到主控板。外壳与传动件为 3D 打印件。'
     '这与开机日志给出的组成一致。', count=False)
at.fig('robot_teardown.png', 'WALL-E 机器人拆解照片（标注为照片中可见的部件）', 15.5)

h = find('2.3.1 软件整体介绍')
at = At(h._p)
set_text(h, '2.3.1 软件整体介绍')
h.runs[0].bold = True
at.p('软件分为三部分：', count=False)
at.items(['FPGA 逻辑（Verilog-2001，TD 6.2.1 综合与布局布线）：ISP、识别、YOLO、运动检测、延迟测量、OSD、串口报告等，全部在同一位流中；',
          'ESP32 固件（Arduino-ESP32 3.3）：解析 FPGA 报告，按规则生成机器人命令，经 Wi-Fi WebSocket 发送，并驱动本地状态终端；',
          'PC 端开发工具（Python）：参考模型与测试向量、YOLO 训练与量化导出、CAPTURE 数据采集与自动标注、串口记录与稳定性统计、BitWriter 下载脚本。电脑只在开发和测试时使用，演示时不需要。'])
at.fig('control_arch.png', '外部控制系统结构与控制规则', 15.5)

h = find('2.3.2 软件各模块介绍')
at = At(h._p)
set_text(h, '2.3.2 软件各模块介绍')
h.runs[0].bold = True
at.table(['模块', '主要输入', '主要输出', '功能'], [
    ['isp_color', '去马赛克 RGB（4 像素 / 拍）', '校正后 RGB、增益读回', '黑电平扣除、镜头阴影校正（21×13 节点插值）、闭环白平衡 / 数字曝光（近中性像素统计）'],
    ['contest_vision_v2', '读出流 RGB、x/y、按键、拨码', '叠加后 RGB、识别结果、串口报告', '三色分割、去噪、外接框、形状分类、跟踪、越线计数、8 种视图'],
    ['yolo_top', '读出流 RGB、vsync、按键', '检测框（≤8）、状态、UART', '取样、34 层描述符推理、解码与 NMS、页面切换、CAPTURE 导出'],
    ['motion_det', '读出流 Y', '运动位图、单元数、外接框', '32×18 单元帧差（1 块 ERAM 存上一帧）'],
    ['ts_stamp / lat_meter', '微秒时间（格雷码）', '延迟、帧数、窗口最大值', '帧首写时间戳，读出时计算采集→显示延迟'],
    ['he_eq', '读出流 Y', '均衡后 RGB、直方图小图', '256 级直方图、消隐期生成映射、只均衡亮度'],
    ['wb_ctrl / wb_osd', '按键、测量窗', '手动增益、白平衡页文字', '自动 / 手动 / 一键白平衡'],
    ['top_osd', '前级视频、延迟、运动结果', '最终 RGB', '每页安路 Logo（α 混合）、延迟读数、运动格'],
    ['ESP32 固件', 'UART2 报告行', 'WebSocket 命令', '报告解析（传统 / YOLO）、规则、动作队列、重连、查找机器人'],
], [2.8, 3.4, 3.4, 5.4], 'FPGA 与 ESP32 主要模块')
at.sub('（1）自研 ISP')
at.p('每帧统计近中性像素（|R−G|、|B−G| ≤ G/2）的 ΣR、ΣG、ΣB 与像素数 n，帧尾用顺序除法器求下一帧增益 er_c = g_c × (110 × n) / Σc，'
     '同时完成白平衡与数字曝光；最大估计超过 8.0 时三路等比例缩小，新增益取 (g + est + 1) / 2 以防振荡；近中性像素不足 1% 时保持增益。'
     '镜头阴影校正表由白纸平场的 4 次二维多项式拟合生成（21×13 节点，Q2.10），运行时双线性插值后与增益相乘，每通道每拍一次乘法 [3][5][6]。', count=False)
at.fig('awb_loop.png', '闭环自动白平衡与数字曝光原理', 15.5)
at.sub('（2）颜色分割、形状分类与越线计数')
at.p('红、绿、蓝各有一个分割模块，电路相同，只是输入通道的顺序不同。固定阈值模式按通道下限判断；自适应模式（KEY2 短按切换）以红色为例，'
     '要求 8R ≥ 13G 且 8R ≥ 13B，即 G、B 都不超过 R 的 61.5%，同时 R ≥ 32 + 平均亮度/2，下限随上一帧的平均亮度变化。'
     '仿真中把画面亮度压到 30% 时，固定阈值三个目标都找不到，自适应模式三个都能找到。', count=False)
at.p('命中像素先按行去噪：一行里连续不足 5 个像素的段被删掉，单个噪点和细线不会进入统计，代价是三角形尖端会被削掉几行。'
     '之后每帧求外接框、面积和中心，按填充率（面积 / 外接框面积）分类：≥ 0.875 为矩形；0.69～0.875 为圆，宽高比超出 3/4～4/3 时为椭圆；'
     '0.375～0.625 为三角形；其余记为 OBJ。画面四边 4 个像素以内的命中直接丢掉，用来避开帧缓存读出最上面两行的偏色伪像（见第三部分表“调试中遇到的主要问题”）。', count=False)
at.p('越线计数把目标中心相对计数线分成左、右和 ±12 像素的死区，连续两帧确认到了另一侧才计一次；在死区里来回抖动不计数，'
     '目标丢失超过 5 帧后再出现只重新记录它在哪一侧。每计一次，蜂鸣器响约 0.15 s，数码管左四位加一。', count=False)
at.p('跟踪器每种颜色一个，只决定屏幕上画什么框：每条边的变化不超过 2 像素时框不动，用来压住抖动；变化较大时框向测量值移动一半；'
     '任何一条边变化超过 24 像素就直接跳到测量值。目标被挡住后的 15 帧（约 0.25 s）内画虚线框并显示 HOLD，超过这个时间才判为 LOST。'
     '越线计数和串口报告用的是原始测量值，所以保持中的虚线框不会造成多计数。', count=False)
at.sub('（3）风格化视图与直方图均衡')
at.p('边缘用 Sobel 算子求梯度，阈值为 20 + 平均亮度/2，暗场景下阈值跟着降低。素描视图是明暗纸面加黑色边缘；卡通视图把颜色量化成 8 级色阶做区域填充，再叠加黑边；'
     'EDGE+ 在半亮的原图上画绿色边缘；THERMAL 把亮度映射成蓝、青、绿、黄、红的伪彩色（只表示亮度，不是温度）。视图切换请求在帧边界才提交，切换时画面不会撕裂。', count=False)
at.p('直方图均衡统计 x、y 都为偶数的像素（每帧 230,400 个）的亮度，在场消隐期间逐级累加出 CDF，生成 256 级映射表 lut，下一帧每个通道都加上同一个增量 lut[Y] − Y。'
     '这样只拉伸亮度，颜色差保持不变。直方图和映射表放在 LUT 分布式 RAM 里，因为做这一页时 ERAM 只剩 1 块。', count=False)
at.sub('（4）片上 YOLO')
at.p('网络由 YOLOv3-tiny [1] 裁剪而来：13 个卷积层、两个检测头（stride 32 / 16，各 3 个 anchor × 3 类），31,496 个参数；'
     '输入为 1280×720 经 10×10 平均得到的 128×72（上下各补 12 行），int8 逐通道对称量化、整数乘移位重标定 [2]。'
     '卷积核 8 lane 并行，由 34 条层描述符驱动，激活存于 4 个片上 RAM bank；解码用 sigmoid / exp 查表，阈值 0.70，NMS 后最多 8 个框。', count=False)
at.fig('yolo_flow.png', '片上 YOLO 调度流程', 15.5)
at.sub('（5）延迟测量与运动检测')
at.p('50 MHz 晶振驱动 20 位微秒计数器，以格雷码分别同步到摄像头域和显示域；ISP 输出每帧第一个字时写入时间与帧号，'
     '显示端读出第 0 行时取回并与当前时间相减，得到“ISP 输出 → HDMI 读出”的延迟。运动检测把画面分为 32×18 个 40×40 单元，'
     '每单元用 10×10 采样点求均值，与上一帧相差 ≥ 6 即判为运动。', count=False)
at.fig('latency_probe.png', '采集→显示延迟测量原理', 15.5)
at.sub('（6）ESP32 桥接固件')
at.p('主循环逐行读取 FPGA 报告：传统报告给出每种颜色的形状、中心 X、面积和越线计数；YOLO 报告（每 200 ms 一份，“Y n 帧号 延迟”加 n 行框）'
     '取每类得分最高的框，换算成同样的结构。规则模块选出主导颜色（新颜色需 1.5 倍面积且连续 2 份报告），判断左/中/右（回差加连续 2 份报告防抖），'
     '检测越线与消失，生成动作命令；动作一次只发一条，等机器人回复“完成”再发下一条 [8]。', count=False)
at.p('连接机器人时，ESP32 先试配置的地址，再试上次连上的地址（存在 NVS 里），然后用 mDNS 查询，最后对所在 /24 网段做并行扫描（每批 8 个地址，每个等 250 ms）。'
     '连上后每 1.5 s 发一次心跳，6 s 收不到回应就断开重连，OLED 显示 ROBOT LOST。', count=False)
at.fig('esp32_flow.png', 'ESP32 桥接固件流程', 15.5)
at.sub('（7）验证方法')
at.p('每个自研模块都有独立的参考模型（Python 或写在测试台里），测试台逐位、逐像素比较输出，tb_custom 下共有 39 个测试台；YOLO 的五个算子另有 Python 生成的测试向量。'
     '测试通过还不够，测试台本身也可能漏查，所以我们又做了变异测试 [7]：自动把 RTL 改坏一处，例如把 ≥ 改成 >、对调两个信号、去掉一个饱和保护，再看测试台能不能发现。'
     '发现不了的变异体，要么补测试，要么论证它与原电路等价。', count=False)
at.table(['模块', '发现 / 变异体总数', '说明'], [
    ['YOLO 卷积 / 辅助 / 网络 / 解码 / 画框', '43/43、50/50、54/54、66/66、35/35', '网络组含 1 个论证等价的变异体'],
    ['目标跟踪 + 帧边界提交', '40/41', '1 个论证等价（保持状态下的年龄饱和保护）'],
    ['ISP（isp_color）', '34/34；近中性门限 9/9', '补测增益下限生效的两帧后全部发现'],
    ['延迟测量 / 运动检测 / 最终叠加', '18/18、17/20、19/19', '运动检测剩下 3 个为等价变异体'],
    ['直方图均衡', '21/21', '包括精简面积时发现的 7 位回绕错误'],
    ['白平衡 awb / ctrl / osd', '15/15、32/32、23/23', '白平衡调节页'],
], [4.6, 4.6, 5.8], '变异测试结果')
at.p('变异测试确实找出过测试缺口。延迟测量第一轮漏了 3 个变异体（像素 3 损坏、窗口最后一帧为最大值、微秒计数速率），补测后都能发现；'
     '最终叠加模块漏掉了“MAX 两位数字对调”，原因是测试值 33.4 的前两位相同，换成 28.4 并加上白点位置校验后才抓到。', count=False)

# ================================================================== part 3
p3 = find('第三部分')
page_break_before(p3)
remove(find('阐述最终实现的成果'))
h = find('整体介绍（整个系统实物')
set_text(h, '整体介绍')
at = At(h._p)
at.p('最终系统由 HX1P35A 开发板（含 SC500CS 摄像头）、HDMI 显示器、ESP32 与 WALL-E 机器人组成。开发板从 Flash 启动，'
     '按键切换 7 个页面；ESP32 与机器人通过手机或电脑热点组成局域网，演示时不需要电脑运行任何程序。', count=False)
at.fig('system_photo.png', '系统实物全景（显示器为 YOLO 页；电脑仅给 ESP32 供电并记录日志）', 12.0)
at.fig('targets.jpg', '识别目标：蓝色泡沫块、红色收纳盒、绿色镂空铁框', 10.0)

h = find('工程成果（分硬件实物')
set_text(h, '工程成果')
h = find('3.2.1 机械成果')
set_text(h, '3.2.1 机械成果')
h.runs[0].bold = True
at = At(h._p)
at.p('本作品无专门机械结构，执行设备为成品 WALL-E 机器人。', count=False)
at.fig('walle.jpg', 'WALL-E 机器人（ESP32-S3，局域网控制）', 6.5)
h = find('3.2.2 电路成果')
set_text(h, '3.2.2 电路成果')
h.runs[0].bold = True
at = At(h._p)
at.fig_pair('j1_wiring.jpg', 'FPGA 侧：J1 第 1 脚（信号）与第 30 脚（地）', 'esp32_photo.jpg', 'ESP32 侧：D16（RX2）与 GND', 'FPGA 与 ESP32 的实际接线')
at.fig_pair('board_closeup.jpg', 'HX1P35A 开发板与 SC500CS 摄像头', 'esp32_terminal.jpg', 'ESP32 本地状态终端：OLED 显示 ROBOT OK、事件与命令', '开发板与 ESP32 本地终端实物')
h = find('3.2.3 软件成果')
set_text(h, '3.2.3 软件成果')
h.runs[0].bold = True
at = At(h._p)
at.p('以下均为 Flash 版本在 HDMI 显示器上的实拍画面。每页左上角为安路 Logo，右上角为延迟读数，左下角为当前页面与状态。', count=False)
at.p('这些照片是用手机对着显示器拍的，部分照片略偏蓝，原因是显示器的白点偏冷，手机自动白平衡又没有完全纠正。'
     '为了确认 FPGA 输出本身没有偏色，我们在 CAPTURE 页把板上实际送去显示的数据传回电脑，对着白纸测得 R/G/B 均值为 112/113/113。', count=False)
at.fig_grid([('view_recog.jpg', '识别面板：颜色、形状、坐标、面积、越线数'), ('view_gray.jpg', '灰度 GRAY'),
             ('view_mask.jpg', '二值化掩膜 MASK（只显示检出的红绿蓝）'), ('view_tint.jpg', '目标着色 TINT（红、绿两个目标）')],
            'CV 页分析视图（SW2 / SW3 切换）')
at.fig_grid([('view_sketch.jpg', '素描 SKETCH'), ('view_cartoon.jpg', '卡通 CARTOON'),
             ('view_edge.jpg', '边缘叠加 EDGE+'), ('view_thermal.jpg', '亮度伪彩色 THERMAL')],
            '风格化视图（KEY2 长按进入）')
at.fig_grid([('page_yolo.jpg', 'YOLO 页：类别 + 置信度标签，状态行 31FPS 27MS N=2'), ('page_cv_yolo.jpg', 'CV+YOLO 页：两种检测同时显示'),
             ('motion_page.jpg', 'MOTION 页：运动格、外接框、计数'), ('page_histeq.jpg', 'HIST EQ 页：左下角直方图与映射曲线')],
            '神经网络与进阶功能页面（KEY3+KEY4 切换）')

h = find('特性成果（逐个展示')
set_text(h, '特性成果')
at = At(h._p)
at.sub('（1）赛题要求完成情况')
at.table(['赛题要求', '本作品的实现（均已在实物上验证）'], [
    ['基础1 MIPI 采集 + HDMI 实时显示', 'SC500CS → 自研 ISP → DDR2 帧缓存 → FPGA 内 HDMI 发送，1280×720@60'],
    ['基础2 FPGA 图像处理算法', '三色分割与自适应阈值、灰度、二值化掩膜、Sobel 边缘、ISP、直方图均衡'],
    ['基础3 稳定输出', '全流水线不阻塞视频；冷启动后 30 分钟连续运行无中断'],
    ['基础4 OSD + 安路 Logo', '每个页面都有安路 Logo、中英文状态、目标框、坐标与延迟读数'],
    ['扩展1 风格化 / 视觉增强', '素描、卡通（色阶量化区域填充 + 黑边）、边缘叠加、伪彩色等 8 种视图'],
    ['扩展2 检测识别 + 文字说明', '三色定位、形状分类、坐标与计数面板；YOLO 框与“类别 + 置信度”标签'],
    ['扩展3 应用场景 + 外部控制', 'FPGA → ESP32 → Wi-Fi → WALL-E 机器人，传统识别与 YOLO 均可驱动'],
    ['扩展4 性能优化', '单像素时钟流水线；面积优化后 Slice 99.58% 时序收敛；片上测量帧率与延迟'],
    ['扩展5 自主创意', '片上 ISP 与阴影标定、片上 int8 YOLO 与板上数据采集、机器人联动'],
    ['高阶1 多算法切换 + 状态显示', 'KEY3+KEY4 切换 7 个页面，切换在帧边界生效，屏幕显示当前模式'],
    ['高阶2 动态跟踪 + 坐标叠加', '每色目标跟踪：抖动死区、遮挡保持（虚线框）、丢失提示、中心坐标'],
    ['高阶3 处理延迟可视化', '帧缓存时间戳，右上角实时显示延迟与 64 帧最大值'],
    ['高阶4 硬件运动目标检测', '32×18 单元帧差，运动格染红、黄色外接框、运动单元数'],
    ['高阶5 自动曝光 / 白平衡等优化', '近中性像素闭环白平衡、数字自动曝光、直方图均衡'],
    ['规则：固化 Flash、单一镜像', 'advy03 位流写入配置 Flash，断电冷启动通过'],
], [4.6, 10.4], '赛题要求与完成情况')
at.sub('（2）资源与时序')
at.table(['资源', '使用 / 总量', '占用率'], [
    ['Slice', '21127 / 21216', '99.58%'], ['LUT6', '20394 / 21216', '96.13%'], ['寄存器', '20411 / 42432', '48.10%'],
    ['ERAM（20 Kbit）', '107 / 108', '99.07%'], ['DSP', '37 / 40', '92.50%'],
], [4.0, 5.0, 3.0], '最终版（advy03）资源占用')
at.p('TD 6.2.1 完整构建：建立时间裕量 +0.144 ns，保持时间裕量 +0.020 ns，0 违例端点。', count=False)
at.sub('（3）实时性与稳定性')
at.table(['项目', '结果'], [
    ['摄像头 / 显示帧率', '59～60 / 60～61 帧/秒（片上 50 MHz 晶振时基）'],
    ['采集→显示延迟', '屏幕读数约 35 ms（2 帧），64 帧窗口最大约 51 ms'],
    ['YOLO', '每两帧一次检测，取样到出框 27 ms（串口报告实测）'],
    ['30 分钟连续运行（Flash 冷启动，YOLO 后台持续推理）', '8569 行报文（4.76 行/秒），0 秒中断，串口 0 次重连；摄像头均值 59.52、显示均值 60.61'],
], [5.2, 9.8], '实时性与稳定性')
at.sub('（4）画质')
at.fig('flatfield_before_after.png', '白纸平场校正前后（数值为相对中心的比值）：四角 R/G 1.21→1.02，亮度 0.70→0.95', 15.5)
at.table(['场景', '改进前', '改进后（近中性像素统计）'], [
    ['大片蓝板', 'R6.88 G2.32 B0.77，旁边中性区被染成橙红', '增益保持 R4.58 G2.51 B4.28，蓝板仍为蓝色'],
    ['对着灯', 'R3.62 G1.89 B3.42，暗处偏蓝', 'R3.45 G1.90 B3.26，灯为白色'],
    ['普通场景', '未单独记录', '测量窗 R126 G126 B127'],
], [3.0, 6.0, 6.0], '白平衡改进前后（WB 页实测读数）')
at.fig_pair('wb_adv02_blueboard.jpg', '改进前：大片蓝板把 B 增益压到 0.77，旁边被染成橙红', 'wb_adv03_blueboard.jpg', '改进后：增益保持不变', '大面积彩色场景的白平衡对比（WB 页）')
at.sub('（5）片上 YOLO 精度')
at.p('训练数据由 CAPTURE 页采集：板子把网络的真实输入（128×72）经串口发到 PC，手持三种目标在镜头前摆放，共 7 组；'
     '自动标注（与空画面的差得到剪影，再用颜色种子判别类别）后逐帧复核，剔除错标帧。'
     '训练集 540 帧（另加 45 帧反例：头、手、房间，权重 ×3），验证用摄像头被转动后单独采集的一组（91 帧、150 个框）。精度均按与 FPGA 逐位一致的 int8 运算统计 [15]：', count=False)
at.fig('yolo_dataset.png', '实拍训练数据样例与标注', 13.5)
at.table(['模型', '训练数据', 'int8 mAP50（红 / 绿 / 蓝）', '阈值 0.70 时 精确率 / 召回率'], [
    ['原模型', '只用合成图', '0.037（0.07 / 0.00 / 0.04）', '实拍基本检测不到'],
    ['实拍微调', '实拍 540 帧', '0.836（0.96 / 0.63 / 0.92）', '0.94 / 0.77'],
    ['实拍 + 反例（最终）', '实拍 540 帧 + 反例 45 帧', '0.844（0.999 / 0.62 / 0.92）', '0.92 / 0.80'],
], [3.0, 3.6, 4.6, 3.8], 'YOLO 精度（实拍验证集，int8）')
at.p('上板实测：三种目标都能识别；头、手和颜色相近的瓶子不再出框。绿色铁框是镂空结构，逆光下只剩几条稀疏的暗线，是三类里最难的，召回率也最低。'
     '需要说明，验证集同时用来挑选训练轮次，所以上表的数字会略偏乐观；我们没有在另一个环境另外采集独立测试集，这是一个不足。'
     '10 月 31 日晚拍摄演示视频时，三类目标都能稳定出框。', count=False)
at.sub('（6）外部控制')
at.table(['测试', '结果'], [
    ['传统识别驱动（CV 页，ESP32，不接电脑）', '红：眼红 + 挥手；绿：眼绿 + 点头；蓝：眼蓝 + 闪烁 + 双臂举起 1.8 s；左 / 右：举左 / 右臂；越线：眼灯闪烁；消失：恢复平静'],
    ['YOLO 驱动（YOLO 页）', '同上动作（无越线事件）；加入侧向防抖后，目标真正移到一侧才举一次手'],
    ['移动规则（电脑桥接时实测）', '绿行并左右转向、红停、蓝退，定时移动 0.5～0.7 s'],
    ['网络', '机器人 IP 变化时，ESP32 依次尝试上次 IP、mDNS、网段扫描，自动重连'],
    ['本地状态终端', 'OLED 正确显示连接状态、YOLO 来源、三色位置与面积、事件和命令；三色灯随目标颜色点亮（2026-10-31 实测）'],
], [5.0, 10.0], '机器人联动测试')
at.sub('（7）调试中遇到的主要问题')
at.p('下表按时间顺序列出上板过程中比较典型的问题。多数问题在仿真里看不到，我们的做法是先记录现象和位流哈希，用诊断页面或串口取数据，确认原因后再改。', count=False)
at.table(['现象', '原因', '处理'], [
    ['画面中心偏绿、四周偏红', '镜头颜色阴影与黑电平（白纸平场、暗场实测）', '黑电平扣除 + 21×13 节点阴影校正'],
    ['暗场景整片发绿', '白平衡增益逐通道截到 4.0，三路都被截住后白平衡失效', '超限时三路等比例缩小'],
    ['大片蓝板把旁边的中性区染成橙红', '灰度世界统计被大面积彩色带偏', '只统计近中性像素，不足 1% 时保持增益'],
    ['画面里没有目标时面板仍报红色目标，Y 常为 0', '帧缓存读出最上面两行有整行偏色', '丢掉距边缘 4 像素以内的命中'],
    ['画面只剩一个颜色通道（纯蓝）', '摄像头排线弯折，一条 MIPI lane 接触不良', '断电重插排线并固定'],
    ['下载和串口频繁断开', '开发板 USB 接在扩展坞上', '改为直接接电脑'],
    ['JTAG 下载后 YOLO 帧号一直为 0', '原因没有查明，重新下载后未再出现', '加 DIAG 参数，可在报告里输出推理阶段和层号'],
    ['加入诊断输出后构建失败', 'Slice 21285 超过 21216', '精简诊断字段；用计数器代替比较、Logo ROM 只留一份等方法回收面积'],
    ['YOLO 把头和手认成目标', '训练集里没有这类反例', '补拍 45 帧反例（权重 ×3）重新训练，阈值定为 0.70'],
    ['YOLO 驱动时机器人左右手来回举', '框中心在左右分界附近抖动', '左右判断加回差，并要求连续 2 份报告一致'],
    ['ESP32 接上舵机后反复重启', 'USB 供电下舵机启动电流过大，ESP32 欠压', '延迟启动、降低 Wi-Fi 发射功率，最后去掉舵机'],
    ['机器人重启后 ESP32 连不上', '机器人重新入网后 IP 可能改变', '依次尝试上次地址、mDNS 和网段并行扫描'],
], [4.6, 5.2, 5.2], '调试中遇到的主要问题')

# ================================================================== part 4
p4 = find('第四部分')
page_break_before(p4)
at, hint = hint_after('可扩展之处', '4.1 可扩展之处', 300)
at.items(['在传感器侧做自动曝光和模拟增益闭环。现在暗场景靠数字增益提亮，噪声比较明显；',
          '更大的检测网络和更多类别：权重改为从 DDR 分块读入（需要先加 DDR 读写仲裁），同时补充不同光照、背景下的数据，并单独采集测试集；',
          '以太网上位机，远程修改参数，查看识别结果和帧率；',
          '同色多目标分离与 ID 关联。现在同一颜色的多个物体会被合成一个框；',
          '把执行端换成小车或机械臂，真正去做分拣。'])
remove(hint)

at, hint = hint_after('心得体会', '4.2 心得体会', 1000)
at.p('回头看，最花时间的不是写 RTL，而是弄清楚问题到底出在哪。早期画面中心偏绿、四周偏红，我们照着照片调全局增益调了好几轮，越调越乱。'
     '后来干脆做了一个片上诊断模块，拍白纸平场和暗场，数据一出来才看清是镜头颜色阴影和黑电平两件事叠在一起，分别处理后一次就好了。'
     '之后白平衡被大片蓝板带偏、暗场景整片发绿，我们都是先看 WB 页的读数再动手，少走了不少弯路。')
at.p('仿真我们做得比较细，每个模块都有参考模型和逐位比对，还用变异测试去找测试台的漏洞，确实找出过几处测试缺口和一个回绕错误。'
     '可上板照样会碰到仿真里看不到的事：排线一弯，画面只剩一个颜色；USB 接在扩展坞上，下载和串口就频繁断开；'
     '还有一次 JTAG 下载后检测网络没有启动，重新下载就好了，原因到现在也没查明，只能留下诊断参数备用。'
     '后来我们养成了习惯，每次构建都记下时序、资源、位流哈希和上板结果，出问题时能很快对上是哪个版本。')
at.p('神经网络这部分印象最深。只用合成图训练的模型在 FPGA 上跑得完全正确，和参考模型逐位一致，可对着真实物体 mAP50 只有 0.04。'
     '改用 CAPTURE 页采集网络真正看到的 128×72 输入，标注、复核、微调之后到了 0.84；上板又发现头和手会出框，补拍 45 帧反例才压下去。'
     '绿色铁框是镂空的，逆光时只剩几条暗线，到最后也是三类里最弱的，这一点我们并不满意。')
at.p('资源一直卡得很紧。所有功能放进同一个位流后，Slice 到了 99.58%，有一次只是多加 10 个字节的诊断输出，就超出了 69 个 Slice。'
     '回收面积靠的都是些不起眼的改法：删掉调试模块、Logo ROM 只留一份、用计数器代替比较、用移位代替乘法。每改一处，我们都重新跑逐像素测试，确认输出没变。')
at.p('演示方式也改过一次。赛题要求作品固化、上电即运行，群里也不推荐让电脑参与演示，所以机器人联动从电脑桥接改成了 ESP32 桥接，'
     '后来又给 ESP32 加了 OLED 和三色灯。机器人没反应时，先看 OLED 就知道是没收到报告、没识别到目标，还是机器人掉线了，现场排查快了很多。')
remove(hint)

# ================================================================== part 5
p5 = find('第五部分')
at, hint = hint_after('第五部分')
refs = [
    'Redmon J, Farhadi A. YOLOv3: An Incremental Improvement[J]. arXiv preprint arXiv:1804.02767, 2018.',
    'Jacob B, Kligys S, Chen B, et al. Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference[C]//Proceedings of the IEEE Conference on Computer Vision and Pattern Recognition. 2018: 2704-2713.',
    'Buchsbaum G. A Spatial Processor Model for Object Colour Perception[J]. Journal of the Franklin Institute, 1980, 310(1): 1-26.',
    'Gonzalez R C, Woods R E. Digital Image Processing[M]. 4th ed. New York: Pearson, 2018.',
    'Yu W. Practical Anti-vignetting Methods for Digital Cameras[J]. IEEE Transactions on Consumer Electronics, 2004, 50(4): 975-983.',
    'Ramanath R, Snyder W E, Yoo Y, et al. Color Image Processing Pipeline[J]. IEEE Signal Processing Magazine, 2005, 22(1): 34-43.',
    'DeMillo R A, Lipton R J, Sayward F G. Hints on Test Data Selection: Help for the Practicing Programmer[J]. Computer, 1978, 11(4): 34-41.',
    'Fette I, Melnikov A. The WebSocket Protocol: RFC 6455[S]. Internet Engineering Task Force, 2011.',
    'Ioffe S, Szegedy C. Batch Normalization: Accelerating Deep Network Training by Reducing Internal Covariate Shift[C]//Proceedings of the 32nd International Conference on Machine Learning. 2015: 448-456.',
    'MIPI Alliance. MIPI Camera Serial Interface 2 (CSI-2) Specification[S].',
    'HDMI Licensing, LLC. High-Definition Multimedia Interface Specification Version 1.4[S]. 2009.',
    '上海安路信息科技股份有限公司. 2026 全国大学生嵌入式芯片与系统设计竞赛 FPGA 创新设计赛道选题指南[Z]. 2026.',
    '康芯科技. HX1P35A 开发板使用手册（HDL 版）[Z]. 2026.',
    'Espressif Systems. ESP32 Series Datasheet[Z].',
    'Everingham M, Van Gool L, Williams C K I, et al. The PASCAL Visual Object Classes (VOC) Challenge[J]. International Journal of Computer Vision, 2010, 88(2): 303-338.',
]
for i, r in enumerate(refs, 1):
    at.p('[%d] %s' % (i, r), 10.5, indent=False)
remove(hint)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
D.save(OUT)
print('wrote', OUT)
print('figures %d, tables %d' % (FIG[0], TAB[0]))
for k, (lim, n) in COUNT.items():
    print('%-16s %4d / %4d %s' % (k, n, lim or 0, 'OVER' if lim and n > lim else ''))
