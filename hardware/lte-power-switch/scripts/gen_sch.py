#!/usr/bin/env python3
"""回路図 (lte-power-switch.kicad_sch) を生成する。

KiCad 標準ライブラリの記号 (Device:R, Device:C, Connector_Generic:Conn_01x04, Connector:TestPoint,
power:GND, power:PWR_FLAG, Mechanical:MountingHole) と、プロジェクトローカルの TPS22918DBVR を
lib_symbols に埋め込み、ネットラベルで配線する。
"""
import pathlib
import re
import uuid
import json

ROOT = pathlib.Path(__file__).resolve().parent.parent
KSYM = pathlib.Path("/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols")
PROJECT = "lte-power-switch"
ROOT_UUID = "5d2a8a0e-3b6c-4c52-9a41-88b0a3c1f001"
REV = "A"
DATE = "2026-10-05"


def uid():
    return str(uuid.uuid4())


def extract(fn, name):
    t = (KSYM / fn).read_text() if not isinstance(fn, pathlib.Path) else fn.read_text()
    i = t.find('(symbol "%s"' % name)
    d = 0
    j = i
    while True:
        c = t[j]
        if c == "(":
            d += 1
        elif c == ")":
            d -= 1
            if d == 0:
                break
        j += 1
    return t[i:j + 1]


def qualified(sym_text, libname, name):
    return sym_text.replace('(symbol "%s"' % name, '(symbol "%s:%s"' % (libname, name), 1)


LIBSYMS = [
    qualified(extract("Device.kicad_sym", "R"), "Device", "R"),
    qualified(extract("Device.kicad_sym", "C"), "Device", "C"),
    qualified(extract("Connector_Generic.kicad_sym", "Conn_01x04"), "Connector_Generic", "Conn_01x04"),
    qualified(extract("Connector.kicad_sym", "TestPoint"), "Connector", "TestPoint"),
    qualified(extract("power.kicad_sym", "GND"), "power", "GND"),
    qualified(extract("power.kicad_sym", "PWR_FLAG"), "power", "PWR_FLAG"),
    qualified(extract("Mechanical.kicad_sym", "MountingHole"), "Mechanical", "MountingHole"),
    qualified(extract(ROOT / "lte-power-switch.kicad_sym", "TPS22918DBVR"), "lte-power-switch", "TPS22918DBVR"),
]

out = []
syms = {}  # ref -> uuid (PCB のパス照合に使う)


def eff(size=1.27, justify=None, hide=False):
    j = f"\n\t\t\t(justify {justify})" if justify else ""
    return f"(effects\n\t\t\t(font\n\t\t\t\t(size {size} {size})\n\t\t\t){j}\n\t\t)"


def wire(x1, y1, x2, y2):
    out.append(f'\t(wire\n\t\t(pts\n\t\t\t(xy {x1:g} {y1:g}) (xy {x2:g} {y2:g})\n\t\t)\n\t\t(stroke\n\t\t\t(width 0)\n\t\t\t(type default)\n\t\t)\n\t\t(uuid "{uid()}")\n\t)\n')


def label(text, x, y, ang=0, just="left bottom"):
    out.append(f'\t(label "{text}"\n\t\t(at {x:g} {y:g} {ang})\n\t\t(effects\n\t\t\t(font\n\t\t\t\t(size 1.27 1.27)\n\t\t\t)\n\t\t\t(justify {just})\n\t\t)\n\t\t(uuid "{uid()}")\n\t)\n')


def noconnect(x, y):
    out.append(f'\t(no_connect\n\t\t(at {x:g} {y:g})\n\t\t(uuid "{uid()}")\n\t)\n')


def textnote(s, x, y, size=1.27):
    s = s.replace("\n", "\\n")
    out.append(f'\t(text "{s}"\n\t\t(exclude_from_sim no)\n\t\t(at {x:g} {y:g} 0)\n\t\t(effects\n\t\t\t(font\n\t\t\t\t(size {size} {size})\n\t\t\t)\n\t\t\t(justify left bottom)\n\t\t)\n\t\t(uuid "{uid()}")\n\t)\n')


