#!/usr/bin/env python3
"""assemble_video.py - title cards + captioned demo + END -> the contest video (MP4, H.264, 1080p30, silent AAC track, < 3 min, < 300 MB)

    F:/yolo_env/Scripts/python.exe tools/report/make_video_cards.py
    F:/yolo_env/Scripts/python.exe tools/report/screen_wb.py <phone video> F:/fpga_submit/video/demo_screenwb.mp4
    F:/yolo_env/Scripts/python.exe tools/report/assemble_video.py   ->  F:/fpga_submit/video/作品演示视频_最终版.mp4
"""
import subprocess
import sys

FF = 'E:/Ultimate Vocal Remover/ffmpeg.exe'
CARDS = 'F:/fpga_submit/video/cards'
DEMO = 'F:/fpga_submit/video/demo_screenwb.mp4'
OUT = sys.argv[1] if len(sys.argv) > 1 else 'F:/fpga_submit/video/作品演示视频_最终版.mp4'
INTRO = [('c0_title', 4.0), ('c1_block', 5.5), ('c2_photo', 5.5), ('c3_robot', 5.5), ('c4_demo', 2.0)]
END = ('c5_end', 3.0)
caps = [tuple(map(float, l.split())) for l in open(f'{CARDS}/captions.txt') if l.strip()]
LAYOUT = open(f'{CARDS}/layout.txt').read().strip()                  # written by make_video_cards.py: overlay | side

args = [FF, '-hide_banner', '-loglevel', 'error', '-y']
for name, t in INTRO + [END]:
    args += ['-loop', '1', '-framerate', '30', '-t', str(t), '-i', f'{CARDS}/{name}.png']
args += ['-i', DEMO]
for i in range(len(caps)):
    args += ['-loop', '1', '-framerate', '30', '-i', f'{CARDS}/cap_{i:02d}.png']
n_cards = len(INTRO) + 1
demo_in = n_cards
fc = []
for k, (name, t) in enumerate(INTRO + [END]):
    fc.append(f'[{k}:v]scale=1920:1080,format=yuv420p,fps=30,fade=t=in:st=0:d=0.4,fade=t=out:st={t - 0.4:.2f}:d=0.4[v{k}]')
last = f'[{demo_in}:v]'
if LAYOUT == 'side':                                                    # video at 80 % top left; the caption PNGs fill the right column and the bottom strip
    fc.append(f'{last}scale=1536:864:flags=lanczos,pad=1920:1080:0:0:color=0x1C1E22[base]')
    last = '[base]'
for i, (a, b) in enumerate(caps):
    nxt = f'[d{i}]'
    fc.append(f"{last}[{demo_in + 1 + i}:v]overlay=0:0:shortest=1:enable='between(t,{a},{min(b, 9999)})'{nxt}")
    last = nxt
fc.append(f'{last}format=yuv420p,fps=30[demo]')
order = ''.join(f'[v{k}]' for k in range(len(INTRO))) + '[demo]' + f'[v{len(INTRO)}]'
fc.append(f'{order}concat=n={len(INTRO) + 2}:v=1:a=0[outv]')
args += ['-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000']
args += ['-filter_complex', ';'.join(fc), '-map', '[outv]', '-map', f'{demo_in + 1 + len(caps)}:a', '-shortest',
         '-c:v', 'libx264', '-preset', 'medium', '-crf', '21', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
         '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv',
         '-c:a', 'aac', '-b:a', '64k', '-movflags', '+faststart', OUT]
subprocess.run(args, check=True)
print('wrote', OUT)
