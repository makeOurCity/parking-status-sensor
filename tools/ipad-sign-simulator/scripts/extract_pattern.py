#!/usr/bin/env python3
"""Extract a Bool dot-matrix bitmap from a reference photo of the physical
parking sign (Issue #54, plan A).

Pipeline:
1. Crop a few pixels off each edge — the supplied screenshots have a thin
   uniform border (from how they were captured) that is not part of the LED
   panel and otherwise confuses step 2.
2. Detect individual LED bumps (lit or unlit) as local maxima of a lightly
   blurred brightness channel, and take the bounding box of those maxima as
   the true LED array extent (it does not always reach the photo's edges).
3. Re-sample a uniform grid x grid grid over that box. For each cell, take
   the max brightness within a small radius of the cell's dot center (not
   the whole cell's mean) — this avoids a lit neighbour's glow inflating an
   unlit cell's classification.
4. Threshold the grid x grid values with Otsu's method (the lit/unlit
   brightness distribution is clearly bimodal) to get the final Bool grid.

This is a one-off development aid used to populate SignPattern.swift; it is
not part of the shipped app.

Usage:
    .venv/bin/python extract_pattern.py <image> --grid 16 --channel r \
        --overlay /tmp/debug.png --dump
"""
import argparse
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter, maximum_filter

EDGE_MARGIN = 4


def load_channel(path: str, channel: str):
    img = Image.open(path).convert("RGB")
    arr = np.asarray(img).astype(np.float32)
    h, w, _ = arr.shape
    arr = arr[EDGE_MARGIN:h - EDGE_MARGIN, EDGE_MARGIN:w - EDGE_MARGIN]
    cropped_img = Image.fromarray(arr.astype(np.uint8))
    r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
    chan = {"r": r, "g": g, "max": np.maximum(np.maximum(r, g), b),
            "lum": 0.299 * r + 0.587 * g + 0.114 * b}[channel]
    return chan, cropped_img


def detect_bbox(chan: np.ndarray, sigma=1.5, size=9, min_val=10):
    blurred = gaussian_filter(chan, sigma=sigma)
    mx = maximum_filter(blurred, size=size, mode="nearest")
    mask = (blurred == mx) & (blurred > min_val)
    ys, xs = np.nonzero(mask)
    return float(xs.min()), float(xs.max()), float(ys.min()), float(ys.max())


def sample_centers(chan: np.ndarray, x0, x1, y0, y1, grid: int, radius: int):
    pitch_x = (x1 - x0) / (grid - 1)
    pitch_y = (y1 - y0) / (grid - 1)
    h, w = chan.shape
    vals = np.zeros((grid, grid), dtype=np.float32)
    centers = [[None] * grid for _ in range(grid)]
    for i in range(grid):
        cy = y0 + i * pitch_y
        for j in range(grid):
            cx = x0 + j * pitch_x
            x_lo, x_hi = max(int(round(cx - radius)), 0), min(int(round(cx + radius + 1)), w)
            y_lo, y_hi = max(int(round(cy - radius)), 0), min(int(round(cy + radius + 1)), h)
            cell = chan[y_lo:y_hi, x_lo:x_hi]
            vals[i, j] = cell.max() if cell.size else 0.0
            centers[i][j] = (cx, cy)
    return vals, centers


def otsu_threshold(vals: np.ndarray) -> float:
    v = vals.flatten()
    hist, edges = np.histogram(v, bins=256, range=(v.min(), v.max()))
    hist = hist.astype(np.float64)
    total = hist.sum()
    sum_all = float(np.sum(hist * np.arange(256)))
    sum_below = 0.0
    weight_below = 0.0
    best_variance = -1.0
    best_index = 0
    for i in range(256):
        weight_below += hist[i]
        if weight_below == 0:
            continue
        weight_above = total - weight_below
        if weight_above == 0:
            break
        sum_below += i * hist[i]
        mean_below = sum_below / weight_below
        mean_above = (sum_all - sum_below) / weight_above
        variance_between = weight_below * weight_above * (mean_below - mean_above) ** 2
        if variance_between > best_variance:
            best_variance = variance_between
            best_index = i
    return float(edges[best_index])


def draw_overlay(img: Image.Image, centers, on: np.ndarray) -> Image.Image:
    out = img.convert("RGB").copy()
    draw = ImageDraw.Draw(out)
    grid = on.shape[0]
    for i in range(grid):
        for j in range(grid):
            cx, cy = centers[i][j]
            color = (0, 255, 0) if on[i, j] else (255, 0, 255)
            draw.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=color)
    return out.resize((out.width * 3, out.height * 3), Image.NEAREST)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--grid", type=int, required=True)
    ap.add_argument("--channel", choices=["r", "g", "max", "lum"], default="max")
    ap.add_argument("--radius", type=int, default=3)
    ap.add_argument("--overlay", default=None, help="Write a 3x zoomed debug overlay PNG here")
    ap.add_argument("--dump", action="store_true", help="Print Bool rows for SignPattern.swift")
    args = ap.parse_args()

    chan, img = load_channel(args.image, args.channel)
    x0, x1, y0, y1 = detect_bbox(chan)
    pitch_x, pitch_y = (x1 - x0) / (args.grid - 1), (y1 - y0) / (args.grid - 1)
    print(f"LED bbox x=[{x0:.1f},{x1:.1f}] y=[{y0:.1f},{y1:.1f}] pitch=({pitch_x:.2f},{pitch_y:.2f})",
          file=sys.stderr)

    vals, centers = sample_centers(chan, x0, x1, y0, y1, args.grid, args.radius)
    threshold = otsu_threshold(vals)
    on = vals >= threshold
    print(f"grid={args.grid} channel={args.channel} valueRange=[{vals.min():.1f},{vals.max():.1f}]"
          f" otsuThreshold={threshold:.1f} onCount={int(on.sum())}", file=sys.stderr)

    if args.overlay:
        draw_overlay(img, centers, on).save(args.overlay)
        print(f"wrote {args.overlay}", file=sys.stderr)

    if args.dump:
        for row in on:
            print("[" + ", ".join("true" if v else "false" for v in row) + "],")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
