#!/usr/bin/env python3
"""pdf_fullres.py - put the full-resolution pictures back into the report PDF

Word lays the report out well but downsamples every picture to 200 dpi (and re-compresses it) when it exports the PDF; that setting is a global
Word option, not part of the document. This script keeps Word's PDF and swaps each downsampled picture for the original file in docs/report/img,
so the layout does not change. A PDF picture is matched to the source with the same aspect ratio and the closest 48 x 48 thumbnail; pictures with
no good match (the template's header logo) are left alone.

    python tools/report/pdf_fullres.py [docs/report/作品报告_官方模板.pdf]
"""
import io
import os
import re
import sys

import numpy as np
import pymupdf
from PIL import Image

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
IMG = os.path.join(ROOT, 'docs', 'report', 'img')
PDF = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'docs', 'report', '作品报告_官方模板.pdf')
USED = sorted(set(re.findall(r"'(\w+\.(?:png|jpg))'", open(os.path.join(ROOT, 'tools', 'report', 'make_report_official.py'), encoding='utf-8').read())))


def sig(im):
    g = np.asarray(im.convert('L').resize((48, 48), Image.BILINEAR)).astype(np.float32)
    return (g - g.mean()) / (g.std() + 1e-3)


src = {}
for n in USED:
    p = os.path.join(IMG, n)
    if os.path.exists(p):
        im = Image.open(p).convert('RGB')
        src[n] = (im.width / im.height, sig(im), im.width)

doc = pymupdf.open(PDF)
done, kept = {}, []
for page in doc:
    for x in page.get_images(full=True):
        xref = x[0]
        if xref in done:
            continue
        pix = pymupdf.Pixmap(doc, xref)
        if pix.n - pix.alpha >= 3 and pix.colorspace and pix.colorspace.n != 3:
            pix = pymupdf.Pixmap(pymupdf.csRGB, pix)
        im = Image.open(io.BytesIO(pix.tobytes('png'))).convert('RGB')
        ar, s = im.width / im.height, sig(im)
        best = min(((float(((s - v[1]) ** 2).mean()), n) for n, v in src.items() if abs(v[0] / ar - 1) < 0.03), default=None)
        if best is None or best[0] > 0.15 or src[best[1]][2] <= im.width:
            done[xref] = None
            kept.append('%dx%d' % (im.width, im.height))
            continue
        page.replace_image(xref, filename=os.path.join(IMG, best[1]))
        done[xref] = best[1]
        print('p%-3d %5dx%-5d -> %-28s (%d px wide, match %.3f)' % (page.number + 1, im.width, im.height, best[1], src[best[1]][2], best[0]))
tmp = PDF + '.tmp'
doc.save(tmp, garbage=3, deflate=True)
doc.close()
os.replace(tmp, PDF)
print('replaced %d pictures, left %d alone (%s); %s %.1f MB' % (sum(v is not None for v in done.values()), len(kept), ', '.join(sorted(set(kept))),
                                                                   PDF, os.path.getsize(PDF) / 1e6))
