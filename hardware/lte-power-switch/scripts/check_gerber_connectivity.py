#!/usr/bin/env python3
"""製造用ガーバーとドリルから銅箔の接続を求め、設計 (kicad_pcb) のネットと照合する。

確認すること:
  1. 各ネットのパッドが、1 つの塊としてつながっている (断線なし)
  2. 異なるネットのパッドが、同じ塊に入っていない (ショートなし)
  3. コネクタ J1・J2・J3 の物理的なパッド順が、実物の Grove ケーブルの線の並びと一致する
     (三角のパッドから順に 黒・赤・白・黄。rev A で鏡像だった不具合の再発防止。2026-10-12 に実物で確認)

実行: python3 scripts/check_gerber_connectivity.py   (PIL が必要。失敗時は終了コード 1)
"""
import math
import pathlib
import re
import sys
from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
GERBER = ROOT / "fabrication" / "gerber"
PCB = ROOT / "lte-power-switch.kicad_pcb"
SC = 25  # px/mm
W, H = 40 * SC, 30 * SC
OX, OY, BH = 100.0, 80.0, 28.0   # gen_pcb.py の原点と基板の高さ

# 期待する物理的なパッド順 (三角のパッドから順)。ガーバー座標 (左下原点、Y 上向き) で並べ替える。
#   J1: 三角は上 (Y 降順)  J2: 三角は下 (Y 昇順)  J3: 三角は左 (X 昇順)
EXPECTED = {
    "J1": ("y_desc", ["GND", "/V3V3_IN", "/SIG2", "/SIG1"]),
    "J2": ("y_asc", ["GND", "/VLTE", "/SIG2", "/SIG1"]),
    "J3": ("x_asc", ["GND", "unconnected-(J3-Pin_3-Pad3)", "unconnected-(J3-Pin_2-Pad2)", "/LTE_EN"]),
}
CABLE = ["黒(GND)", "赤(VCC)", "白", "黄"]


def parse_gerber(path):
    t = open(path).read()
    aps = {}
    for m in re.finditer(r"%ADD(\d+)([A-Za-z]+),([^*%]*)\*%", t):
        n, k, p = m.group(1), m.group(2), m.group(3)
        vals = [float(v) for v in re.findall(r"[-\d.]+", p.replace("X", " "))]
        if k == "C":
            aps[n] = ("C", vals[0])
        elif k == "R":
            aps[n] = ("R", vals[0], vals[1])
        else:  # RoundRect: 外接矩形で近似
            pts = vals[2:10]
            aps[n] = ("R", max(pts[0::2]) - min(pts[0::2]), max(pts[1::2]) - min(pts[1::2]))
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    X = lambda v: v * SC
    Y = lambda v: H - v * SC
    cur = None
    x = y = 0.0
    in_reg, reg = False, []
    for line in t.split("\n"):
        line = line.strip()
        m = re.match(r"^D(\d+)\*$", line)
        if m and int(m.group(1)) >= 10:
            cur = aps.get(m.group(1))
            continue
        if line == "G36*":
            in_reg, reg = True, []
            continue
        if line == "G37*":
            if len(reg) > 2:
                d.polygon(reg, fill=255)
            in_reg = False
            continue
        m = re.match(r"^(?:X(-?\d+))?(?:Y(-?\d+))?D0([123])\*$", line)
        if not m:
            continue
        nx = float(m.group(1)) / 1e6 if m.group(1) else x
        ny = float(m.group(2)) / 1e6 if m.group(2) else y
        op = m.group(3)
        if in_reg:
            if op in ("1", "2"):
                reg.append((X(nx), Y(ny)))
        elif op == "1" and cur and cur[0] == "C":
            w = cur[1] * SC
            d.line([(X(x), Y(y)), (X(nx), Y(ny))], fill=255, width=max(1, round(w)))
            r = w / 2
            for px, py in ((x, y), (nx, ny)):
                d.ellipse([X(px) - r, Y(py) - r, X(px) + r, Y(py) + r], fill=255)
        elif op == "3" and cur:
            if cur[0] == "C":
                r = cur[1] * SC / 2
                d.ellipse([X(nx) - r, Y(ny) - r, X(nx) + r, Y(ny) + r], fill=255)
            else:
                hw, hh = cur[1] * SC / 2, cur[2] * SC / 2
                d.rectangle([X(nx) - hw, Y(ny) - hh, X(nx) + hw, Y(ny) + hh], fill=255)
        x, y = nx, ny
    return img


