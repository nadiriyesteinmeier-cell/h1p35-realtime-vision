#!/usr/bin/env python3
"""make_figures.py - data figures for the contest report (matplotlib in F:/yolo_env)

    F:/yolo_env/Scripts/python.exe tools/report/make_figures.py

  flatfield_before_after.png  R/G, B/G (each / its centre value) and luminance / centre on the 16 x 9 flat-field cells: raw sensor (wb02 unity gains,
                              dark frame subtracted) vs. corrected (isp02: BLC + LSC + AWB) - same colour scale left and right
  lsc_gain_map.png            the 21 x 13 lens-shading gains of the R / G / B channels (logs_custom/lsc/lsc_table.hex, Q2.10)
  yolo_training.png           box / objectness / class loss per epoch and the validation mAP50 (models/p5_synth_20261024/train_log.txt)
  resource_breakdown.png      LUT and register use of the top-level blocks of the final build (cli_adv03b *_phy.area)
"""
import os
import re
import sys

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
OUT = os.path.join(ROOT, 'docs', 'report', 'img')
sys.path.insert(0, os.path.join(ROOT, 'tools', 'shade'))
import shade_analyze as sa                                          # noqa: E402

font_manager.fontManager.addfont('C:/Windows/Fonts/msyh.ttc')
plt.rcParams['font.family'] = 'Microsoft YaHei'
plt.rcParams['axes.unicode_minus'] = False
os.makedirs(OUT, exist_ok=True)


def mean_report(path, cell_px):
    reps, bad = sa.parse_reports(open(path, encoding='utf-8', errors='replace').read())
    arrs = [sa.to_array(r, cell_px) for r in reps]
    return np.mean(arrs, axis=0), len(arrs)


def centre(a):
    gh, gw = a.shape
    m = sa.centre_mask(gh, gw)
    return a[m].mean()


# ------------------------------------------------------------------ flat field
SC = os.path.join(ROOT, 'logs_custom', 'shade_capture')
first = open(os.path.join(SC, 'wb02_white_mode1.txt'), encoding='utf-8', errors='replace').read()
hdr = [l for l in first.splitlines() if l.startswith('HDR,')][0].split(',')
cell_px = int(hdr[5], 16) * 64 if False else None
# cell size: 80 x 80 pixels (1280 / 16, 720 / 9) sampled every 4th pixel in x and y -> 400 samples per cell (shade_diag / flat_stats)
CELL = 400
raw, n_raw = mean_report(os.path.join(SC, 'wb02_white_mode1.txt'), CELL)
dark, n_dark = mean_report(os.path.join(SC, 'wb02_dark_mode1.txt'), CELL)
cor, n_cor = mean_report(os.path.join(SC, 'isp02_white_mode0.txt'), CELL)
rawb = np.maximum(raw - dark, 1e-6)


def maps(a):
    R, G, B = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    rg, bg = R / G, B / G
    lum = (77 * R + 150 * G + 29 * B) / 256.0
    return rg / centre(rg), bg / centre(bg), lum / centre(lum)


mb, mc = maps(rawb), maps(cor)
names = ['R/G（相对中心）', 'B/G（相对中心）', '亮度（相对中心）']
fig, axes = plt.subplots(2, 3, figsize=(13, 5.2))
for j in range(3):
    lo, hi = (0.70, 1.30)
    for i, (m, title) in enumerate(((mb, '校正前（原始传感器，已扣暗场）'), (mc, '校正后（BLC + LSC + AWB）'))):
        ax = axes[i, j]
        im = ax.imshow(m[j], cmap='RdBu_r', vmin=lo, vmax=hi)
        ax.set_xticks([]); ax.set_yticks([])
        corner = np.mean([m[j][0, 0], m[j][0, -1], m[j][-1, 0], m[j][-1, -1]])
        ax.set_title('%s\n%s  四角均值 %.2f' % (title, names[j], corner), fontsize=9.5)
fig.colorbar(im, ax=axes, shrink=0.8, label='相对中心的比值')
fig.suptitle('白纸平场 16×9 格（同一色标）：镜头颜色阴影与亮度衰减的校正效果', fontsize=12)
fig.savefig(os.path.join(OUT, 'flatfield_before_after.png'), dpi=150, bbox_inches='tight')
plt.close(fig)
print('flatfield: raw %d / dark %d / corrected %d reports' % (n_raw, n_dark, n_cor))
for j in range(3):
    cb = np.mean([mb[j][0, 0], mb[j][0, -1], mb[j][-1, 0], mb[j][-1, -1]])
    cc = np.mean([mc[j][0, 0], mc[j][0, -1], mc[j][-1, 0], mc[j][-1, -1]])
    print('  %s corners: before %.3f after %.3f' % (['R/G', 'B/G', 'lum'][j], cb, cc))

# ------------------------------------------------------------------ LSC gains
vals = [int(l.strip(), 16) for l in open(os.path.join(ROOT, 'logs_custom', 'lsc', 'lsc_table.hex')) if l.strip()]
NX, NY = 21, 13
g = np.array(vals[:NX * NY], dtype=np.int64)
chans = [(g >> 24) & 0xFFF, (g >> 12) & 0xFFF, g & 0xFFF]
fig, axes = plt.subplots(1, 3, figsize=(13, 3.2))
for ax, c, nm in zip(axes, chans, ('R', 'G', 'B')):
    m = (c.reshape(NY, NX) / 1024.0)
    im = ax.imshow(m, cmap='viridis', vmin=1.0, vmax=max(1.6, m.max()))
    ax.set_title('%s 通道增益 %.2f–%.2f' % (nm, m.min(), m.max()), fontsize=10)
    ax.set_xticks([]); ax.set_yticks([])
