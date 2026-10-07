# gen_pcb.py から exec される。配線・外形・ゾーン・シルク・保存。
import math

# ---------------- V3V3_IN (電源 0.5mm)
track("/V3V3_IN", [(9.9, 8.0), (16.15, 8.0)], PWR)
track("/V3V3_IN", [(14.6, 7.05), (14.6, 8.0)], PWR)
track("/V3V3_IN", [(14.0, 8.0), (14.0, 10.3)], PWR)
# ---------------- VLTE (電源 0.5mm)
track("/VLTE", [(18.85, 8.0), (19.6, 8.0), (19.6, 7.3), (20.4, 7.3), (22.0, 7.3), (22.0, 6.0), (28.1, 6.0)], PWR)
track("/VLTE", [(21.0, 4.75), (21.0, 6.0), (22.0, 6.0)], PWR)
# ---------------- LTE_EN / QOD / CT
track("/LTE_EN", [(16.15, 18.1), (16.15, 9.9)], SIG)
track("/QOD", [(18.85, 8.95), (20.4, 8.95)], SIG)
track("/CT", [(18.85, 9.9), (18.85, 11.725)], SIG)
# ---------------- GND 取り出し (裏面ベタへ)
for (px, py), (vx, vy) in [((9.9, 10.0), (7.6, 10.0)),      # J1.4
                           ((14.6, 5.5), (14.6, 4.2)),       # C1.2
                           ((16.15, 8.95), (15.1, 8.95)),    # U1.2
                           ((14.5, 12.3), (14.5, 13.6)),     # R1.2
                           ((18.85, 13.275), (18.85, 14.2)), # C2.2
                           ((28.1, 4.0), (30.4, 4.0)),       # J2.4
                           ((22.15, 18.1), (22.15, 20.4)),   # J3.4
                           ((21.0, 3.2), (21.0, 2.0)),       # C3.2
                           ((9.0, 21.5), (9.0, 22.9))]:      # TP4
    track("GND", [(px, py), (vx, vy)], LNK)
    via("GND", vx, vy)
# ---------------- SIG1 : 表 → 裏(下をくぐる) → 表
track("/SIG1", [(9.9, 4.0), (13.6, 4.0)], SIG)
via("/SIG1", 13.6, 4.0)
track("/SIG1", [(13.6, 4.0), (13.6, 16.0), (25.2, 16.0), (25.2, 10.0)], SIG, B_CU)
via("/SIG1", 25.2, 10.0)
track("/SIG1", [(25.2, 10.0), (28.1, 10.0)], SIG)
# ---------------- SIG2
track("/SIG2", [(9.9, 6.0), (12.6, 6.0)], SIG)
via("/SIG2", 12.6, 6.0)
track("/SIG2", [(12.6, 6.0), (12.6, 15.0)], SIG, B_CU)
via("/SIG2", 12.6, 15.0)
track("/SIG2", [(12.6, 15.0), (14.6, 15.0)], SIG)          # SIG1 の裏面配線をまたぐ表面ジャンパ
via("/SIG2", 14.6, 15.0)
track("/SIG2", [(14.6, 15.0), (23.4, 15.0), (23.4, 8.0)], SIG, B_CU)
via("/SIG2", 23.4, 8.0)
track("/SIG2", [(23.4, 8.0), (28.1, 8.0)], SIG)

# ---------------- 外形 (角 R0.5)
r = 0.5
def seg(a, b):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(P(*a)); s.SetEnd(P(*b))
    s.SetLayer(pcbnew.Edge_Cuts); s.SetWidth(FromMM(0.1))
    board.Add(s)
def arc(c, start_deg):
    # 中心 c の 90 度円弧 (start_deg → +90)
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_ARC)
    a0, a1, am = [math.radians(start_deg + d) for d in (0, 90, 45)]
    st = (c[0] + r * math.cos(a0), c[1] + r * math.sin(a0))
    en = (c[0] + r * math.cos(a1), c[1] + r * math.sin(a1))
    md = (c[0] + r * math.cos(am), c[1] + r * math.sin(am))
    s.SetArcGeometry(P(*st), P(*md), P(*en))
    s.SetLayer(pcbnew.Edge_Cuts); s.SetWidth(FromMM(0.1))
    board.Add(s)
