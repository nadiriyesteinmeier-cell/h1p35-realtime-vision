#!/usr/bin/env python3
"""train_yolo.py - train the YOLOv3-tiny-derived detector of the PH1P35 board (PyTorch), export float weights with BatchNorm folded for tools/yolo/quantize.py

The network is exactly the topology of mininet.py / quantize.float_forward / the RTL descriptor table: conv0..conv6 (3x3 + BN + leaky 13/128 + 2x2 max-pool), conv8 (3x3, route source),
pool9, conv10, conv12 (3x3), conv13 (1x1), conv14 (3x3), head1 (1x1, stride 32), conv18 (1x1) + x2 nearest upsample + concat [up, conv8], conv21 (3x3), head2 (1x1, stride 16).
Heads: 3 anchors x (tx, ty, tw, th, obj, 3 classes) = 24 channels, decoded like tools/yolo/decode_ref.py (box centre = (sigmoid(t) + cell) * stride, size = anchor * exp(t)).
Hardware contracts enforced in training: leaky slope 13/128; every head output should stay inside the int8 range of real scale 1/16 (-8 .. 7.94): a penalty on |logit| > 7.5.

Input: uint8 [96, 128, 3] images (synth.py or frames captured from the board), x = (pixel - 128) / 128.  Labels: [cls, cx, cy, w, h] in network pixels.
Usage: F:/yolo_env/Scripts/python.exe train_yolo.py --data F:/yolo_data --out F:/yolo_runs/p5_synth --epochs 60
Writes <out>/model.pt, <out>/float_folded.npz (conv0_w, conv0_b, ...), <out>/anchors.json, <out>/train_log.txt, <out>/metrics.json
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

CH = (8, 8, 16, 16, 24, 32, 24, 16, 24, 8, 16)
NCLS = 3
NA = 3
LEAKY = 13.0 / 128.0
NW, NH = 128, 96
STRIDES = (32, 16)                       # head1, head2


class ConvBN(nn.Module):
    def __init__(self, cin, cout, k):
        super().__init__()
        self.conv = nn.Conv2d(cin, cout, k, padding=k // 2, bias=False)
        self.bn = nn.BatchNorm2d(cout)

    def forward(self, x):
        return F.leaky_relu(self.bn(self.conv(x)), LEAKY)


class Net(nn.Module):
    def __init__(self, ch=CH, ncls=NCLS):
        super().__init__()
        c0, c1, c2, c3, c4, c5, c6, d1, d2, d3, d4 = ch
        head = NA * (5 + ncls)
        self.conv0, self.conv2, self.conv4, self.conv6 = ConvBN(3, c0, 3), ConvBN(c0, c1, 3), ConvBN(c1, c2, 3), ConvBN(c2, c3, 3)
        self.conv8, self.conv10, self.conv12 = ConvBN(c3, c4, 3), ConvBN(c4, c5, 3), ConvBN(c5, c6, 3)
        self.conv13, self.conv14 = ConvBN(c6, d1, 1), ConvBN(d1, d2, 3)
        self.head1 = nn.Conv2d(d2, head, 1)
        self.conv18 = ConvBN(d1, d3, 1)
        self.conv21 = ConvBN(d3 + c4, d4, 3)
        self.head2 = nn.Conv2d(d4, head, 1)

    def forward(self, x):
        x = F.max_pool2d(self.conv0(x), 2)
        x = F.max_pool2d(self.conv2(x), 2)
        x = F.max_pool2d(self.conv4(x), 2)
        x = F.max_pool2d(self.conv6(x), 2)
        c8 = self.conv8(x)
        x = F.max_pool2d(c8, 2)
        x = self.conv12(self.conv10(x))
        x13 = self.conv13(x)
        h1 = self.head1(self.conv14(x13))
        up = F.interpolate(self.conv18(x13), scale_factor=2, mode='nearest')
        h2 = self.head2(self.conv21(torch.cat([up, c8], dim=1)))
        return h1, h2


def fold(model):
    """BN folded into the convolutions: name -> (w [cout, cin, k, k], b [cout]) as numpy float64 (the layout quantize.py expects)"""
    out = {}
    for name in ('conv0', 'conv2', 'conv4', 'conv6', 'conv8', 'conv10', 'conv12', 'conv13', 'conv14', 'conv18', 'conv21'):
        m = getattr(model, name)
        w = m.conv.weight.detach().double().cpu()
        bn = m.bn
        s = bn.weight.detach().double().cpu() / torch.sqrt(bn.running_var.detach().double().cpu() + bn.eps)
        out[name] = ((w * s[:, None, None, None]).numpy(), (bn.bias.detach().double().cpu() - bn.running_mean.detach().double().cpu() * s).numpy())
    for name in ('head1', 'head2'):
        m = getattr(model, name)
        out[name] = (m.weight.detach().double().cpu().numpy(), m.bias.detach().double().cpu().numpy())
    return out


# ---------------------------------------------------------------- anchors
def kmeans_anchors(labels, k=6, iters=60, seed=0):
    wh = np.array([[l[3], l[4]] for lab in labels for l in lab], dtype=np.float64)
    rng = np.random.default_rng(seed)
    cent = wh[rng.choice(len(wh), k, replace=False)]
    for _ in range(iters):
        inter = np.minimum(wh[:, None, 0], cent[None, :, 0]) * np.minimum(wh[:, None, 1], cent[None, :, 1])
        iou = inter / (wh[:, None, 0] * wh[:, None, 1] + cent[None, :, 0] * cent[None, :, 1] - inter)
        a = iou.argmax(1)
        new = np.array([np.median(wh[a == j], axis=0) if np.any(a == j) else cent[j] for j in range(k)])
        if np.allclose(new, cent):
            break
        cent = new
    cent = cent[np.argsort(cent[:, 0] * cent[:, 1])]
    cent = np.clip(np.round(cent), 2, 255)                  # the hardware stores anchors as 8-bit network pixels
    return cent[3:].tolist(), cent[:3].tolist()             # head1 (stride 32, large), head2 (stride 16, small)


# ---------------------------------------------------------------- targets / loss
def build_targets(labels_b, anchors, device):
    """per head: obj / noobj masks, box and class targets (numpy, converted once), plus the padded ground-truth boxes of the batch for the ignore rule"""
    B = len(labels_b)
    all_anc = np.array(anchors[0] + anchors[1], dtype=np.float64)          # 6 x 2, head1 first
    outs = []
    for hi, st in enumerate(STRIDES):
        gh, gw = NH // st, NW // st
        outs.append(dict(obj=np.zeros((B, NA, gh, gw), np.float32), noobj=np.ones((B, NA, gh, gw), np.float32), txy=np.zeros((B, NA, gh, gw, 2), np.float32),
                         twh=np.zeros((B, NA, gh, gw, 2), np.float32), cls=np.zeros((B, NA, gh, gw, NCLS), np.float32), wscale=np.zeros((B, NA, gh, gw), np.float32)))
    gmax = max(1, max(len(l) for l in labels_b))
    gt = np.zeros((B, gmax, 4), np.float32)
    gm = np.zeros((B, gmax), bool)
    for b, lab in enumerate(labels_b):
        for gi, (c, cx, cy, w, h) in enumerate(lab):
            gt[b, gi] = (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
            gm[b, gi] = True
            inter = np.minimum(all_anc[:, 0], w) * np.minimum(all_anc[:, 1], h)
            iou = inter / (all_anc[:, 0] * all_anc[:, 1] + w * h - inter)
            best = int(iou.argmax())
            for j in range(6):
                hj, aj = j // NA, j % NA
                stj = STRIDES[hj]
                gx, gy = min(int(cx // stj), NW // stj - 1), min(int(cy // stj), NH // stj - 1)
                tj = outs[hj]
                if j == best:
                    tj['obj'][b, aj, gy, gx] = 1
                    tj['noobj'][b, aj, gy, gx] = 0
                    tj['txy'][b, aj, gy, gx] = (cx / stj - gx, cy / stj - gy)
                    aw, ah = anchors[hj][aj]
                    tj['twh'][b, aj, gy, gx] = (math.log(max(w, 1e-3) / aw), math.log(max(h, 1e-3) / ah))
                    tj['cls'][b, aj, gy, gx] = 0
                    tj['cls'][b, aj, gy, gx, int(c)] = 1
                    tj['wscale'][b, aj, gy, gx] = 2.0 - (w * h) / (NW * NH)
                elif iou[j] > 0.5:
                    tj['noobj'][b, aj, gy, gx] = 0            # other anchors that fit the box well are not punished as background
    res = [{k: torch.from_numpy(v).to(device) for k, v in t.items()} for t in outs]
    return res, torch.from_numpy(gt).to(device), torch.from_numpy(gm).to(device)


def reshape_head(p):
    B, C, H, W = p.shape
    return p.view(B, NA, 5 + NCLS, H, W).permute(0, 1, 3, 4, 2)          # B, A, H, W, 8


def decode_boxes(p, hi, anchors):
    """float decode of one head (same formulas as decode_ref) -> B, A, H, W, 4 boxes (x0, y0, x1, y1) in network pixels"""
    st = STRIDES[hi]
    B, A, H, W, _ = p.shape
    gy, gx = torch.meshgrid(torch.arange(H, device=p.device), torch.arange(W, device=p.device), indexing='ij')
    anc = torch.tensor(anchors[hi], dtype=p.dtype, device=p.device)
    cx = (torch.sigmoid(p[..., 0]) + gx) * st
    cy = (torch.sigmoid(p[..., 1]) + gy) * st
    w = anc[:, 0].view(1, A, 1, 1) * torch.exp(p[..., 2].clamp(-8, 8))
    h = anc[:, 1].view(1, A, 1, 1) * torch.exp(p[..., 3].clamp(-8, 8))
    return torch.stack([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], dim=-1)


def box_iou(a, b):
    """a [..., 4], b [M, 4] -> [..., M]"""
    ix = (torch.minimum(a[..., None, 2], b[:, 2]) - torch.maximum(a[..., None, 0], b[:, 0])).clamp(min=0)
    iy = (torch.minimum(a[..., None, 3], b[:, 3]) - torch.maximum(a[..., None, 1], b[:, 1])).clamp(min=0)
    inter = ix * iy
    area_a = ((a[..., 2] - a[..., 0]) * (a[..., 3] - a[..., 1]))[..., None]
    area_b = (b[:, 2] - b[:, 0]) * (b[:, 3] - b[:, 1])
    return inter / (area_a + area_b - inter + 1e-9)


def yolo_loss(outs, targets, gt, gm, anchors, range_w=0.05):
    total = 0.0
    parts = dict(box=0.0, obj=0.0, cls=0.0, rng=0.0)
    B = outs[0].shape[0]
    bce = nn.functional.binary_cross_entropy_with_logits
    for hi, (raw, t) in enumerate(zip(outs, targets)):
        p = reshape_head(raw)
        # ignore background predictions that already overlap a ground-truth box (IoU > 0.5), all images of the batch at once
        with torch.no_grad():
            boxes = decode_boxes(p, hi, anchors).reshape(B, -1, 4)
            ix = (torch.minimum(boxes[:, :, None, 2], gt[:, None, :, 2]) - torch.maximum(boxes[:, :, None, 0], gt[:, None, :, 0])).clamp(min=0)
            iy = (torch.minimum(boxes[:, :, None, 3], gt[:, None, :, 3]) - torch.maximum(boxes[:, :, None, 1], gt[:, None, :, 1])).clamp(min=0)
            inter = ix * iy
            area_p = ((boxes[..., 2] - boxes[..., 0]) * (boxes[..., 3] - boxes[..., 1]))[:, :, None]
            area_g = ((gt[..., 2] - gt[..., 0]) * (gt[..., 3] - gt[..., 1]))[:, None, :]
            iou = torch.where(gm[:, None, :], inter / (area_p + area_g - inter + 1e-9), torch.zeros_like(inter))
            ign = (iou.max(dim=-1).values > 0.5).reshape(t['noobj'].shape)
            noobj = t['noobj'] * (~ign).float()
        m = t['obj'] > 0
        l_obj = bce(p[..., 4], t['obj'], reduction='none')
        l_obj = (l_obj * (t['obj'] + noobj)).sum() / B
        if m.any():
            ws = t['wscale'][m]
            l_xy = (bce(p[..., 0:2][m], t['txy'][m], reduction='none').sum(-1) * ws).sum()
            l_wh = (((p[..., 2:4][m] - t['twh'][m]) ** 2).sum(-1) * ws).sum() * 0.5
            l_box = (l_xy + l_wh) / B
            l_cls = bce(p[..., 5:][m], t['cls'][m], reduction='sum') / B
        else:
            l_box = l_cls = p.sum() * 0.0
        l_rng = (F.relu(raw.abs() - 7.5) ** 2).mean() * range_w * 100
        total = total + 2.0 * l_box + l_obj + l_cls + l_rng
        parts['box'] += float(l_box.detach())
        parts['obj'] += float(l_obj.detach())
        parts['cls'] += float(l_cls.detach())
        parts['rng'] += float(l_rng.detach())
    return total, parts


# ---------------------------------------------------------------- evaluation (float network; the integer network is evaluated by eval_int.py)
def nms_np(boxes, scores, thr=0.45):
    order = np.argsort(-scores, kind='stable')
    keep = []
    while order.size:
        i = order[0]
        keep.append(i)
        if order.size == 1:
            break
        r = order[1:]
        ix = np.clip(np.minimum(boxes[i, 2], boxes[r, 2]) - np.maximum(boxes[i, 0], boxes[r, 0]), 0, None)
        iy = np.clip(np.minimum(boxes[i, 3], boxes[r, 3]) - np.maximum(boxes[i, 1], boxes[r, 1]), 0, None)
        inter = ix * iy
        u = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1]) + (boxes[r, 2] - boxes[r, 0]) * (boxes[r, 3] - boxes[r, 1]) - inter
        order = r[inter / np.maximum(u, 1e-9) <= thr]
    return keep


def detections_float(outs, anchors, conf=0.01):
    """list per image of (cls, score, x0, y0, x1, y1) in network pixels, class-wise NMS"""
    res = []
    B = outs[0].shape[0]
    allb, alls = [], []
    for hi, raw in enumerate(outs):
        p = reshape_head(raw)
        boxes = decode_boxes(p, hi, anchors).reshape(B, -1, 4)
        obj = torch.sigmoid(p[..., 4]).reshape(B, -1)
        cls = torch.sigmoid(p[..., 5:]).reshape(B, -1, NCLS)
        sc, ci = (obj[..., None] * cls).max(-1)          # same rule as the hardware: obj * best class
        allb.append(boxes)
        alls.append(torch.stack([sc, ci.float()], -1))
    boxes = torch.cat(allb, 1).cpu().numpy()
    sc = torch.cat(alls, 1).cpu().numpy()
    for b in range(B):
        out = []
        for c in range(NCLS):
            sel = (sc[b, :, 1] == c) & (sc[b, :, 0] >= conf)
            if not sel.any():
                continue
            bb, ss = boxes[b, sel], sc[b, sel, 0]
            for i in nms_np(bb, ss):
                out.append((c, float(ss[i]), *[float(v) for v in bb[i]]))
        res.append(out)
    return res


def average_precision(dets, labels, iou_thr=0.5):
    """VOC-style AP per class (all-point interpolation) -> dict cls -> AP, plus mAP"""
    aps = {}
    for c in range(NCLS):
        gts = {}
        npos = 0
        for i, lab in enumerate(labels):
            g = [(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2) for (cc, cx, cy, w, h) in lab if int(cc) == c]
            gts[i] = (np.array(g, dtype=np.float64).reshape(-1, 4), np.zeros(len(g), dtype=bool))
            npos += len(g)
        cand = [(s, i, (x0, y0, x1, y1)) for i, d in enumerate(dets) for (cc, s, x0, y0, x1, y1) in d if cc == c]
        cand.sort(key=lambda t: -t[0])
        tp = np.zeros(len(cand))
        for k, (s, i, bb) in enumerate(cand):
            g, used = gts[i]
            if len(g) == 0:
                continue
            ix = np.clip(np.minimum(bb[2], g[:, 2]) - np.maximum(bb[0], g[:, 0]), 0, None)
            iy = np.clip(np.minimum(bb[3], g[:, 3]) - np.maximum(bb[1], g[:, 1]), 0, None)
            inter = ix * iy
            u = (bb[2] - bb[0]) * (bb[3] - bb[1]) + (g[:, 2] - g[:, 0]) * (g[:, 3] - g[:, 1]) - inter
            iou = inter / np.maximum(u, 1e-9)
            j = int(iou.argmax())
            if iou[j] >= iou_thr and not used[j]:
                tp[k] = 1
                used[j] = True
        if npos == 0:
            aps[c] = float('nan')
            continue
        ctp = np.cumsum(tp)
        rec = ctp / npos
        prec = ctp / np.arange(1, len(cand) + 1)
        mrec = np.concatenate([[0], rec, [1]])
        mpre = np.concatenate([[0], prec, [0]])
        for k in range(len(mpre) - 2, -1, -1):
            mpre[k] = max(mpre[k], mpre[k + 1])
        idx = np.nonzero(mrec[1:] != mrec[:-1])[0]
        aps[c] = float(np.sum((mrec[idx + 1] - mrec[idx]) * mpre[idx + 1]))
    vals = [v for v in aps.values() if not math.isnan(v)]
    aps['mAP'] = float(np.mean(vals)) if vals else float('nan')
    return aps


def to_tensor(imgs, device):
    x = torch.from_numpy(imgs).to(device).float()
    return ((x - 128.0) / 128.0).permute(0, 3, 1, 2).contiguous()


def evaluate(model, imgs, labels, anchors, device, bs=256):
    model.eval()
    dets = []
    with torch.no_grad():
        for i in range(0, len(imgs), bs):
            outs = model(to_tensor(imgs[i:i + bs], device))
            dets += detections_float(outs, anchors)
    return average_precision(dets, labels), dets


def augment(img, lab, rng, shift=10):
    """captured frames (camera looking up, objects held overhead): vertical flip, a shift of up to +-shift pixels inside the 72-row picture band
    (the 12 grey letterbox rows stay grey), gain / contrast / per-channel jitter (AWB and AE vary); boxes are shifted and clipped, slivers dropped"""
    pic = img[12:84].astype(np.float32)
    lab = [list(l) for l in lab]
    if rng.random() < 0.5:
        pic = pic[::-1]
        for l in lab:
            l[2] = 96 - l[2]
    dx, dy = rng.integers(-shift, shift + 1, 2)
    out = np.empty_like(pic)
    out[:] = pic.mean((0, 1))
    ys, yd = (slice(0, 72 - dy), slice(dy, 72)) if dy >= 0 else (slice(-dy, 72), slice(0, 72 + dy))
    xs, xd = (slice(0, 128 - dx), slice(dx, 128)) if dx >= 0 else (slice(-dx, 128), slice(0, 128 + dx))
    out[yd, xd] = pic[ys, xs]
    m = out.mean()
    out = (out - m) * rng.uniform(0.8, 1.2) + m * rng.uniform(0.8, 1.2)
    out = out * rng.uniform(0.92, 1.08, 3)
    res = img.copy()
    res[12:84] = np.clip(out, 0, 255).astype(np.uint8)
    keep = []
    for c, cx, cy, w, h in lab:
        x0, x1 = max(cx - w / 2 + dx, 0), min(cx + w / 2 + dx, 128)
        y0, y1 = max(cy - h / 2 + dy, 12), min(cy + h / 2 + dy, 84)
        if x1 - x0 >= 3 and y1 - y0 >= 3 and (x1 - x0) * (y1 - y0) >= 0.3 * w * h:
            keep.append([c, (x0 + x1) / 2, (y0 + y1) / 2, x1 - x0, y1 - y0])
    return res, keep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default='F:/yolo_data')
    ap.add_argument('--out', default='F:/yolo_runs/p5_synth')
    ap.add_argument('--epochs', type=int, default=60)
    ap.add_argument('--bs', type=int, default=128)
    ap.add_argument('--lr', type=float, default=3e-3)
    ap.add_argument('--init', default='', help='start from this model.pt (fine-tuning on captured frames)')
    ap.add_argument('--anchors', default='', help='use the anchors of this anchors.json instead of k-means')
    ap.add_argument('--aug', action='store_true', help='extra augmentation for small captured sets: vertical flip, shift, gain / contrast / per-channel jitter')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    dev = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    tr_img = np.load(os.path.join(a.data, 'train_img.npy'))
    tr_lab = json.load(open(os.path.join(a.data, 'train_lab.json')))
    va_img = np.load(os.path.join(a.data, 'val_img.npy'))
    va_lab = json.load(open(os.path.join(a.data, 'val_lab.json')))
    if a.anchors:
        anchors = json.load(open(a.anchors))['anchors']
    else:
        anchors = list(kmeans_anchors(tr_lab))
    json.dump(dict(anchors=anchors, strides=STRIDES, note='anchors in network pixels (128 x 96 input); head1 = stride 32 (large), head2 = stride 16 (small)'),
              open(os.path.join(a.out, 'anchors.json'), 'w'), indent=1)
    model = Net().to(dev)
    if a.init:
        model.load_state_dict(torch.load(a.init, map_location=dev))
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=5e-4)
    steps = a.epochs * ((len(tr_img) + a.bs - 1) // a.bs)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=steps, pct_start=0.1)
    log = open(os.path.join(a.out, 'train_log.txt'), 'a')
    print('device %s, %d train / %d val images, anchors %s, params %d' % (dev, len(tr_img), len(va_img), anchors, sum(p.numel() for p in model.parameters())), file=log, flush=True)
    rng = np.random.default_rng(0)
    best = -1
    for ep in range(a.epochs):
        model.train()
        perm = rng.permutation(len(tr_img))
        t0 = time.time()
        acc = dict(box=0.0, obj=0.0, cls=0.0, rng=0.0)
        nb = 0
        for i in range(0, len(perm), a.bs):
            idx = perm[i:i + a.bs]
            imgs = tr_img[idx].copy()
            labs = [list(map(list, tr_lab[j])) for j in idx]
            flip = rng.random(len(idx)) < 0.5                     # horizontal flip
            for k in np.nonzero(flip)[0]:
                imgs[k] = imgs[k, :, ::-1]
                for l in labs[k]:
                    l[1] = NW - l[1]
            if a.aug:
                for k in range(len(idx)):
                    imgs[k], labs[k] = augment(imgs[k], labs[k], rng)
            x = to_tensor(imgs, dev)
            tg, gt, gm = build_targets(labs, anchors, dev)
            outs = model(x)
            loss, parts = yolo_loss(list(outs), tg, gt, gm, anchors)
            opt.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 10.0)
            opt.step()
            sched.step()
            for k in acc:
                acc[k] += parts[k]
            nb += 1
        msg = 'epoch %3d  %.0f s  loss box %.3f obj %.3f cls %.3f range %.4f' % (ep, time.time() - t0, acc['box'] / nb, acc['obj'] / nb, acc['cls'] / nb, acc['rng'] / nb)
        if ep % 5 == 4 or ep == a.epochs - 1:
            ap50, _ = evaluate(model, va_img, va_lab, anchors, dev)
            msg += '  val AP50 red %.3f green %.3f blue %.3f mAP %.3f' % (ap50[0], ap50[1], ap50[2], ap50['mAP'])
            if ap50['mAP'] > best:
                best = ap50['mAP']
                torch.save(model.state_dict(), os.path.join(a.out, 'model.pt'))
        print(msg, file=log, flush=True)
        print(msg, flush=True)
    model.load_state_dict(torch.load(os.path.join(a.out, 'model.pt'), map_location=dev))
    folded = fold(model)
    np.savez(os.path.join(a.out, 'float_folded.npz'), **{k + '_w': v[0] for k, v in folded.items()}, **{k + '_b': v[1] for k, v in folded.items()})
    te_img = np.load(os.path.join(a.data, 'test_img.npy'))
    te_lab = json.load(open(os.path.join(a.data, 'test_lab.json')))
    ap_te, _ = evaluate(model, te_img, te_lab, anchors, dev)
    with torch.no_grad():
        o = model(to_tensor(te_img[:512], dev))
        sat = float(sum(((x.abs() >= 7.94).float().mean()) for x in o) / 2)
    json.dump(dict(float_test_AP50=ap_te, best_val_mAP=best, head_saturation_fraction=sat, anchors=anchors), open(os.path.join(a.out, 'metrics.json'), 'w'), indent=1)
    print('float test AP50', ap_te, 'head saturation %.4f' % sat, file=log, flush=True)
    print('float test AP50', ap_te, 'head saturation %.4f' % sat)


if __name__ == '__main__':
    main()
