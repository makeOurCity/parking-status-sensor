#!/usr/bin/env python3
"""プロジェクトローカルのシンボル・フットプリントライブラリを生成する。

出典:
- TPS22918DBVR / HY2.0-4P-WT のパッド寸法は easyeda2kicad (LCSC C131941 / C722729) が
  LCSC(EasyEDA) 公開ライブラリから取得したもの。ここでは KiCad 10 形式に書き直している。
- ピン配置は TI データシート SLVSD76C (DBV パッケージ 上面図) と照合済み。
"""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRETTY = ROOT / "lte-power-switch.pretty"

HDR = '\t(version 20260206)\n\t(generator "pcbnew")\n\t(generator_version "10.0")\n'


def prop(name, val, x, y, layer, hide=False, size=1.0, thick=0.15):
    h = "\t\t(hide yes)\n" if hide else ""
    return (f'\t(property "{name}" "{val}"\n\t\t(at {x} {y} 0)\n\t\t(layer "{layer}")\n{h}'
            f'\t\t(effects\n\t\t\t(font\n\t\t\t\t(size {size} {size})\n\t\t\t\t(thickness {thick})\n\t\t\t)\n\t\t)\n\t)\n')


def line(x1, y1, x2, y2, layer, w):
    return (f'\t(fp_line\n\t\t(start {x1} {y1})\n\t\t(end {x2} {y2})\n\t\t(stroke\n\t\t\t(width {w})\n\t\t\t(type solid)\n\t\t)\n'
            f'\t\t(layer "{layer}")\n\t)\n')


def rect(x1, y1, x2, y2, layer, w, fill="no"):
    return (f'\t(fp_rect\n\t\t(start {x1} {y1})\n\t\t(end {x2} {y2})\n\t\t(stroke\n\t\t\t(width {w})\n\t\t\t(type solid)\n\t\t)\n'
            f'\t\t(fill {fill})\n\t\t(layer "{layer}")\n\t)\n')


def poly(pts, layer, w, fill="no"):
    p = " ".join(f"(xy {x} {y})" for x, y in pts)
    return (f'\t(fp_poly\n\t\t(pts {p})\n\t\t(stroke\n\t\t\t(width {w})\n\t\t\t(type solid)\n\t\t)\n'
            f'\t\t(fill {fill})\n\t\t(layer "{layer}")\n\t)\n')


def pad(num, x, y, w, h):
    return (f'\t(pad "{num}" smd rect\n\t\t(at {x} {y})\n\t\t(size {w} {h})\n'
            f'\t\t(layers "F.Cu" "F.Mask" "F.Paste")\n\t)\n')


def text(s, x, y, layer, size=0.8, thick=0.12, rot=0):
    return (f'\t(fp_text user "{s}"\n\t\t(at {x} {y} {rot})\n\t\t(layer "{layer}")\n'
            f'\t\t(effects\n\t\t\t(font\n\t\t\t\t(size {size} {size})\n\t\t\t\t(thickness {thick})\n\t\t\t)\n\t\t)\n\t)\n')


# ---------------------------------------------------------------- TPS22918DBVR
def sot23_6():
    s = '(footprint "SOT-23-6_TPS22918DBVR"\n' + HDR
    s += '\t(layer "F.Cu")\n'
    s += '\t(descr "SOT-23-6 (TI DBV) for TPS22918DBVR, LCSC C131941. Pad geometry from the LCSC/EasyEDA library (easyeda2kicad). Pin 1 at +X,+Y at rotation 0 (JLCPCB/EasyEDA reference orientation).")\n'
    s += '\t(tags "SOT-23-6 TPS22918 load switch C131941")\n'
    s += prop("Reference", "REF**", 0, -2.9, "F.SilkS")
    s += prop("Value", "TPS22918DBVR", 0, 2.9, "F.Fab")
    s += prop("Datasheet", "https://www.ti.com/lit/ds/symlink/tps22918.pdf", 0, 0, "F.Fab", hide=True)
    s += '\t(attr smd)\n'
    # Fab 本体
    s += rect(-0.8, -1.45, 0.8, 1.45, "F.Fab", 0.1)
    # 1 番ピン側の面取りマーク (Fab)
    s += poly([(0.8, 0.5), (0.3, 0.95), (0.8, 1.45)], "F.Fab", 0.1)
    # シルク: 上下辺 (パッドと干渉しない)
    s += line(-0.8, -1.6, 0.8, -1.6, "F.SilkS", 0.12)
    s += line(-0.8, 1.6, 0.8, 1.6, "F.SilkS", 0.12)
    # 1 番ピンのドット (パッド 1 の外側 +X 側)
    s += (f'\t(fp_circle\n\t\t(center 2.3 0.95)\n\t\t(end 2.45 0.95)\n\t\t(stroke\n\t\t\t(width 0.12)\n\t\t\t(type solid)\n\t\t)\n'
          f'\t\t(fill yes)\n\t\t(layer "F.SilkS")\n\t)\n')
    s += rect(-2.0, -1.4, 2.0, 1.4, "F.CrtYd", 0.05)
    for n, x, y in [(1, 1.35, 0.95), (2, 1.35, 0.0), (3, 1.35, -0.95),
                    (4, -1.35, -0.95), (5, -1.35, 0.0), (6, -1.35, 0.95)]:
        s += pad(n, x, y, 1.1, 0.6)
    s += ('\t(model "${KIPRJMOD}/3dmodels/SOT-23-6_L2.9-W1.6-H1.5-LS2.8-P0.95.wrl"\n'
          '\t\t(offset\n\t\t\t(xyz 0 0 0)\n\t\t)\n\t\t(scale\n\t\t\t(xyz 1 1 1)\n\t\t)\n'
          '\t\t(rotate\n\t\t\t(xyz 0 0 180)\n\t\t)\n\t)\n')
    s += ')\n'
    return s