def symbol(lib_id, ref, value, x, y, footprint="", datasheet="", fields=None, dnp=False, in_bom=True, on_board=True, ang=0, ref_pos=None, val_pos=None, hide_value=False):
    fields = fields or {}
    u = uid()
    syms[ref] = u
    rx, ry = ref_pos if ref_pos else (x + 2.54, y - 2.54)
    vx, vy = val_pos if val_pos else (x + 2.54, y + 2.54)
    s = f'\t(symbol\n\t\t(lib_id "{lib_id}")\n\t\t(at {x:g} {y:g} {ang})\n\t\t(unit 1)\n\t\t(body_style 1)\n'
    s += f'\t\t(exclude_from_sim no)\n\t\t(in_bom {"yes" if in_bom else "no"})\n\t\t(on_board {"yes" if on_board else "no"})\n'
    s += f'\t\t(in_pos_files {"yes" if on_board else "no"})\n\t\t(dnp {"yes" if dnp else "no"})\n\t\t(uuid "{u}")\n'
    s += f'\t\t(property "Reference" "{ref}"\n\t\t\t(at {rx:g} {ry:g} 0)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n\t\t\t{eff(justify="left")}\n\t\t)\n'
    hv = "\t\t\t(hide yes)\n" if hide_value else ""
    s += f'\t\t(property "Value" "{value}"\n\t\t\t(at {vx:g} {vy:g} 0)\n{hv}\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n\t\t\t{eff(justify="left")}\n\t\t)\n'
    s += f'\t\t(property "Footprint" "{footprint}"\n\t\t\t(at {x:g} {y:g} 0)\n\t\t\t(hide yes)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n\t\t\t{eff()}\n\t\t)\n'
    s += f'\t\t(property "Datasheet" "{datasheet}"\n\t\t\t(at {x:g} {y:g} 0)\n\t\t\t(hide yes)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n\t\t\t{eff()}\n\t\t)\n'
    for k, v in fields.items():
        s += f'\t\t(property "{k}" "{v}"\n\t\t\t(at {x:g} {y:g} 0)\n\t\t\t(hide yes)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n\t\t\t{eff()}\n\t\t)\n'
    return s, u


def place(lib_id, ref, value, x, y, pins, **kw):
    s, u = symbol(lib_id, ref, value, x, y, **kw)
    for p in pins:
        s += f'\t\t(pin "{p}"\n\t\t\t(uuid "{uid()}")\n\t\t)\n'
    s += f'\t\t(instances\n\t\t\t(project "{PROJECT}"\n\t\t\t\t(path "/{ROOT_UUID}"\n\t\t\t\t\t(reference "{ref}")\n\t\t\t\t\t(unit 1)\n\t\t\t\t)\n\t\t\t)\n\t\t)\n\t)\n'
    out.append(s)


pwr_n = [0]


def power(lib_id, value, x, y):
    pwr_n[0] += 1
    ref = f"#PWR{pwr_n[0]:02d}" if lib_id == "power:GND" else f"#FLG{pwr_n[0]:02d}"
    s = f'\t(symbol\n\t\t(lib_id "{lib_id}")\n\t\t(at {x:g} {y:g} 0)\n\t\t(unit 1)\n\t\t(body_style 1)\n\t\t(exclude_from_sim no)\n\t\t(in_bom no)\n\t\t(on_board no)\n\t\t(in_pos_files no)\n\t\t(dnp no)\n\t\t(uuid "{uid()}")\n'
    s += f'\t\t(property "Reference" "{ref}"\n\t\t\t(at {x:g} {y:g} 0)\n\t\t\t(hide yes)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n\t\t\t{eff()}\n\t\t)\n'
    dy = 2.54 if lib_id == "power:GND" else -3.81
    s += f'\t\t(property "Value" "{value}"\n\t\t\t(at {x + 2.54:g} {y + dy / 2:g} 0)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n\t\t\t{eff(justify="left")}\n\t\t)\n'
    s += f'\t\t(property "Footprint" ""\n\t\t\t(at {x:g} {y:g} 0)\n\t\t\t(hide yes)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n\t\t\t{eff()}\n\t\t)\n'
    s += f'\t\t(property "Datasheet" ""\n\t\t\t(at {x:g} {y:g} 0)\n\t\t\t(hide yes)\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)\n\t\t\t{eff()}\n\t\t)\n'
    s += f'\t\t(pin "1"\n\t\t\t(uuid "{uid()}")\n\t\t)\n'
    s += f'\t\t(instances\n\t\t\t(project "{PROJECT}"\n\t\t\t\t(path "/{ROOT_UUID}"\n\t\t\t\t\t(reference "{ref}")\n\t\t\t\t\t(unit 1)\n\t\t\t\t)\n\t\t\t)\n\t\t)\n\t)\n'
    out.append(s)


