# LTE power switch（Issue #88）

**状態: 暫定・WIP（rev A、2026-10-05 に JLCPCB へ発注済み、2026-10-12 に実機到着）。** **rev A は、Grove コネクタのピン番号が実物と鏡像のため、普通の Grove ケーブルでは使えない（下の「rev A の既知の不具合」）。** rev B で直す予定。 M5 Unit CatM（LTE-M）の VCC 線を TI TPS22918DBVR で開閉する、Grove コネクタ 3 つの小基板。設計の背景は [../../docs/88-load-switch-design.md](../../docs/88-load-switch-design.md)。

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

## rev A の既知の不具合（2026-10-12、実機で確認）

**J1・J2・J3 のコネクタ（HY2.0-4P-WT）の pad 番号が、実物と鏡像になっている。** Grove ケーブルを挿すと、▼（J2 は▲、J3 は▶）のマークに一番近いパッド（設計の pin1）に**黒（GND）**が来る。設計では、そこは pin1 = 黄（SIG1）。

| 位置（三角に近い順） | 設計（回路図・基板） | 実際にそこへ来る Grove ケーブルの線 |
|---|---|---|
| 1 番目（三角のパッド） | pin1 = SIG1（黄） | 黒（GND） |
| 2 番目 | pin2 = SIG2（白） | 赤（VCC） |
| 3 番目 | pin3 = 3V3 / VLTE（赤） | 白 |
| 4 番目 | pin4 = GND（黒） | 黄 |

- 回路図（論理）は正しい。誤りは、フットプリントの pad 番号（pad「1」を、実物の pin1 と逆の端に置いた）。
- 原因: 下の「発注前に確認すること」2 を、実物で確認しないまま発注した。
- 影響: 普通の Grove ケーブルを J1・J2 につなぐと、Shield の VCC と GND が信号線のパッドにつながる。**rev A を、普通のケーブルで Shield に挿さないこと。**
- rev A の使い方（検証のみ）: ケーブルの片側を切って、テストポイント（`3V3` / `GND` / `EN` / `VLTE`）に直結する。
- 直し方（rev B）: フットプリントの pad 番号を逆にする（1↔4、2↔3）。回路図は変えない。基板のコネクタまわりの配線は、引き直しになる。

**rev A の動作確認（テストポイント直結、2026-10-12）:** Shield の 3.3V を `3V3` TP に入れ、`EN` を `3V3` につなぐと、`VLTE` が 3.3V になった。外すと、1 秒以内に 0V に戻った（負荷なし、QOD 開放）。U1 の向きは正しい。

**LTE-M・実機ファームでの確認（2026-10-12）:** 逆結線の専用ケーブルで、Shield・U128 につなぎ、ブートモードの送信 2/5〜5/5（LTE-M の接続、MQTT）が、途中でリセットされずに完了した。OFF のときの `VLTE` は、UART が動いている間は約 0.76V（旧リレー方式と同程度）、Deep Sleep では、20〜30 秒で 0V になった。回路の変更は、要らない見込み。電圧降下、突入電流の波形、Deep Sleep の待機電流は、未確認（[docs/88-load-switch-design.md](../../docs/88-load-switch-design.md) §8）。

## rev B の方針（案）

**回路図（論理）は変えない。** フットプリントの pad 番号を逆にし（1↔4、2↔3）、コネクタまわりの配線を引き直す。U1 まわり（LTE_EN・QOD・CT、C1・C2・R1）は変えない。

**物理的なパッド順（▼・▲・▶のパッドから順）と、印字**

| 位置 | J1（IN、Shield の UART へ） | J2（OUT、LTE-M へ） | J3（CTRL、Shield の D0 へ） |
|---|---|---|---|
| 1（三角のパッド） | GND（黒） | GND（黒） | GND（黒） |
| 2 | 3V3（赤） | VLTE（赤） | NC（赤。3V3 は未接続） |
| 3 | TX-6（白） | RX（白。モジュールの RX） | NC（白。D1 は未接続） |
| 4 | RX-7（黄） | TX（黄。モジュールの TX） | LTE_EN / D0（黄） |

- 三角は、**GND 側の端**に付ける（Shield の Grove ポートは、GND が端、その隣が 3V3）。「pin1」とは呼ばない。各パッドの横に、機能名とケーブルの色を印字する。
- J1 と J2 の信号線は、ケーブルがまっすぐなので、同じ位置にある。J1 は XIAO から見た名前（TX-6・RX-7）、J2 はモジュールから見た名前。
- **J3 の白（D1）は、NC のままにする。** Shield の右上ポート（D0・D1）の白線は、右下ポート（ポテンショメーター、D1・D2）の黄線と、同じ D1 の線。つなぐと、ポテンショメーターの信号に干渉する。赤（3V3）も、誤挿入しても何も入らないよう、未接続のまま。

**Shield（Grove Shield for XIAO）のポートの印字（2026-10-12、写真で確認。左から 1 番目〜4 番目 = 黄・白・赤・黒）**

| ポート | 黄 | 白 | 赤 | 黒 | 用途 |
|---|---|---|---|---|---|
| 左上（I2C） | SCL-5 | SDA-4 | 3V3 | GND | カラーセンサー |
| 左下（UART） | RX-7 | TX-6 | 3V3 | GND | J1 |
| 右上 | D0 | D1 | 3V3 | GND | J3 |
| 右下 | D1 | D2 | 3V3 | GND | ポテンショメーター |

- 左下の「RX」「TX」は、写真では頭文字が切れていて、ファームの定義（D7 = RX、D6 = TX）からの推定。

## 発注前に確認すること（rev A 発注時の項目。rev B でも使う）

1. **JLCPCB の注文画面の部品プレビューで、U1 と J1〜J3 の向きを確認する。** `fabrication/lte-power-switch-cpl.csv` の回転角は KiCad の値そのまま（補正なし）。フットプリントは LCSC/EasyEDA の公開ライブラリ由来なので補正が不要の可能性が高いが、自動では確認できていない。ずれていれば、注文画面で回転を直す。
2. **HY2.0-4P-WT が手元の Grove ケーブルと嵌合し、pin1 が黄線になるか。（rev A では、未確認のまま発注し、鏡像だった。rev B では、実物のコネクタにケーブルを挿して確認してから発注する。）** データシートに pin1 の位置の記載はなく、フットプリントの pin1（嵌合口を手前にして左端）は EasyEDA の定義による。最初の 1 枚で、ケーブルを J1 に挿し、反対側の黄線と基板の pin1 パッド（三角マーク側）の導通を確認する。
3. パッドの寸法は LCSC のライブラリ由来で、データシート（外形の図のみ）では検証できていない。