# ---------------------------------------------------------------- HY2.0-4P-WT
def hy20():
    s = '(footprint "HY2.0-4P-WT_SMD-RA"\n' + HDR
    s += '\t(layer "F.Cu")\n'
    s += ('\t(descr "CAX HY2.0-4P-WT (LCSC C722729) 2.0mm pitch 4P SMD right-angle (Grove-compatible receptacle). '
          'Pad geometry from the LCSC/EasyEDA library (easyeda2kicad). Body 12.0 x 7.9mm (datasheet), '
          'mating face toward +Y, contact tails toward -Y, pin 1 at -X at rotation 0.")\n')
    s += '\t(tags "HY2.0 Grove JST-PH 2.0mm SMD right angle C722729")\n'
    s += prop("Reference", "REF**", 0, 0, "F.Fab", size=1.0)
    s += prop("Value", "HY2.0-4P-WT", 0, 7.5, "F.Fab")
    s += prop("Datasheet", "https://www.lcsc.com/datasheet/C722729.pdf", 0, 0, "F.Fab", hide=True)
    s += '\t(attr smd)\n'
    # Fab: 本体 (データシート 幅 12.0 x 奥行き 7.9)
    s += rect(-6.05, -2.43, 6.05, 5.45, "F.Fab", 0.1)
    # 嵌合口 (正面 +Y 側) の目印
    s += line(-5.0, 4.4, 5.0, 4.4, "F.Fab", 0.1)
    # シルク: 本体の背面側コーナーと両側面 (タブパッドと干渉しない範囲)
    for sx in (-1, 1):
        s += line(sx * 6.15, -2.43, sx * 6.15, 1.75, "F.SilkS", 0.12)
        s += line(sx * 6.15, -2.43, sx * 4.6, -2.43, "F.SilkS", 0.12)
    # 1 番ピンの目印: パッド 1 の左隣 (-X 側)、パッド先端側。三角形の頂点はパッド 1 を向く
    s += poly([(-5.3, -5.3), (-5.3, -4.1), (-4.4, -4.7)], "F.SilkS", 0.1, fill="yes")
    # 嵌合方向 (ケーブルが出る側 +Y) の矢印 (Fab)
    s += line(0, 5.0, 0, 3.0, "F.Fab", 0.1)
    s += rect(-6.25, -5.8, 6.25, 5.8, "F.CrtYd", 0.05)
    for n, x in [(1, -3.0), (2, -1.0), (3, 1.0), (4, 3.0)]:
        s += pad(n, x, -3.9, 1.0, 3.4)
    # 5, 6 = シェルのタブ (回路上は未接続)
    s += pad("5", 5.3, 3.9, 1.5, 3.6)
    s += pad("6", -5.3, 3.9, 1.5, 3.6)
    s += ('\t(model "${KIPRJMOD}/3dmodels/CONN-SMD_HY2.00-WS-4P.wrl"\n'
          '\t\t(offset\n\t\t\t(xyz 0 0 0)\n\t\t)\n\t\t(scale\n\t\t\t(xyz 1 1 1)\n\t\t)\n'
          '\t\t(rotate\n\t\t\t(xyz 0 0 0)\n\t\t)\n\t)\n')
    s += ')\n'
    return s