def gnd(x, y):
    power("power:GND", "GND", x, y)


def flag(x, y):
    power("power:PWR_FLAG", "PWR_FLAG", x, y)


# ----------------------------------------------------------------- 部品
FP_C = "Capacitor_SMD:C_0603_1608Metric"
FP_R = "Resistor_SMD:R_0603_1608Metric"
FP_J = "lte-power-switch:HY2.0-4P-WT_SMD-RA"
FP_TP = "TestPoint:TestPoint_Pad_D1.5mm"
FP_H = "MountingHole:MountingHole_2.2mm_M2"

# コネクタ: ピン n は (x-5.08, y-2.54+2.54*(n-1))
def connector(ref, title, x, y, nets, note):
    place("Connector_Generic:Conn_01x04", ref, "HY2.0-4P-WT", x, y, [1, 2, 3, 4], footprint=FP_J, datasheet="https://www.lcsc.com/datasheet/C722729.pdf",
          fields={"LCSC": "C722729"}, ref_pos=(x - 2.54, y - 7.62), val_pos=(x - 2.54, y + 8.89))
    textnote(title, x - 20.32, y - 15.24, 1.5)
    textnote(note, x - 20.32, y - 12.7, 1.0)
    for n, net in enumerate(nets, start=1):
        py = y - 2.54 + 2.54 * (n - 1)
        px = x - 5.08
        if net == "NC":
            noconnect(px, py)
        elif net == "GND":
            wire(px, py, px - 5.08, py)
            gnd(px - 5.08, py)
        else:
            wire(px, py, px - 5.08, py)
            label(net, px - 5.08, py, 180, "right bottom")


connector("J1", "J1  IN  (from Shield UART Grove port)", 50.8, 55.88,
          ["SIG1", "SIG2", "V3V3_IN", "GND"], "pin1 yellow=SIG1, pin2 white=SIG2, pin3 red=3V3, pin4 black=GND")
connector("J2", "J2  OUT  (to LTE-M unit, Grove UART)", 50.8, 96.52,
          ["SIG1", "SIG2", "VLTE", "GND"], "pin1/pin2 pass-through from J1, pin3 = switched VLTE")
connector("J3", "J3  CTRL  (from Shield D0 = GPIO1)", 50.8, 137.16,
          ["LTE_EN", "NC", "NC", "GND"], "pin1 = LTE_EN. pin2/pin3 left open on purpose (do not feed 5V)")

# U1: 中心 (152.4, 69.85)
UX, UY = 152.4, 69.85
place("lte-power-switch:TPS22918DBVR", "U1", "TPS22918DBVR", UX, UY, [1, 2, 3, 4, 5, 6],
      footprint="lte-power-switch:SOT-23-6_TPS22918DBVR", datasheet="https://www.ti.com/lit/ds/symlink/tps22918.pdf", fields={"LCSC": "C131941"},
      ref_pos=(UX - 3.81, UY - 10.16), val_pos=(UX + 5.08, UY + 10.16))
# VIN / ON は左、VOUT / QOD / CT は右、GND は下
for dy, net in [(-2.54, "V3V3_IN"), (2.54, "LTE_EN")]:
    wire(UX - 10.16, UY + dy, UX - 15.24, UY + dy)
    label(net, UX - 15.24, UY + dy, 180, "right bottom")
for dy, net in [(-2.54, "VLTE"), (0, "QOD"), (2.54, "CT")]:
    wire(UX + 10.16, UY + dy, UX + 15.24, UY + dy)
    label(net, UX + 15.24, UY + dy, 0, "left bottom")
wire(UX, UY + 7.62, UX, UY + 10.16)
gnd(UX, UY + 10.16)


def vpart(lib, ref, val, x, y, top, bottom, fp, lcsc=None, dnp=False, note=None):
    f = {"LCSC": lcsc} if lcsc else {}
    place(lib, ref, val, x, y, [1, 2], footprint=fp, fields=f, dnp=dnp,
          ref_pos=(x + 2.54, y - 1.27), val_pos=(x + 2.54, y + 1.27))
    for (py, net, d) in [(y - 3.81, top, -1), (y + 3.81, bottom, 1)]:
        ey = py + d * 2.54
        wire(x, py, x, ey)
        if net == "GND":
            gnd(x, ey)
        else:
            label(net, x, ey, 0, "left bottom" if d < 0 else "left top")
    if note:
        textnote(note, x - 2.54, y + 10.16, 1.0)