seg((r, 0), (W - r, 0)); seg((W, r), (W, H - r)); seg((W - r, H), (r, H)); seg((0, H - r), (0, r))
arc((r, r), 180); arc((W - r, r), 270); arc((W - r, H - r), 0); arc((r, H - r), 90)

# ---------------- GND ゾーン (裏面ベタ)
z = pcbnew.ZONE(board)
z.SetLayer(B_CU)
z.SetNet(net("GND"))
z.SetIsRuleArea(False)
ol = z.Outline(); ol.NewOutline()
for (x, y) in [(0, 0), (W, 0), (W, H), (0, H)]:
    ol.Append(FromMM(OX + x), FromMM(OY + y))
z.SetMinThickness(FromMM(0.25))
z.SetLocalClearance(FromMM(0.25))
z.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
z.SetThermalReliefGap(FromMM(0.3))
z.SetThermalReliefSpokeWidth(FromMM(0.4))
board.Add(z)

# ---------------- シルク
def txt(s, x, y, size=1.0, layer=pcbnew.F_SilkS, just=pcbnew.GR_TEXT_H_ALIGN_LEFT, rot=0, thick=0.15, mirror=False):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(s); t.SetPosition(P(x, y)); t.SetLayer(layer)
    t.SetTextSize(VECTOR2I(FromMM(size), FromMM(size)))
    t.SetTextThickness(FromMM(thick))
    t.SetHorizJustify(just)
    t.SetTextAngleDegrees(rot)
    if mirror:
        t.SetMirrored(True)
    board.Add(t)

C_ = pcbnew.GR_TEXT_H_ALIGN_CENTER
R_ = pcbnew.GR_TEXT_H_ALIGN_RIGHT
K1 = dict(size=1.0, thick=0.15)
# コネクタ名 (J1 は左下、J2 は右下、J3 は右)
for i_, s_ in enumerate(["J1 IN", "from Shield", "UART"]):
    txt(s_, 6.0, 14.4 + i_ * 1.4, just=C_, **K1)
for i_, s_ in enumerate(["J2 OUT", "to LTE-M"]):
    txt(s_, W - 6.0, 14.5 + i_ * 1.3, just=C_, **K1)
for i_, s_ in enumerate(["LTE power", "switch", "rev A #88"]):
    txt(s_, 31.6, 19.0 + i_ * 1.5, just=C_, **K1)
for i_, s_ in enumerate(["J3 CTRL", "(D0)"]):
    txt(s_, 8.6, 25.3 + i_ * 1.3, just=C_, **K1)
# テストポイント名
txt("3V3", 12.3, 10.3, rot=90, just=C_, **K1)
txt("VLTE", 24.0, 4.1, just=C_, **K1)
txt("EN", 14.7, 14.7, just=R_, **K1)
txt("GND", 9.0, 19.9, just=C_, **K1)
# 裏面: ピン割り当て (ミラー文字)
BS = pcbnew.B_SilkS
back_lines = ["1 yellow SIG1  2 white SIG2", "3 red VCC      4 black GND", "J1.3=3V3 in  J2.3=VLTE out",
              "J3: 1=LTE_EN  2,3=NC (no 5V)", "triangle on top side = pin1", "TP: 3V3 VLTE EN GND"]
for i_, s_ in enumerate(back_lines):
    txt(s_, 19.0, 18.0 + i_ * 1.6, layer=BS, just=C_, mirror=True, **K1)

# ---------------- 保存
ds.SetAuxOrigin(P(0, H))      # 製造用原点 = 基板左下 (CPL/ドリルの基準)
ds.SetGridOrigin(P(0, H))
filler = pcbnew.ZONE_FILLER(board)
filler.Fill(board.Zones())
out = ROOT / "lte-power-switch.kicad_pcb"
board.Save(str(out))
print("saved", out)