# ---------------------------------------------------------------- symbol
def symbol_lib():
    def pin(typ, x, y, ang, name, num):
        return (f'\t\t\t(pin {typ} line\n\t\t\t\t(at {x} {y} {ang})\n\t\t\t\t(length 2.54)\n'
                f'\t\t\t\t(name "{name}"\n\t\t\t\t\t(effects\n\t\t\t\t\t\t(font\n\t\t\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t\t\t)\n\t\t\t\t\t)\n\t\t\t\t)\n'
                f'\t\t\t\t(number "{num}"\n\t\t\t\t\t(effects\n\t\t\t\t\t\t(font\n\t\t\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t\t\t)\n\t\t\t\t\t)\n\t\t\t\t)\n\t\t\t)\n')

    def sprop(name, val, x, y, hide=False):
        h = "\t\t\t(hide yes)\n" if hide else ""
        return (f'\t\t(property "{name}" "{val}"\n\t\t\t(at {x} {y} 0)\n{h}'
                f'\t\t\t(effects\n\t\t\t\t(font\n\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t)\n\t\t\t)\n\t\t)\n')

    s = '(kicad_symbol_lib\n\t(version 20251024)\n\t(generator "kicad_symbol_editor")\n\t(generator_version "10.0")\n'
    s += '\t(symbol "TPS22918DBVR"\n\t\t(exclude_from_sim no)\n\t\t(in_bom yes)\n\t\t(on_board yes)\n\t\t(in_pos_files yes)\n'
    s += '\t\t(duplicate_pin_numbers_are_jumpers no)\n'
    s += sprop("Reference", "U", 0, 7.62)
    s += sprop("Value", "TPS22918DBVR", 0, -10.16)
    s += sprop("Footprint", "lte-power-switch:SOT-23-6_TPS22918DBVR", 0, 0, True)
    s += sprop("Datasheet", "https://www.ti.com/lit/ds/symlink/tps22918.pdf", 0, 0, True)
    s += sprop("Description", "TI TPS22918 5.5V 2A load switch with configurable rise time and quick output discharge, SOT-23-6 (DBV)", 0, 0, True)
    s += sprop("LCSC", "C131941", 0, 0, True)
    s += sprop("ki_keywords", "load switch power switch TPS22918", 0, 0, True)
    s += ('\t\t(symbol "TPS22918DBVR_0_1"\n\t\t\t(rectangle\n\t\t\t\t(start -7.62 5.08)\n\t\t\t\t(end 7.62 -5.08)\n'
          '\t\t\t\t(stroke\n\t\t\t\t\t(width 0.254)\n\t\t\t\t\t(type default)\n\t\t\t\t)\n\t\t\t\t(fill\n\t\t\t\t\t(type background)\n\t\t\t\t)\n\t\t\t)\n\t\t)\n')
    s += '\t\t(symbol "TPS22918DBVR_1_1"\n'
    # TI DBV 上面図: 1 VIN, 2 GND, 3 ON, 4 CT, 5 QOD, 6 VOUT
    s += pin("power_in", -10.16, 2.54, 0, "VIN", 1)
    s += pin("input", -10.16, -2.54, 0, "ON", 3)
    s += pin("power_out", 10.16, 2.54, 180, "VOUT", 6)
    s += pin("passive", 10.16, 0, 180, "QOD", 5)
    s += pin("passive", 10.16, -2.54, 180, "CT", 4)
    s += pin("power_in", 0, -7.62, 90, "GND", 2)
    s += '\t\t)\n\t\t(embedded_fonts no)\n\t)\n)\n'
    return s


if __name__ == "__main__":
    PRETTY.mkdir(exist_ok=True)
    (PRETTY / "SOT-23-6_TPS22918DBVR.kicad_mod").write_text(sot23_6())
    (PRETTY / "HY2.0-4P-WT_SMD-RA.kicad_mod").write_text(hy20())
    (ROOT / "lte-power-switch.kicad_sym").write_text(symbol_lib())
    def sl(name, uri, descr):
        return f'  (lib (name "{name}")(type "KiCad")(uri "{uri}")(options "")(descr "{descr}"))\n'
    sym = sl("lte-power-switch", "${KIPRJMOD}/lte-power-switch.kicad_sym", "Project symbols")
    for n in ["Device", "power", "Connector_Generic", "Connector", "Mechanical"]:
        sym += sl(n, "${KICAD10_SYMBOL_DIR}/%s.kicad_sym" % n, "KiCad standard")
    fp = sl("lte-power-switch", "${KIPRJMOD}/lte-power-switch.pretty", "Project footprints (LCSC/EasyEDA-derived)")
    for n in ["Capacitor_SMD", "Resistor_SMD", "TestPoint", "MountingHole"]:
        fp += sl(n, "${KICAD10_FOOTPRINT_DIR}/%s.pretty" % n, "KiCad standard")
    (ROOT / "fp-lib-table").write_text("(fp_lib_table\n  (version 7)\n" + fp + ")\n")
    (ROOT / "sym-lib-table").write_text("(sym_lib_table\n  (version 7)\n" + sym + ")\n")
    print("ok")
