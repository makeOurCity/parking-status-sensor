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

### 2.1 配線

```
[LiPo +] ──→ [U200-1A IN+] ──→ [U200-1A IN-] ──→ [Grove Shield BAT+]
[LiPo -] ──────────────────────────────────────→ [Grove Shield BAT-]

[ロガー XIAO]  SDA/SCL → U200-1A（I2C 0x41）
```

| 注意 | 内容 |
|---|---|
| 並列給電禁止 | 計測中は DUT の **USB を外す** |
| ロガー給電 | 予備 XIAO は **USB 給電**（DUT と電源分離） |

### 2.2 ロガー（到着後）

| 項目 | 方針 |
|---|---|
| サンプリング | 10〜20 Hz |
| 出力 | Serial CSV: `ms,current_mA,bus_mV,power_mW` |
| 積算 | ホストで `Σ(current × Δt)` → mAh |
| 同期 | CloudWatch の `bootCount`・`activeMsBeforePublish` と突合 |

到着当日: ロガー単体確認 → 既知負荷で spot check → パターン B → D の順。

### 2.3 記録指標

| 指標 | 用途 |
|---|---|
| 平均電流（mA） | Deep Sleep / active 各フェーズ |
| 積算 mAh（1 サイクル） | README §6.2 更新 |
| ピーク電流（mA） | LTE 送信・昇圧回路 |
| バッテリーチェッカー | 長期トレンドの補助のみ |

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

## 4. 次のアクション

| 優先 | タスク | 状態 |
|---|---|---|
| 1 | U200-1A 到着・配線・ロガー動作確認 | 到着待ち |
| 2 | ロガー用スケッチ（INA226 CSV） | 未 |
| 3 | パターン B → D を 1 サイクルずつ | 未 |
| 4 | パターン A / F（テスター併用） | 未 |
| 5 | README §6.2 / firmware README の mAh 試算更新 | 未 |

## 5. 完了条件（Issue #31）

- [x] 電流計・ロガーの選定と配線方針が決まっている
- [ ] 1 サイクルあたりの mAh を測れる
- [ ] パターン A〜D の結果が README §6.2 更新に使える
- [ ] #25 の低消費電力設計を再開できる（mAh 実測後）

---

## 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-07-07 | 初版（LTE 調査と同居） |
| 2026-07-07 | LTE 調査を [lte-active-investigation.md](lte-active-investigation.md) に分離。本稿は mAh 実測専用に |
