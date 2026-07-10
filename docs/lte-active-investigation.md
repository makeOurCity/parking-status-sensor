# LTE-M active 時間の調査と改善（2026-07-07）

LiPo + `xiao-s3-aws-lte` で観測された **active 約68秒** の原因切り分けと、ファームウェア改善の記録。

- 関連 Issue: #30（時刻同期）、#32（送信サイクル再設計・SyncLedger）、#35（SORACOM CLI）
- 実装 PR: `feature/30-lte-modem-tls`（モデム TLS + Fix A/C）
- 消費電力 mAh 実測: [power-measurement.md](power-measurement.md)（Issue #31）

---

## 1. 一晩通し試験の CloudWatch 分析

構成: LiPo → Grove Shield BAT、`xiao-s3-aws-lte`（TLS 8883 / QoS1）、SORACOM plan-D、AWS IoT Core。  
出典: CloudWatch Logs `/aws/lambda/parking-status-bridge`。生ログ 87 レコードを集計。

| 区間 | boot | 件数 | `transport` | `networkConnectMs` | `mqttConnectMs` | `activeMs`（中央値） |
|---|---|---|---|---|---|---|
| 起動直後（power_on 連発） | 1 ×約6回 | 9 | 一部 lte / 欠落 | 3.6〜12.9秒 | 34〜35秒 | 41〜111秒 |
| **フェーズ1（安定）** | 2〜42 | 41 | **lte（全件）** | **2474ms** | **約34.2秒** | **約68秒** |
| **フェーズ2** | 43〜75+ | 36 | **欠落** | — | — | **約128秒** |

観測事実:

- boot 43 で network メトリクス欠落が **100% 切替**
- フェーズ2の network は `flushOutbox` の 3 フィールドと一致
- `timestamp` は LTE 定常で全件 `null`（#30）
- 全件 `deliveryConfirmed: true`、boot 欠番なし

---

## 2. 処理時間の分解（コード + ログ）

### 2.1 サイクル概要

`activeMsBeforePublish` は **publish 確認（PUBACK）まで**。その後 `sleepNow()` → `disconnectTransport()`（`poweroff` 含む）はペイロードに含まれない。

### 2.2 改善前（約68秒）— NTP 空振り + ESP32 TLS

| 区間 | 値 | 根拠 |
|---|---|---|
| LTE attach | ~2.5 s | `networkConnectMs` |
| NTP 空振り ×2 | ~30 s | lwIP SNTP が LTE-only で経路なし |
| TLS + MQTT | ~34 s | `mqttConnectMs`（ESP32 SSLClient over UART） |
| その他 | ~2 s | センサー・publish 等 |

**active の約94%** が NTP 空振り + TLS。

### 2.3 boot 43 以降（約128秒）— outbox ラッチ劣化モード

1. 直接 publish の PUBACK 確認が失敗 → outbox に enqueue
2. 以降: flush 成功 + 直接 publish 失敗を毎サイクル反復 → active ≈ `PSS_CYCLE_MAX_ACTIVE_MS`（120秒）

→ 送信サイクル再設計（Outbox 廃止・SyncLedger）は Issue **#32** で追跡（[sync-delivery-design.md](sync-delivery-design.md)）。

### 2.4 `network.*` 欠落（Fix C・済）

`flushOutbox` の `.to<JsonObject>()` が既存 network を破棄していた。`.as<JsonObject>()` に修正済み。

### 2.5 disconnect / poweroff がファーム未計測の理由

切断・`poweroff` は `activeMsBeforePublish` の**後**。改善後は定常 active 約6秒のうち残り数秒以下の見込み。**U200-1A 波形で計測**（[power-measurement.md](power-measurement.md) パターン D）。

---

## 3. 設計評価と方針

### 2026-07-07（active 短縮）

| 案 | 判定 |
|---|---|
| 現行 + モデム TLS | **採用・継続**（通信パイプライン実証用） |
| SORACOM Beam / Funnel | 記録のみ・実測予定なし |
| Grove 5V ハード切断 | 見送り |

### 2026-07-10（#25 Phase 0 完了 — [25-low-power-mode.md](25-low-power-mode.md)）

| 案 | 判定 |
|---|---|
| LTE を電池 PoC のコア経路 | **見送り**（待機 ≈23 mA・Grove VCC 制御不可） |
| Grove 上での LTE poweroff ファーム修正 | 主戦場にしない（応答と実機消費が乖離） |
| LoRaWAN（Grove Wio-E5） | **次の評価対象**（モジュール到着済） |
| 専用基板 / LTE VCC 制御 | 要件は明確だが **優先度低** |

---

## 4. 改善実装と再計測

| 項目 | 内容 |
|---|---|
| **Fix A** | モデム `CCLK` / `CNTP`（#30） |
| **Fix C** | outbox 再送時の network 保持 |
| **モデム TLS** | `tcpTlsConnectMs` 約1.5秒（従来34秒） |
| **メトリクス** | `tcpTlsConnectMs`, `mqttHandshakeMs`, `publishMs` |

### 改善前後（定常）

| 指標 | 改善前 | 改善後 |
|---|---|---|
| `activeMsBeforePublish` | 約 **68秒** | 約 **6秒** |
| TLS + MQTT | 約 **34秒** | 約 **1.7秒** |
| `timestamp` | null | ISO8601 |
| 受信間隔（sleep 300秒） | 約 **8分** | 約 **5分弱** |

---

## 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-07-07 | 初版（旧 `power-measurement.md` から LTE 調査部分を分離） |
| 2026-07-10 | #25 Phase 0 完了に伴い §3 を更新（LTE PoC コア見送り・LoRaWAN 次評価） |
