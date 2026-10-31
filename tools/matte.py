#!/usr/bin/env python3
"""Build a clean alpha matte for a subject on a black background.

usage: matte.py luma.gray W H alpha.gray [tol=0.05] [min_area=400] [edge=60]

- Background = black pixels that are connected to the frame border (flood fill), so dark shading
  *inside* the subject stays opaque (full fingers) while real gaps between fingers stay transparent.
- Opaque islands smaller than min_area pixels (dust, film grain) are dropped.
- Alpha ramps to 0 over `edge` pixels at the frame borders, so an arm leaving the picture fades out
  instead of ending in a straight cut.
Reads/writes raw 8-bit gray buffers (ffmpeg -f rawvideo -pix_fmt gray).
"""
import sys
from collections import deque

src, W, H, dst = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
tol = float(sys.argv[5]) if len(sys.argv) > 5 else 0.05
min_area = int(sys.argv[6]) if len(sys.argv) > 6 else 400
edge = int(sys.argv[7]) if len(sys.argv) > 7 else 60

luma = open(src, 'rb').read()
n = W * H
assert len(luma) == n, f"expected {n} bytes, got {len(luma)}"
thr = int(tol * 255)
fg = bytes(1 if v > thr else 0 for v in luma)

def neighbors(i):
    x = i % W
    if x > 0: yield i - 1
    if x < W - 1: yield i + 1
    if i >= W: yield i - W
    if i < n - W: yield i + W

# 1. flood-fill the background from the border
bg = bytearray(n)
q = deque()
def seed(i):
    if not bg[i] and not fg[i]:
        bg[i] = 1; q.append(i)
for x in range(W): seed(x); seed((H - 1) * W + x)
for y in range(H): seed(y * W); seed(y * W + W - 1)
while q:
    i = q.popleft()
    for j in neighbors(i):
        if not bg[j] and not fg[j]:
            bg[j] = 1; q.append(j)

alpha = bytearray(0 if bg[i] else 255 for i in range(n))

# 2. drop small opaque islands
seen = bytearray(n)
for s in range(n):
    if alpha[s] and not seen[s]:
        comp = [s]; seen[s] = 1; q.append(s)
        while q:
            i = q.popleft()
            for j in neighbors(i):
                if alpha[j] and not seen[j]:
                    seen[j] = 1; q.append(j); comp.append(j)
        if len(comp) < min_area:
            for i in comp: alpha[i] = 0

# 3. feather at the frame borders
if edge > 0:
    for y in range(H):
        ry = min(1.0, y / edge, (H - 1 - y) / edge)
        row = y * W
        for x in range(W):
            i = row + x
            if alpha[i]:
                r = min(ry, x / edge, (W - 1 - x) / edge)
                if r < 1.0:
                    alpha[i] = int(alpha[i] * max(0.0, r))

open(dst, 'wb').write(alpha)
print(f"matte: {sum(1 for a in alpha if a) * 100 // n}% opaque")
