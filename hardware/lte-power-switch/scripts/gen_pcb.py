#!/usr/bin/env python3
"""基板 (lte-power-switch.kicad_pcb) を pcbnew Python API で生成する。

実行: /Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 scripts/gen_pcb.py
座標は基板左上を (0,0) とするローカル座標 [mm] で書き、(OX, OY) だけずらして配置する。
"""
import json
import pathlib
import pcbnew
from pcbnew import FromMM, VECTOR2I

ROOT = pathlib.Path(__file__).resolve().parent.parent
STD_FP = pathlib.Path("/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints")
LOCAL_FP = ROOT / "lte-power-switch.pretty"
SYM_UUIDS = json.load(open(ROOT / "scripts" / "sym_uuids.json"))
SCH_UUID = "5d2a8a0e-3b6c-4c52-9a41-88b0a3c1f001"

W, H = 38.0, 28.0
OX, OY = 100.0, 80.0

F_CU, B_CU = pcbnew.F_Cu, pcbnew.B_Cu


def P(x, y):
    return VECTOR2I(FromMM(OX + x), FromMM(OY + y))


board = pcbnew.BOARD()
ds = board.GetDesignSettings()
ds.SetCopperLayerCount(2)
ds.SetBoardThickness(FromMM(1.6))
ds.m_MinClearance = FromMM(0.2)
ds.m_TrackMinWidth = FromMM(0.2)
ds.m_ViasMinSize = FromMM(0.5)
ds.m_MinThroughDrill = FromMM(0.3)
ds.m_CopperEdgeClearance = FromMM(0.3)
ds.m_HoleToHoleMin = FromMM(0.5)
try:
    ds.m_TentViasFront = True
    ds.m_TentViasBack = True
except Exception:
    pass

# ------------------------------------------------------------ ネット
NETNAMES = ["GND", "/SIG1", "/SIG2", "/V3V3_IN", "/VLTE", "/LTE_EN", "/QOD", "/CT",
            "unconnected-(J3-Pin_2-Pad2)", "unconnected-(J3-Pin_3-Pad3)"]
nets = {}
for n in NETNAMES:
    ni = pcbnew.NETINFO_ITEM(board, n)
    board.Add(ni)
    nets[n] = ni


def net(n):
    return nets[n]


# ------------------------------------------------------------ 部品
def load(libdir, name):
    return pcbnew.FootprintLoad(str(libdir), name)


LCSC = {"J1": "C722729", "J2": "C722729", "J3": "C722729", "U1": "C131941", "C1": "C15849",
        "C2": "C1588", "C3": "C19702", "R1": "C25803"}
VALUE = {"J1": "HY2.0-4P-WT", "J2": "HY2.0-4P-WT", "J3": "HY2.0-4P-WT", "U1": "TPS22918DBVR",
         "C1": "1uF", "C2": "1nF", "C3": "10uF", "R1": "100k", "R2": "DNP",
         "TP1": "TP_V3V3_IN", "TP2": "TP_VLTE", "TP3": "TP_LTE_EN", "TP4": "TP_GND", "H1": "MountingHole_M2", "H2": "MountingHole_M2"}
PADNETS = {
    "J1": {"1": "/SIG1", "2": "/SIG2", "3": "/V3V3_IN", "4": "GND"},
    "J2": {"1": "/SIG1", "2": "/SIG2", "3": "/VLTE", "4": "GND"},
    "J3": {"1": "/LTE_EN", "2": "unconnected-(J3-Pin_2-Pad2)", "3": "unconnected-(J3-Pin_3-Pad3)", "4": "GND"},
    "U1": {"1": "/V3V3_IN", "2": "GND", "3": "/LTE_EN", "4": "/CT", "5": "/QOD", "6": "/VLTE"},
    "C1": {"1": "/V3V3_IN", "2": "GND"},
    "R1": {"1": "/LTE_EN", "2": "GND"},
    "C2": {"1": "/CT", "2": "GND"},
    "R2": {"1": "/QOD", "2": "/VLTE"},
    "C3": {"1": "/VLTE", "2": "GND"},
    "TP1": {"1": "/V3V3_IN"}, "TP2": {"1": "/VLTE"}, "TP3": {"1": "/LTE_EN"}, "TP4": {"1": "GND"},
}
fps = {}


