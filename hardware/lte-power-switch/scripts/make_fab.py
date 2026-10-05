#!/usr/bin/env python3
"""JLCPCB 向け製造データ (ガーバー zip, ドリル, BOM, CPL) と確認用の PDF/SVG/PNG を生成する。

BOM/CPL は kicad-cli の pos 出力 (製造用原点 = 基板左下、Y 上向き) を JLCPCB 形式に整形する。
実行前に gen_sch.py / gen_pcb.py で回路図・基板を再生成しておくこと。
"""
import csv
import pathlib
import shutil
import subprocess
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
K = "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
PCB = str(ROOT / "lte-power-switch.kicad_pcb")
SCH = str(ROOT / "lte-power-switch.kicad_sch")
FAB = ROOT / "fabrication"
REND = ROOT / "renders"


def run(*a):
    r = subprocess.run([K, *a], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"kicad-cli failed: {a}\n{r.stdout}\n{r.stderr}")


for d in (FAB, REND):
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir()
gerb = FAB / "gerber"
gerb.mkdir()

# ---- ガーバー + ドリル
run("pcb", "export", "gerbers", "--layers",
    "F.Cu,B.Cu,F.Paste,F.Mask,B.Mask,F.Silkscreen,B.Silkscreen,Edge.Cuts",
    "--use-drill-file-origin", "--subtract-soldermask", "-o", str(gerb), PCB)
run("pcb", "export", "drill", "--format", "excellon", "--drill-origin", "plot", "--excellon-units", "mm",
    "--excellon-zeros-format", "decimal", "--excellon-oval-format", "route", "--excellon-separate-th",
    "--generate-map", "--map-format", "pdf", "-o", str(gerb), PCB)
zp = FAB / "lte-power-switch-gerber.zip"
with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(gerb.iterdir()):
        if f.suffix.lower() in (".pdf", ".gbrjob"):
            continue  # 注文用 zip にはガーバーとドリルのみ
        z.write(f, f.name)

# ---- CPL (表面のみ・DNP/非 BOM 除外)
pos_raw = FAB / "_pos.csv"
run("pcb", "export", "pos", "--format", "csv", "--units", "mm", "--side", "front", "--use-drill-file-origin",
    "--smd-only", "--exclude-dnp", "-o", str(pos_raw), PCB)
rows = list(csv.DictReader(open(pos_raw)))
with open(FAB / "lte-power-switch-cpl.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    for r in rows:
        w.writerow([r["Ref"], f'{float(r["PosX"]):.4f}mm', f'{float(r["PosY"]):.4f}mm', "Top", f'{float(r["Rot"]) % 360:.0f}'])
pos_raw.unlink()
cpl_refs = {r["Ref"] for r in rows}

# ---- BOM (DNP・テストポイント・取り付け穴は除外)
LCSC = {"U1": ("TPS22918DBVR", "SOT-23-6", "C131941"),
        "J1": ("HY2.0-4P-WT", "HY2.0-4P-WT_SMD-RA", "C722729"),
        "J2": ("HY2.0-4P-WT", "HY2.0-4P-WT_SMD-RA", "C722729"),
        "J3": ("HY2.0-4P-WT", "HY2.0-4P-WT_SMD-RA", "C722729"),
        "C1": ("1uF", "C_0603_1608Metric", "C15849"),
        "C2": ("1nF", "C_0603_1608Metric", "C1588"),
        "R1": ("100k", "R_0603_1608Metric", "C25803")}
assert set(LCSC) == cpl_refs, (set(LCSC), cpl_refs)  # BOM と CPL の部品が一致していること
groups = {}
for ref, (comment, fp, lcsc) in LCSC.items():
    groups.setdefault((comment, fp, lcsc), []).append(ref)
with open(FAB / "lte-power-switch-bom.csv", "w", newline="") as f:
    w = csv.writer(f, quoting=csv.QUOTE_ALL)
    w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
    for (comment, fp, lcsc), refs in groups.items():
        w.writerow([comment, ",".join(sorted(refs)), fp, lcsc])

# ---- 確認用の出力
run("sch", "export", "pdf", "-o", str(ROOT / "lte-power-switch-schematic.pdf"), SCH)
run("sch", "erc", "--severity-all", "-o", str(FAB / "erc.rpt"), SCH)
run("pcb", "drc", "--severity-all", "--schematic-parity", "-o", str(FAB / "drc.rpt"), PCB)
for side, layers in (("top", "F.Cu,F.Mask,F.Silkscreen,Edge.Cuts"), ("bottom", "B.Cu,B.Mask,B.Silkscreen,Edge.Cuts")):
    run("pcb", "export", "svg", "--mode-single", "--layers", layers, "--exclude-drawing-sheet",
        "--page-size-mode", "2", *(["--mirror"] if side == "bottom" else []), "-o", str(REND / f"board-{side}.svg"), PCB)
    run("pcb", "render", "--side", side, "--width", "2000", "--height", "1500", "--quality", "high",
        "--background", "opaque", "-o", str(REND / f"board-{side}.png"), PCB)
print("done")
