# gen_pcb.py から exec される。配線・外形・ゾーン・シルク・保存。
import math

# rev B: コネクタの pad 番号を実物に合わせた (rev A は鏡像だった)。
#   J1 の物理的な並び (上から): GND(pin4) 3V3(pin3) SIG2(pin2) SIG1(pin1) → y = 4, 6, 8, 10
#   J2 の物理的な並び (上から): SIG1 SIG2 VLTE GND → y = 4, 6, 8, 10
#   J3 の物理的な並び (左から): GND NC NC LTE_EN → x = 16.15, 18.15, 20.15, 22.15
# ---------------- V3V3_IN (電源 0.5mm) : J1 の 2 番目のパッド → C1 → U1 / TP1
track("/V3V3_IN", [(9.9, 6.0), (12.4, 6.0), (12.4, 7.05), (14.6, 7.05)], PWR)
track("/V3V3_IN", [(14.6, 7.05), (14.6, 8.0)], PWR)
track("/V3V3_IN", [(14.0, 8.0), (16.15, 8.0)], PWR)
track("/V3V3_IN", [(14.0, 8.0), (14.0, 10.3)], PWR)
# ---------------- VLTE (電源 0.5mm) : U1 → J2 の 3 番目のパッド (TP2 は幹線の上)
track("/VLTE", [(18.85, 8.0), (19.6, 8.0), (19.6, 7.3), (20.4, 7.3), (22.0, 7.3), (22.0, 8.0), (28.1, 8.0)], PWR)
track("/VLTE", [(21.0, 4.75), (21.0, 6.0), (22.0, 6.0), (22.0, 7.3)], PWR)
# ---------------- LTE_EN / QOD / CT
track("/LTE_EN", [(22.15, 18.1), (22.15, 15.5), (16.15, 15.5), (16.15, 9.9)], SIG)
track("/QOD", [(18.85, 8.95), (20.4, 8.95)], SIG)
track("/CT", [(18.85, 9.9), (18.85, 11.725)], SIG)
# ---------------- GND 取り出し (裏面ベタへ)
for (px, py), (vx, vy) in [((9.9, 4.0), (7.6, 4.0)),        # J1 GND (pin4)
                           ((14.6, 5.5), (14.6, 4.2)),       # C1.2
                           ((16.15, 8.95), (15.1, 8.95)),    # U1.2
                           ((14.5, 12.3), (14.5, 13.6)),     # R1.2
                           ((18.85, 13.275), (18.85, 14.2)), # C2.2
                           ((28.1, 10.0), (30.4, 10.0)),     # J2 GND (pin4)
                           ((16.15, 18.1), (16.15, 20.4)),   # J3 GND (pin4)
                           ((21.0, 3.2), (21.0, 2.0)),       # C3.2
                           ((9.0, 21.5), (9.0, 22.9))]:      # TP4
    track("GND", [(px, py), (vx, vy)], LNK)
    via("GND", vx, vy)
# ---------------- SIG1 : J1 (y=10) → 裏面の外側の U 字 → J2 (y=4)
track("/SIG1", [(9.9, 10.0), (12.2, 10.0)], SIG)
via("/SIG1", 12.2, 10.0)
track("/SIG1", [(12.2, 10.0), (12.2, 16.0), (25.8, 16.0), (25.8, 4.0)], SIG, B_CU)
via("/SIG1", 25.8, 4.0)
track("/SIG1", [(25.8, 4.0), (28.1, 4.0)], SIG)
# ---------------- SIG2 : J1 (y=8) → 裏面の内側の U 字 → J2 (y=6)  (SIG1 の U 字の内側に入れ子で、交差しない)
track("/SIG2", [(9.9, 8.0), (13.0, 8.0)], SIG)
via("/SIG2", 13.0, 8.0)
track("/SIG2", [(13.0, 8.0), (13.0, 15.0), (24.6, 15.0), (24.6, 6.0)], SIG, B_CU)
via("/SIG2", 24.6, 6.0)
track("/SIG2", [(24.6, 6.0), (28.1, 6.0)], SIG)

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
for i_, s_ in enumerate(["LTE power", "switch", "rev B #88"]):
    txt(s_, 31.6, 19.0 + i_ * 1.5, just=C_, **K1)
for i_, s_ in enumerate(["J3 CTRL", "(D0)"]):
    txt(s_, 8.6, 24.0 + i_ * 1.2, just=C_, **K1)
# 三角 (J1: v / J2: ^ / J3: >) は GND (黒線) の端。コネクタごとの注記
K2 = dict(size=0.8, thick=0.12)
txt("tri=GND(black)", 6.0, 18.6, just=C_, **K2)
txt("tri=GND(black)", W - 6.0, 17.2, just=C_, **K2)
txt("tri=GND(black)", 8.0, 26.9, just=C_, **K2)
# テストポイント名
txt("VLTE", 24.0, 10.2, just=C_, **K1)
txt("EN", 14.7, 14.7, just=R_, **K1)
txt("GND", 8.0, 21.5, just=R_, **K1)
# 裏面: ピン割り当て (ミラー文字)
BS = pcbnew.B_SilkS
back_lines = ["from triangle: black red white yellow", "J1: GND 3V3  TX6(w) RX7(y)", "J2: GND VLTE RX(w)  TX(y)",
              "J3: GND NC NC LTE_EN(y,D0)", "J3 white=D1 shared w/ pot: keep NC", "TP: 3V3 VLTE EN GND"]
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