def add_fp(ref, libdir, name, x, y, rot):
    fp = load(libdir, name)
    libnick = libdir.name[:-len(".pretty")]
    fp.SetFPID(pcbnew.LIB_ID(libnick, name))
    fp.SetReference(ref)
    fp.SetValue(VALUE.get(ref, name))
    fp.SetPosition(P(x, y))
    fp.SetOrientationDegrees(rot)
    for pad in fp.Pads():
        n = PADNETS.get(ref, {}).get(pad.GetNumber())
        if n:
            pad.SetNet(net(n))
    if ref in SYM_UUIDS:
        fp.SetPath(pcbnew.KIID_PATH(f"/{SCH_UUID}/{SYM_UUIDS[ref]}"))
    fp.Reference().SetLayer(pcbnew.F_Fab)
    fp.Reference().SetTextSize(VECTOR2I(FromMM(0.6), FromMM(0.6)))
    fp.Reference().SetTextThickness(FromMM(0.1))
    fp.Value().SetVisible(False)
    if ref in LCSC:
        fp.SetField("LCSC", LCSC[ref])
        f = fp.GetField("LCSC")
        f.SetVisible(False)
        f.SetLayer(pcbnew.F_Fab)
    board.Add(fp)
    fps[ref] = fp
    return fp


# コネクタ: ケーブルの出る向き (嵌合口 = ローカル +Y) を基板の外側に向ける
#   J1 左辺 → 270 度、J2 右辺 → 90 度、J3 下辺 → 0 度
add_fp("J1", LOCAL_FP, "HY2.0-4P-WT_SMD-RA", 6.0, 7.0, 270)
add_fp("J2", LOCAL_FP, "HY2.0-4P-WT_SMD-RA", W - 6.0, 7.0, 90)
add_fp("J3", LOCAL_FP, "HY2.0-4P-WT_SMD-RA", 19.15, H - 6.0, 0)
# U1: ローカル 0 度だとピン 1 が右下。180 度で VIN を左上 (J1 側) に向ける
add_fp("U1", LOCAL_FP, "SOT-23-6_TPS22918DBVR", 17.5, 8.95, 180)
C = STD_FP / "Capacitor_SMD.pretty"
R = STD_FP / "Resistor_SMD.pretty"
add_fp("C1", C, "C_0603_1608Metric", 14.6, 6.275, 90)   # パッド 1 (V3V3_IN) が下、パッド 2 (GND) が上
add_fp("R1", R, "R_0603_1608Metric", 15.325, 12.3, 180)  # パッド 1 (LTE_EN) が右、パッド 2 (GND) が左
add_fp("C2", C, "C_0603_1608Metric", 18.85, 12.5, 270) # パッド 1 (CT) 上、パッド 2 (GND) 下
add_fp("R2", R, "R_0603_1608Metric", 20.4, 8.125, 90)    # パッド 1 (QOD) 下、パッド 2 (VLTE) 上
add_fp("C3", C, "C_0603_1608Metric", 21.0, 3.975, 90)    # パッド 1 (VLTE) が下、パッド 2 (GND) が上
TP = STD_FP / "TestPoint.pretty"
add_fp("TP1", TP, "TestPoint_Pad_D1.5mm", 14.0, 10.3, 0)
add_fp("TP2", TP, "TestPoint_Pad_D1.5mm", 24.0, 8.0, 0)
add_fp("TP3", TP, "TestPoint_Pad_D1.5mm", 16.15, 14.7, 0)
add_fp("TP4", TP, "TestPoint_Pad_D1.5mm", 9.0, 21.5, 0)
HOLE = STD_FP / "MountingHole.pretty"
add_fp("H1", HOLE, "MountingHole_2.2mm_M2", 3.5, 25.0, 0)
add_fp("H2", HOLE, "MountingHole_2.2mm_M2", W - 3.5, 25.0, 0)

for r in ("R2", "C3"):
    fps[r].SetDNP(True) if hasattr(fps[r], "SetDNP") else None


def pad_pos(ref, num):
    for p in fps[ref].Pads():
        if p.GetNumber() == num:
            v = p.GetPosition()
            return (pcbnew.ToMM(v.x) - OX, pcbnew.ToMM(v.y) - OY)
    raise KeyError((ref, num))


# ------------------------------------------------------------ 配線
def track(netname, pts, width, layer=F_CU):
    for a, b in zip(pts[:-1], pts[1:]):
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(P(*a))
        t.SetEnd(P(*b))
        t.SetWidth(FromMM(width))
        t.SetLayer(layer)
        t.SetNet(net(netname))
        board.Add(t)


def via(netname, x, y, dia=0.6, drill=0.3):
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(P(x, y))
    v.SetWidth(FromMM(dia))
    v.SetDrill(FromMM(drill))
    v.SetViaType(pcbnew.VIATYPE_THROUGH)
    v.SetLayerPair(F_CU, B_CU)
    v.SetNet(net(netname))
    board.Add(v)


SIG, PWR, LNK = 0.25, 0.5, 0.4

if __name__ == "__main__":
    exec(open(ROOT / "scripts" / "pcb_routes.py").read())