vpart("Device:C", "C1", "1uF", 104.14, 69.85, "V3V3_IN", "GND", FP_C, "C15849")
textnote("C1: VIN bypass (datasheet: 1uF or more).\nX5R 50V, place close to U1", 91.44, 83.82, 1.0)
vpart("Device:R", "R1", "100k", 127.0, 109.22, "LTE_EN", "GND", FP_R, "C25803")
textnote("R1: ON-pin pull-down.\nRequired (ON must not float)", 109.22, 124.46, 1.0)
vpart("Device:C", "C2", "1nF", 182.88, 101.6, "CT", "GND", FP_C, "C1588")
textnote("C2: CT slew-rate cap\n1nF default, 0603 pads\n(swap e.g. 2.2nF)", 165.1, 114.3, 1.0)
vpart("Device:R", "R2", "DNP", 203.2, 101.6, "QOD", "VLTE", FP_R, None, dnp=True)
textnote("R2: QOD to VOUT, DNP\n(QOD disabled by default)\n0603 pads for experiments", 190.5, 114.3, 1.0)
vpart("Device:C", "C3", "10uF", 223.52, 101.6, "VLTE", "GND", FP_C, "C19702", dnp=True)
textnote("C3: output cap, DNP", 215.9, 114.3, 1.0)

# テストポイント (実装しない)
for i, (x, net) in enumerate([(160.02, "V3V3_IN"), (180.34, "VLTE"), (200.66, "LTE_EN"), (220.98, "GND")], start=1):
    y = 137.16
    place("Connector:TestPoint", f"TP{i}", f"TP_{net}", x, y, [1], footprint=FP_TP, in_bom=False,
          ref_pos=(x + 2.54, y - 5.08), val_pos=(x + 2.54, y - 7.62), hide_value=False)
    wire(x, y, x, y + 2.54)
    if net == "GND":
        gnd(x, y + 2.54)
        wire(x, y + 2.54, x - 5.08, y + 2.54)
        flag(x - 5.08, y + 2.54)
    else:
        label(net, x, y + 2.54, 0, "left top")
        if net == "V3V3_IN":
            wire(x, y + 2.54, x - 5.08, y + 2.54)
            flag(x - 5.08, y + 2.54)
textnote("Test points (not assembled): V3V3_IN / VLTE / LTE_EN / GND", 160.02, 126.0, 1.0)

# 取り付け穴
place("Mechanical:MountingHole", "H1", "MountingHole_M2", 240.0, 137.16, [], footprint=FP_H, in_bom=False)
place("Mechanical:MountingHole", "H2", "MountingHole_M2", 265.0, 137.16, [], footprint=FP_H, in_bom=False)

textnote("LTE power switch  rev A  (#88)\nTI TPS22918DBVR load switch gates the LTE-M unit VCC (Grove pin3).\n"
         "Grove pin1/pin2 (UART) pass straight through J1 -> J2.\nLTE_EN: HIGH = ON. R1 pulls it LOW when the GPIO is Hi-Z (deep sleep, reset).",
         160.02, 36.0, 1.27)

# ----------------------------------------------------------------- 出力
head = (f'(kicad_sch\n\t(version 20260306)\n\t(generator "eeschema")\n\t(generator_version "10.0")\n\t(uuid "{ROOT_UUID}")\n\t(paper "A4")\n'
        f'\t(title_block\n\t\t(title "LTE power switch")\n\t\t(date "{DATE}")\n\t\t(rev "{REV}")\n\t\t(company "Issue #88")\n'
        f'\t\t(comment 1 "Grove IN / OUT / CTRL load-switch board (TPS22918DBVR)")\n\t)\n')
body = "\t(lib_symbols\n" + "\n".join(LIBSYMS) + "\n\t)\n"
tail = '\t(sheet_instances\n\t\t(path "/"\n\t\t\t(page "1")\n\t\t)\n\t)\n\t(embedded_fonts no)\n)\n'
(ROOT / "lte-power-switch.kicad_sch").write_text(head + body + "".join(out) + tail)
json.dump(syms, open(ROOT / "scripts" / "sym_uuids.json", "w"), indent=1)
print("sch written", len(syms), "symbols")
