# Issue #25 Phase 0 — 実機計測手順書（WIP）

**暫定・WIP** — ベンチ作業用。結果は [25-low-power-investigation.md](25-low-power-investigation.md) §7 に転記する。

## 目的（これだけ）

**待機 ≈22 mA（[#31 実測](power-measurement.md) §6）の内訳を機器別に数値化し、#25 の対策優先度を決める。**

付随して 1 点だけ: `modem.poweroff()` が実際に成立しているか（成立していなければ最有力の修正候補）。

## 確定済みの前提（Phase 0 で再確認しない)

| 事実 | 根拠 |
|---|---|
| 部品構成・動作（VEML6040 / LTE-M / MQTT） | BOM + PoC 動作実績 |
| Grove VCC = 3.3 V 直結・昇圧なし・ポート電源スイッチなし・Deep Sleep 中も給電 | [Shield SCH](datasheets/grove-shield-xiao-v1.0-sch.pdf) |
| VEML6040 に LED 駆動ピンなし → SD=1 でも基板白 LED は消えない見込み | [VEML6040 DS](datasheets/veml6040.pdf) |
| スリープ前に `AT+CPOWD=1` 送信、`NORMAL POWER DOWN` 応答待ち（戻り値は未チェック） | `firmware/src/transport.cpp` / TinyGSM |
| 正常 power-off 後の SIM7080G は ≤15 µA | SIMCom DS |

---

## 計測 1: 待機電流の内訳（U200 抜き差し・3 構成）

LiPo → U200 IN/OUT → Shield BAT。**XIAO USB は外す。** ファームは `xiao-s3-aws-lte`（#31 と同一）。

センサ未接続は `sensor-error`、LTE 未接続は `connect-failed` でどちらも Deep Sleep に到達する（`main.cpp` 確認済み）ので、抜いたままサイクルを回してよい。

各構成: 電源投入 → 1 サイクル完走 → **スリープ突入 30 s 後から 30 s 以上**の平均電流。

| # | 構成 | 待機電流 (mA) | 分かること |
|---|---|---|---|
| 1 | XIAO + Shield のみ | **1.60** | ベース（Shield PMIC 等） |
| 2 | #1 + センサ | **1.75** | センサ寄与 **≈+0.15**（白 LED 込み・待機では無視できる） |
| 3 | #2 + LTE（フル構成 = #31 再現） | **20〜30**（CSV 平均 **≈23.2 mA**） | LTE 寄与 **≈+21〜28**（#31 の ≈22 mA と整合） |

ログ: [tools/power-logger/capture-phase0-N.csv](../tools/power-logger/capture-phase0-N.csv)（3 構成を 1 本の CSV に連続記録。先頭はバッテリー逆接続の異常値 — 解析時は除外）

```bash
cd tools/power-logger
pio device monitor -e logger-devkit > capture-phase0-N.csv
python3 integrate_mah.py capture-phase0-N.csv   # 全区間。内訳は下記 §計測 1 結果参照
```

## 計測 1 結果（2026-07-10）

| 寄与 | 報告値 / CSV | 判定 |
|---|---|---|
| ベース（XIAO + Shield） | **1.60 mA**（CSV 平均 1.65） | Deep Sleep + Shield は mA 級で妥当 |
| センサ（+白 LED） | **1.75 mA**（+0.15） | **待機の主因ではない** |
| LTE-M | **20〜30 mA** 往復（CSV 平均 ≈23.2） | **支配的。≈22 mA のほぼ全て** |

**20〜30 mA の往復:** CSV では **≈21 mA** と **≈31 mA** の 2 水準が秒オーダーで切り替わる（15 Hz サンプル間に >5 mA のジャンプが多数）。#31 の青 NETLIGHT 3 s 点滅と整合し、**モデムが完全停止しておらず状態が 2 段ある**可能性が高い。待機平均として **≈23 mA** と見なしてよい。

**異常区間:** 先頭は逆接続で負電流 → 続いて **≈1 A** スパイク。その後 #1→#2→#3 と遷移。解析・報告とも先頭を除外する。

## 計測 2: poweroff 成否（フル構成）

計測 1（U200）とは **配線と給電を変える別セッション**。目的は 2 つだけ:

1. スリープ直前に `AT+CPOWD=1` → `NORMAL POWER DOWN` が出るか（Serial）
2. スリープ中、LTE モジュールの **青 NETLIGHT** が消灯するか / 点滅し続けるか（目視）

計測 1 で 20〜30 mA 往復が出ているなら、**点滅継続 = poweroff 未成立** の可能性が高い。Serial で裏取りする。

### なぜ U200 と同時にやらないか

- U200 経由だと XIAO の USB シリアルが使えない（または給電経路が混ざる）
- Serial は **スリープ直前の数秒**しか出ない（Deep Sleep 入るとログが止まる）

### 0. 構成

| 項目 | 設定 |
|---|---|
| 試験対象 | **フル構成**（XIAO + Shield + センサ + LTE）— 計測 1 の #3 と同じ |
| ファーム | `xiao-s3-aws-lte`（#31 / 計測 1 と同一） |
| 給電 | **XIAO の USB-C**（シリアル用）。LiPo は Shield BAT に挿したままでよい（USB と BAT 併用可） |
| U200 | **外す**（LiPo を U200 を介さず Shield BAT へ直結） |

### 1. 配線の切り替え（計測 1 からの手順）

1. ロガーの `pio device monitor` を **Ctrl+C** で止める
2. LiPo を U200 の OUT から外し、**Shield BAT パッドへ直結**（計測 1 と同じ極性。逆接続しない）
3. XIAO ESP32S3 に **USB-C ケーブル**を接続（Mac 側）
4. センサ・LTE の Grove ケーブルは **そのまま**（抜かない）

### 2. ファーム確認・書き込み（未実施なら）

```bash
cd firmware
pio run -e xiao-s3-aws-lte -t upload
```

`secrets.h` と証明書は計測 1 と同じでよい。

### 3-A. Serial ログ取得（`NORMAL POWER DOWN` 確認）

**AT トレースを出すため**、一時的に `TINY_GSM_DEBUG` を有効にしてビルドする（計測 2 用。終わったら戻してよい）。

`firmware/platformio.ini` の `[env:xiao-s3-aws-lte]` の `build_flags` 末尾に 1 行追加:

```ini
    -DTINY_GSM_DEBUG=Serial
```

再ビルド・書き込み:

```bash
cd firmware
pio run -e xiao-s3-aws-lte -t upload
```

**ログ保存しながらモニタ**（1 サイクル分で足りる）:

```bash
pio device monitor -e xiao-s3-aws-lte --port /dev/cu.usbmodem* | tee ../tools/power-logger/phase0-poweroff.log
```

`--port` は環境に合わせる（`pio device list` で確認）。

**操作手順:**

1. モニタを起動した状態で、XIAO の **リセットボタン**を 1 回押す（または USB 抜き差し）
2. **約 1 サイクル（active ≈6 s + スリープ直前）**を待つ — 計測 1 と同様 MQTT 送信まで進む
3. ログに `sleep reason=confirmed`（または `connect-failed` 等）が出たら、その **直後〜数秒**を重点確認
4. Deep Sleep に入ると **Serial は止まる**（正常）。次のログは約 300 s 後の起床まで来ない

**ログで探す文字列:**

| 文字列 | 意味 |
|---|---|
| `AT+CPOWD=1` | poweroff コマンド送信（`TINY_GSM_DEBUG` 有効時） |
| `NORMAL POWER DOWN` | **モデムが正常 power-off を応答** → poweroff 成立 |
| `sleep reason=confirmed` | スリープ処理開始（この後に `disconnectTransport()` → `poweroff()`） |
| `+CME ERROR` / 無応答 | poweroff 失敗の疑い |

`TINY_GSM_DEBUG` を足したくない場合は **3-B の NETLIGHT 目視のみ**でも Phase 0 は進められる（Serial 項目は「未確認」でよい）。

### 3-B. NETLIGHT 目視（スリープ中）

Serial で `sleep reason=...` を確認したら、**すぐに** M5 U128 本体の **青 LED（NETLIGHT）** を見る。Deep Sleep 中は XIAO が止まっているので、こちらが主証拠になる。

| 観察（スリープ中 30 s 以上） | 判定 |
|---|---|
| **消灯**（点滅なし） | poweroff **成立**（SIMCom: Power off / PSM 状態） |
| **約 3 秒周期で点滅** | U128 Unit が mA 級で動作継続（#31・計測 1 と整合） |
| 常時点灯 | 要調査（稀） |

暗い場所の方が見やすい。白 LED（センサ Fill-light）と混同しないよう **LTE モジュール本体の青 LED** を見る。

### 4. 記録テンプレ

```
日付:
ファーム: xiao-s3-aws-lte (+ TINY_GSM_DEBUG 有無)
Serial: NORMAL POWER DOWN → あり / なし / 未確認（ログ: phase0-poweroff.log / phase0-poweroff-test.log）
NETLIGHT（スリープ 30 s 後）: 消灯 / 3s点滅 / その他
判定: Grove PoC 継続可 / 専用基板検討
```

### 5. 判定 → Phase 2 への引き継ぎ

| Serial | NETLIGHT | Phase 2 第一候補 |
|---|---|---|
| `NORMAL POWER DOWN` **なし** | 点滅 | **poweroff の確実化**（戻り値チェック・リトライ・タイミング） |
| `NORMAL POWER DOWN` **あり** | 点滅 | Grove 構成では VCC 切断不可。**LTE を PoC コアに据えない**（[25-low-power-mode.md](25-low-power-mode.md)）。専用基板は優先度低 |
| あり/なし問わず | **消灯** | 待機電流がまだ高いなら **ESP 側以外の漏れ**を再計測（稀。計測 1 結果と突合） |

計測 1 で LTE 寄与が支配的なため、上表の上 2 行が現実的な分岐。

### チェックリスト

- [x] U200 を外し USB シリアルに切り替えた
- [x] フル構成で 1 サイクル以上完走した
- [x] `phase0-poweroff.log` を保存した
- [x] `phase0-poweroff-test.log` を保存した
- [x] `NORMAL POWER DOWN` の有無を記録した → 通常ファームでは無し、専用ファームでは **あり**
- [x] スリープ中 NETLIGHT を記録した → **3 s 点滅継続**（2026-07-10）

---

## 結果 → 対策の判定表

| 内訳の結果 | Phase 2 の第一候補 |
|---|---|
| LTE 寄与が支配的 + `NORMAL POWER DOWN` **なし** | poweroff の確実化（戻り値確認・リトライ・タイミング） |
| LTE 寄与が支配的 + poweroff **成立**（応答あり） | Grove 構成の限界。**LTE を電池 PoC の主経路にしない**（[25-low-power-mode.md](25-low-power-mode.md)） |
| センサ寄与が支配的 | Grove 構成の限界。専用基板 / センサ電源制御付き実装を検討（ただし今回の実測では +0.15 mA のため主因ではない） |
| ベース（#1）が支配的 | Shield / XIAO 側の調査（PMIC 待機電流・充電 LED 等） |

複数が同程度なら効果の大きい順に積む。**変化時のみ送信（mustPublish）は内訳と独立に有効**なので Phase 2 に含める。

## 完了条件

1. [x] 3 構成の待機電流が数値で埋まっている
2. [x] poweroff 後の実態が Serial + NETLIGHT で判定できている → **NORMAL POWER DOWN 応答あり / NETLIGHT 点滅継続**
3. [x] Phase 2 の優先順位が決まり、[25-low-power-investigation.md](25-low-power-investigation.md) §7 に転記済み

**Phase 0 完了（2026-07-10）** → 結論: [25-low-power-mode.md](25-low-power-mode.md)

## 二次調査（内訳判明後、必要になった場合のみ）

- V3 センサ回路図（Seeed CDN 403 — 手元 PDF or 基板写真で補完）・白 LED の駆動経路
- U128 回路図・NETLIGHT / 電源系
- 白 LED の満空灯読取への影響（#8 と共有）
