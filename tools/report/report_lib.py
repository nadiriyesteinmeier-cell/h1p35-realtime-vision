#!/usr/bin/env python3
"""report_lib.py - Word layout helpers shared by the report scripts (A4, SimSun / SimHei, tables, figures, fields)

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


