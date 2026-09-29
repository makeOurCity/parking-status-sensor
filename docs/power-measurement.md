# 消費電力実測（Issue #31）

LiPo 運用時の **mAh / サイクル** を電流計で測り、README §6.2 の試算を実測ベースで更新する。

- 関連: #25（低消費電力運用）、#6
- LTE active 時間の調査（完了）: [lte-active-investigation.md](lte-active-investigation.md)
- 正（試算）: [README.md §6.2](../README.md#62-消費電力連続稼働の試算)

---

## 1. 背景

バッテリーチェッカーでは短時間試験で 80% / 4.00V 前後がほぼ不変に見え、以下が分からない。

| 分からないこと | #25 への影響 |
|---|---|
| 1 サイクルあたり何 mAh か | 起床間隔・変化時のみ送信の試算根拠がない |
| Deep Sleep 中の実電流 | スリープ設計の優先度が判断できない |
| LTE-M 通信中のピーク・平均 | README §6.2 試算との突合 |
| Grove 5V / LTE モジュールのスリープ漏れ | 青 LED 点滅時の漏れ電流 |

ファームの `power.activeMsBeforePublish` は active 時間の目安になるが、**mAh は U200-1A で測る**。

---

## 2. 測定手段

### 2.0 採用品（注文済み）

| 項目 | 内容 |
|---|---|
| 品名 | **M5Stack INA226 電流電圧測定ユニット（絶縁型・±1A）** |
| 型番 | **M5STACK-U200-1A** |
| 注文日 | 2026-07-07 |

±1A 版（分解能 32 µA）。Deep Sleep の spot check は手持ちテスター併用。

### 2.1 配線（U200-1A 端子台）

M5 公式: **IN 端（IN+/IN-）に電源、OUT 端（OUT+/OUT-）に負荷**。

```
[LiPo (+)] ──→ IN+
[LiPo (-)] ──→ IN-

OUT+ ──→ [Grove Shield BAT+]
OUT- ──→ [Grove Shield BAT-]
```

| 注意 | 内容 |
|---|---|
| 並列給電禁止 | 計測中は試験対象機（XIAO）の **USB を外す** |
| 極性 | 端子シルクどおり。逆接続はユニット損傷の恐れ |
| ロガー給電 | ESP32 DevKit は **USB 給電**（試験対象機と電源分離） |

### 2.2 ロガー（ESP32 DevKit + OLED）

実装: [tools/power-logger/README.md](../tools/power-logger/README.md)

| 項目 | 内容 |
|---|---|
| MCU | ESP32 DevKit（GPIO21=SDA, GPIO22=SCL） |
| I2C | U200-1A @ `0x41` + SSD1306 OLED @ `0x3C`（共有バス） |
| サンプリング | 15 Hz（通常モード）。**高速モード（`logger-devkit-fast`、#74/#75）**は電圧を約 0.46 ms 間隔で読み、50 ms ごとに最低電圧・最大電流を出力する。LTE の送信時など ms 単位の電圧低下を見るときは高速モードを使う |
| Serial | CSV: `ms,current_mA,bus_mV,power_mW` |
| OLED | 電流・電圧・電力・セッション mAh・ピーク（ライブ表示） |
| 積算 | ホスト `integrate_mah.py` または OLED 上の目安 |

到着当日: ロガー単体確認 → 既知負荷で spot check → パターン B → D の順。

### 2.3 記録指標

| 指標 | 用途 |
|---|---|
| 平均電流（mA） | Deep Sleep / active 各フェーズ |
| 積算 mAh（1 サイクル） | README §6.2 更新 |
| ピーク電流（mA） | LTE 送信・昇圧回路 |
| バッテリーチェッカー | 長期トレンドの補助のみ |

**電圧を測るときの注意（#74）:**

- **バッテリーチェッカー（Capacity Controller）**で 1S の LiPo を測るときは、**NiCd/NiMH 側の差し込み口**に差す。Li-ion 2S〜7S 側に差すと正しく測れない（電池 #1 で 0.33V 高く表示された）。電圧の基準はテスターにする
- U200-1A の `bus_mV` は OUT 側（デバイスが受け取る電圧）で、テスターの値と一致することを確認済み（差は 20mV 以内）
- **電池には個体番号を付けて**、記録に番号を添える

`disconnectTransport` / `poweroff` はファーム未計測。波形上の publish 後〜スリープまでを U200-1A で切り出す。

---

## 3. 実測パターン（チェックリスト）

| # | パターン | ビルド / 設定 | 目的 |
|---|---|---|---|
| A | Deep Sleep のみ | 通信なし | スリープ底電流 |
| B | 起床 → センサ → 即 Sleep | Wi-Fi/LTE 無効 | センサ + MCU active のみ |
| C | Wi-Fi + ローカル MQTT 1 回 | `xiao-s3` | Wi-Fi baseline |
| D | LTE-M + AWS 1 回 | `xiao-s3-aws-lte`（モデム TLS） | 現行 PoC 経路 |
| E | LTE active 120秒超 | 一晩試験再現 | boot 43 型（#32 Fix B 後に要否判断） |
| F | スリープ中・青 LED 点滅 | `modem.poweroff()` 後 | Grove 5V 漏れ |

各パターン:

- [ ] 波形 CSV
- [ ] 1 サイクル mAh
- [ ] 対応する MQTT `power.*` / `network.*`（あれば）
- [ ] 備考（CSQ、bootCount）

---

## 6. 実測結果（2026-07-10）

ロガー: [tools/power-logger/](../tools/power-logger/)（DevKit + U200-1A + OLED）。  
試験対象機: `xiao-e83dc1fb05fc`、`xiao-s3-aws-lte`、LiPo → U200 IN/OUT → Grove Shield BAT（USB 非接続）。

### 6.1 パターン D（現行 PoC 経路）

| 項目 | 値 |
|---|---|
| 記録時間 | 371 s（`integrate_mah.py`: 5970 rows） |
| 区間積算 | **3.00 mAh**（boot 1 + 2 を含む） |
| 区間平均電流 | **29.1 mA** |
| CloudWatch 受信 | boot **1**（`power_on`, active **14.9 s**）→ **307 s 後** → boot **2**（`timer`, active **6.2 s**） |
| 定常 active | **≈6 s**（#30 改善どおり） |
| 定常 1 サイクル mAh（概算） | **≈2.0〜2.1 mAh**（active ≈0.2 mAh + スリープ ≈1.8 mAh） |
| スリープ中ベースライン（概算） | **≈22 mA**（ESP32 Deep Sleep 単体では説明不可） |

### 6.2 所見（#25 へ引き渡し）

| 観測 | 解釈 |
|---|---|
| LTE-M 青 LED が **3 秒おきに点滅** | `modem.poweroff()` 後も **Grove 5V 供給継続**。モデム完全停止ではない |
| カラーセンサ **白 LED 常時点灯** | **VEML6040 shutdown 未実装**（`sensor.cpp` は常時 `SD_ENABLE`） |
| スリープ時間の大半が **≈22 mA** | 試算（Deep Sleep µA 級）より **桁違いに重い**。主因は周辺電源 |

LiPo 実効 **3,960 mAh**・定常 **≈2.1 mAh/サイクル**・受信 **≈5 分弱** の暫定試算 → 連続稼働 **約 7 日**（README §6.2 更新済み）。

**#25 Phase 0（2026-07-10）で内訳確定:** 待機 ≈22 mA のほぼ全量は LTE-M（+21〜28 mA）。`poweroff()` 成功応答後も NETLIGHT 点滅・mA 級待機は継続。結論は [25-low-power-mode.md](25-low-power-mode.md)。

### 6.3 チェックリスト（パターン D）

- [x] 波形 CSV
- [x] 1 サイクル mAh（定常は概算。boot 3 以降の単独 CSV は #25 施策後に再計測可）
- [x] MQTT `power.*` / `network.*`（boot 1・2）
- [x] 備考: 青/白 LED 常時、Grove 5V 未切断

パターン A / B / C / F / E は **#31 スコープ外**（#25 施策の Before/After 再計測でよい）。

---

## 4. 次のアクション

| 優先 | タスク | 状態 |
|---|---|---|
| 1 | U200-1A 到着・配線・ロガー動作確認 | 済 |
| 2 | ロガー（DevKit + INA226 + OLED） | 済（`tools/power-logger/`） |
| 3 | パターン D 実測 | 済（§6） |
| 4 | README §6.2 試算更新 | 済 |
| 5 | #25 Phase 0（内訳・poweroff） | **済** — [25-low-power-mode.md](25-low-power-mode.md) |

## 5. 完了条件（Issue #31）

- [x] 電流計・ロガーの選定と配線方針が決まっている
- [x] 1 サイクルあたりの mAh を測れる
- [x] パターン D の結果が README §6.2 更新に使える
- [x] #25 の低消費電力設計を再開できる（mAh 実測後）

---

## 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-07-07 | 初版（LTE 調査と同居） |
| 2026-07-07 | LTE 調査を [lte-active-investigation.md](lte-active-investigation.md) に分離。本稿は mAh 実測専用に |
| 2026-07-10 | U200 配線を IN/OUT 4 端子版に修正。ロガーを DevKit + OLED（`tools/power-logger/`）に |
| 2026-07-10 | パターン D 実測（§6）。#31 完了・#25 へ引き渡し |
| 2026-07-10 | #25 Phase 0 完了。内訳・結論は [25-low-power-mode.md](25-low-power-mode.md) |