fig.colorbar(im, ax=axes, shrink=0.85, label='校正增益（中心 = 1.0）')
fig.suptitle('镜头阴影校正表：21×13 个节点（64 像素间距，Q2.10）', fontsize=12)
fig.savefig(os.path.join(OUT, 'lsc_gain_map.png'), dpi=150, bbox_inches='tight')
plt.close(fig)

# ------------------------------------------------------------------ YOLO training
ep, lb, lo_, lc, vep, vmap = [], [], [], [], [], []
for ln in open(os.path.join(ROOT, 'models', 'p5_synth_20261024', 'train_log.txt'), encoding='utf-8'):
    m = re.match(r'epoch\s+(\d+).*loss box ([\d.]+) obj ([\d.]+) cls ([\d.]+)', ln)
    if m:
        e = int(m.group(1)); ep.append(e); lb.append(float(m.group(2))); lo_.append(float(m.group(3))); lc.append(float(m.group(4)))
        v = re.search(r'mAP ([\d.]+)', ln)
        if v:
            vep.append(e); vmap.append(float(v.group(1)))
fig, ax1 = plt.subplots(figsize=(10, 4.2))
ax1.plot(ep, lb, label='框回归损失')
ax1.plot(ep, lc, label='分类损失')
ax1.set_xlabel('训练轮次（epoch）'); ax1.set_ylabel('损失（框 / 分类）')
ax1b = ax1.twinx()
ax1b.plot(ep, lo_, color='tab:gray', alpha=0.6, label='目标置信度损失（右轴，对数）')
ax1b.set_yscale('log'); ax1b.set_ylabel('置信度损失（对数）')
ax2 = ax1.twinx()
ax2.spines['right'].set_position(('outward', 55))
ax2.plot(vep, vmap, 'o-', color='tab:red', label='验证集 mAP50')
ax2.set_ylabel('验证集 mAP50', color='tab:red'); ax2.set_ylim(0, 0.7)
h = sum((a.get_legend_handles_labels()[0] for a in (ax1, ax1b, ax2)), [])
lbl = sum((a.get_legend_handles_labels()[1] for a in (ax1, ax1b, ax2)), [])
ax1.legend(h, lbl, loc='center right', fontsize=8.5)
ax1.set_title('片上 YOLO（3.1 万参数）合成数据训练过程：150 轮，RTX 4060 约 30 分钟', fontsize=11)
fig.savefig(os.path.join(OUT, 'yolo_training.png'), dpi=150, bbox_inches='tight')
plt.close(fig)
print('yolo: %d epochs, %d validation points, last mAP %.3f' % (len(ep), len(vep), vmap[-1] if vmap else -1))

# ------------------------------------------------------------------ resources per block
AREA = os.path.join(ROOT, 'contest_work_v3_adv', 'td_project', 'camera_to_dsi_display_Runs', 'cli_adv03b', 'camera_to_dsi_display_phy.area')
txt = open(AREA, encoding='utf-8', errors='replace').read()
sec = txt[txt.index('Report Hierarchy Area'):]
rows = []
for ln in sec.splitlines():
    f = ln.split('|')
    if len(f) > 8 and f[1].startswith('  u_') and not f[1].startswith('   '):
        name = f[1].strip(); lut = int(f[3] or 0) + int(f[4] or 0); seq = int(f[5] or 0)
        rows.append((name, lut, seq))
label = {'u_contest_vision_v2': '传统视觉识别', 'u_yolo': '片上 YOLO', 'u_ph1p35_324_ddr_wrapper': 'DDR 控制器（IP）', 'u_isp_top': 'ISP（去马赛克 + isp_color）',
         'u_yolo_osd': 'YOLO 叠加', 'u_hdmi_tx': 'HDMI 发送（IP）', 'u_wb_ctrl': '白平衡页控制', 'u_top_osd': 'Logo / 延迟 / 运动叠加', 'u_he': '直方图均衡',
         'u_wb_osd': '白平衡页叠加', 'u_video_out': '帧缓存读出', 'u_video_in': '帧缓存写入', 'u_lat': '延迟测量', 'u_motion': '帧差运动检测'}
rows = sorted([r for r in rows if r[0] in label], key=lambda r: -r[1])
fig, ax = plt.subplots(figsize=(10, 4.6))
y = np.arange(len(rows))
ax.barh(y - 0.2, [r[1] for r in rows], height=0.4, label='LUT（含进位链）')
ax.barh(y + 0.2, [r[2] for r in rows], height=0.4, label='寄存器')
ax.set_yticks(y); ax.set_yticklabels([label[r[0]] for r in rows], fontsize=9)
ax.invert_yaxis(); ax.set_xlabel('数量'); ax.legend(fontsize=9)
ax.set_title('最终版（adv03）主要模块资源占用（Slice 99.63%，ERAM 107/108，DSP 37/40）', fontsize=11)
fig.savefig(os.path.join(OUT, 'resource_breakdown.png'), dpi=150, bbox_inches='tight')
plt.close(fig)
for r in rows:
    print('  %-28s lut+rip %6d  seq %6d' % (r[0], r[1], r[2]))