def label(img):
    px = img.load()
    lab = [[0] * W for _ in range(H)]
    n = 0
    for j in range(H):
        for i in range(W):
            if px[i, j] and not lab[j][i]:
                n += 1
                st = [(i, j)]
                lab[j][i] = n
                while st:
                    a, b = st.pop()
                    for da, db in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        u, v = a + da, b + db
                        if 0 <= u < W and 0 <= v < H and px[u, v] and not lab[v][u]:
                            lab[v][u] = n
                            st.append((u, v))
    return lab


def blocks(s, key):
    out, i = [], 0
    while True:
        i = s.find("(" + key, i)
        if i < 0:
            break
        d, j = 0, i
        while True:
            if s[j] == "(":
                d += 1
            elif s[j] == ")":
                d -= 1
                if d == 0:
                    break
            j += 1
        out.append(s[i:j + 1])
        i = j + 1
    return out


def main():
    LF = label(parse_gerber(GERBER / "lte-power-switch-F_Cu.gtl"))
    LB = label(parse_gerber(GERBER / "lte-power-switch-B_Cu.gbl"))
    par = {}

    def find(a):
        par.setdefault(a, a)
        while par[a] != a:
            par[a] = par[par[a]]
            a = par[a]
        return a

    drl = (GERBER / "lte-power-switch-PTH.drl").read_text()
    for vx, vy in ((float(a), float(b)) for a, b in re.findall(r"^X([\d.]+)Y([\d.]+)$", drl, re.M)):
        i, j = round(vx * SC), round(H - vy * SC)
        a, b = LF[j][i], LB[j][i]
        if a and b:
            par[find(("F", a))] = find(("B", b))

    s = PCB.read_text(encoding="utf-8")
    pads = []
    for fp in blocks(s, "footprint"):
        ref = re.search(r'\(property "Reference" "([^"]*)"', fp).group(1)
        at = re.search(r"\(at ([-\d.]+) ([-\d.]+)(?: ([-\d.]+))?\)", fp)
        fx, fy, fa = float(at.group(1)), float(at.group(2)), float(at.group(3) or 0)
        c, sn = math.cos(math.radians(fa)), math.sin(math.radians(fa))
        for p in blocks(fp, "pad"):
            pm = re.match(r'\(pad "([^"]*)" (\w+)', p)
            if pm.group(2) != "smd":
                continue
            pat = re.search(r"\(at ([-\d.]+) ([-\d.]+)", p)
            px_, py_ = float(pat.group(1)), float(pat.group(2))
            ax, ay = fx + px_ * c + py_ * sn, fy - px_ * sn + py_ * c
            nm = re.search(r'\(net "([^"]*)"\)', p)
            pads.append((ref, pm.group(1), ax - OX, BH - (ay - OY), nm.group(1) if nm else None))

    ok = True
    group = {}
    for ref, pn, gx, gy, net in pads:
        l = LF[round((H - gy * SC))][round(gx * SC)]
        group[(ref, pn)] = find(("F", l)) if l else None
        if not l:
            print(f"FAIL: {ref}.{pn} のパッドに銅箔がない ({gx:.2f}, {gy:.2f})")
            ok = False

    by_net = {}
    for ref, pn, gx, gy, net in pads:
        if net:
            by_net.setdefault(net, set()).add(group[(ref, pn)])
    for net, gs in sorted(by_net.items()):
        if len(gs) != 1:
            print(f"FAIL: ネット {net} が {len(gs)} つの塊に分かれている (断線)")
            ok = False
    by_group = {}
    for ref, pn, gx, gy, net in pads:
        if net:
            by_group.setdefault(group[(ref, pn)], set()).add(net)
    for g, nets in by_group.items():
        if len(nets) != 1:
            print(f"FAIL: 異なるネット {sorted(nets)} が同じ塊につながっている (ショート)")
            ok = False
    if ok:
        print(f"OK: {len(by_net)} ネットすべてが、1 つの塊で、ほかのネットとショートしていない")

    for ref, (key, want) in EXPECTED.items():
        row = [p for p in pads if p[0] == ref and p[1] in "1234"]
        sort = {"y_desc": lambda p: -p[3], "y_asc": lambda p: p[3], "x_asc": lambda p: p[2]}[key]
        got = [p[4] for p in sorted(row, key=sort)]
        if got == want:
            print(f"OK: {ref} のパッド順 (三角から) = {' / '.join(f'{n}:{c}' for n, c in zip(want, CABLE))}")
        else:
            print(f"FAIL: {ref} のパッド順 (三角から) = {got}、期待 {want}")
            ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
