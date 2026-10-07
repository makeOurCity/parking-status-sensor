# LTE power switch（Issue #88）

**状態: 暫定・WIP（rev A、2026-10-05 に JLCPCB へ発注済み・実機未検証）。** M5 Unit CatM（LTE-M）の VCC 線を TI TPS22918DBVR で開閉する、Grove コネクタ 3 つの小基板。設計の背景は [../../docs/88-load-switch-design.md](../../docs/88-load-switch-design.md)。

| コネクタ | 向き | 内容 |
|---|---|---|
| J1 IN | 左辺 | Shield の UART Grove ポートから。pin1/pin2 は J2 へ直結、pin3 = 3V3（`V3V3_IN`）、pin4 = GND |
| J2 OUT | 右辺 | LTE-M ユニットへ。pin1/pin2 は J1 から直結、pin3 = スイッチ後（`VLTE`）、pin4 = GND |
| J3 CTRL | 下辺 | Shield の D0（GPIO1）から。pin1 = `LTE_EN`（HIGH で ON）、pin4 = GND、**pin2/pin3 は未接続**（5V ポートに誤挿入しても被害が出ないように） |

Grove の pin1 = 黄、pin2 = 白、pin3 = 赤、pin4 = 黒。基板は 38 × 28mm、2 層、1.6mm。部品はすべて表面（JLCPCB の片面実装）。

## 部品（JLCPCB、2026-10-05 に jlcpcb.com の部品検索で在庫と区分を確認）

| 参照 | 部品 | LCSC | 区分 | 在庫 |
|---|---|---|---|---|
| U1 | TPS22918DBVR（SOT-23-6） | C131941 | Extended | 12,774 |
| J1〜J3 | CAX HY2.0-4P-WT（SMD 直角） | C722729 | Extended | 2,954 |
| C1 | 1µF 50V X5R 0603 | C15849 | Basic | 7,179,042 |
| C2 | 1nF 50V X7R 0603（差し替え可、例: 2.2nF） | C1588 | Basic | 7,779,974 |
| R1 | 100kΩ 1% 0603（ON ピンのプルダウン、必須） | C25803 | Basic | 22,053,367 |
| R2 | 0603、**DNP**（QOD と VOUT の間。実装すると QOD 有効） | — | — | — |
| C3 | 10µF 10V X5R 0603、**DNP**（任意。C19702 が Basic） | C19702 | Basic | 10,364,993 |
| TP1〜TP4 | 1.5mm 円形パッド（V3V3_IN / VLTE / LTE_EN / GND）。実装しない | — | — | — |

## ファイル

- `lte-power-switch.kicad_pro` / `.kicad_sch` / `.kicad_pcb`: KiCad 10.0.6 のプロジェクト。`lte-power-switch.kicad_sym` と `lte-power-switch.pretty/` は TPS22918 の記号とフットプリント（LCSC/EasyEDA 由来のパッド寸法。`3dmodels/` も同じ出典）。
- `lte-power-switch-schematic.pdf`: 回路図。
- `renders/`: 表・裏の SVG と 3D 画像。
- `fabrication/`: `lte-power-switch-gerber.zip`（ガーバー + ドリル。注文用）、`lte-power-switch-bom.csv`、`lte-power-switch-cpl.csv`、`erc.rpt`、`drc.rpt`、`gerber/`（展開済み）。
- `scripts/`: 回路図・基板・製造データの生成スクリプト（`gen_lib.py` → `gen_sch.py` → `run_pcb.sh` → `make_fab.py` の順）。回路図と基板は手書きではなくスクリプトから生成している。KiCad で編集した場合、スクリプトを再実行すると上書きされる。

## 発注前に確認すること（発注済み。以下は届いたあとの確認にも使う）

1. **JLCPCB の注文画面の部品プレビューで、U1 と J1〜J3 の向きを確認する。** `fabrication/lte-power-switch-cpl.csv` の回転角は KiCad の値そのまま（補正なし）。フットプリントは LCSC/EasyEDA の公開ライブラリ由来なので補正が不要の可能性が高いが、自動では確認できていない。ずれていれば、注文画面で回転を直す。
2. **HY2.0-4P-WT が手元の Grove ケーブルと嵌合し、pin1 が黄線になるか。** データシートに pin1 の位置の記載はなく、フットプリントの pin1（嵌合口を手前にして左端）は EasyEDA の定義による。最初の 1 枚で、ケーブルを J1 に挿し、反対側の黄線と基板の pin1 パッド（三角マーク側）の導通を確認する。
3. パッドの寸法は LCSC のライブラリ由来で、データシート（外形の図のみ）では検証できていない。
