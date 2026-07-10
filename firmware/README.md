# ファームウェア

XIAO ESP32S3 向けファームウェア（PlatformIO）。Grove - I2C Color Sensor V3.0（VEML6040）から満空灯の色を読み取り、AWS IoT Core へ MQTT 送信する。

ロードマップ: [Issue #22](https://github.com/makeOurCity/parking-status-sensor/issues/22)

## 対象ボード

| ボード | PlatformIO 環境 | 用途 |
|---|---|---|
| Seeed XIAO ESP32S3 | `xiao-s3` | **PoC 試作機**（LiPo・Deep Sleep・現場設置） |

- 配線の正: [docs/wiring.md](../docs/wiring.md)
- DevKit 検証は 2026-07 完了。[devkit-bench.md](devkit-bench.md) はアーカイブ

### センサモジュール

**Grove - I2C Color Sensor V3.0**（VEML6040、I2C `0x10`）。Grove Shield の I2C ポートにケーブル1本で接続。

## モジュール構成

Issue ごとに層を分け、単体検証しながら積み上げる。

```
firmware/
├── platformio.ini
├── include/
│   ├── board.h          # board_xiao.h を include
│   ├── board_xiao.h     # XIAO 用ピン定義（docs/wiring.md に準拠）
│   └── sensor.h         # RawSample / initSensor / readSensor
├── src/
│   ├── main.cpp         # ライフサイクル（setup / loop）
│   └── sensor.cpp       # VEML6040 ドライバ（#5）
└── README.md
```

| モジュール | 責務 | Issue |
|---|---|---|
| `sensor` | VEML6040 初期化・R/G/B/W 読み取り | #5 |
| `classify` | R−G 差による満/空/不明判定 | #6 |
| `transport` | MQTT 送信（Wi-Fi / LTE-M / LoRaWAN） | #6 以降 |
| `config` | NVS 設定（threshold、送信間隔、transport_mode） | #6 以降 |
| `provision` | 初回セットアップ・通信モジュール検出 | 将来 |

### 通常運用フロー（#6 以降）

```
起床 → sensor.read() → classify() → transport.publish() → Deep Sleep
```

- **色判定**は Deep Sleep 起床のたびに実行する
- **通信経路の選択**は毎サイクル行わない。プロビジョニング時に決定し NVS に保存する

### 通信経路の優先順位（将来）

接続されている通信モジュールをプロビジョニング時に検出し、NVS に保存する。

1. LoRaWAN モジュールが応答 → LoRaWAN
2. なければ LTE-M モジュールが応答 → LTE-M
3. どちらもなければ → Wi-Fi（内蔵）

PoC 第1弾（#6）は **Wi-Fi 固定**。モジュール検出・プロビジョニング UI は将来フェーズ。

### 電源・周辺モジュール（#6）

`esp_deep_sleep()` が止めるのは **ESP32 本体**（CPU / Wi-Fi）のみ。Grove Shield の Grove ポート電源は PoC 構成では **自動では落ちない**。

| 周辺 | Deep Sleep 中の電源 | #6 での扱い |
|---|---|---|
| ESP32 | スリープ（〜数十 µA） | 実装済み |
| Wi-Fi | オフ（`WiFi.mode(OFF)`） | 実装済み |
| カラーセンサ | Grove 3.3V はオン | **スリープ前に VEML6040 IC シャットダウン**（未実装・#6 で追加） |
| LTE-M | Grove 5V はオン | **`modem.poweroff()` でソフト停止**（5V は切れない）。スリープ中も青 LED が点滅する場合は完全停止していない疑い — 実測で確認（README §6.2） |

**PoC 第1弾（Wi-Fi + LiPo）の運用ルール**

- LTE-M（Grove UART）は **未接続のまま** Wi-Fi 検証・数日蓄積を行う（常時給電のアイドル消費を避ける）
- LTE 単体確認は `xiao-s3-lte-test` で別途実施
- 5V のハード電源スイッチ・NVS による transport 固定は **#6 スコープ外**（将来）

詳細・経緯: [Issue #6 コメント](https://github.com/makeOurCity/parking-status-sensor/issues/6)

## 配線（XIAO 実証機）

[docs/wiring.md](../docs/wiring.md) を参照。

- XIAO + **Grove Shield for XIAO**
- I2C: Shield の Grove ポート（D4=SDA, D5=SCL）
- センサ: Grove Color Sensor V3.0（ピン入替不要）
- 電源: LiPo → Shield BAT パッド（JST）

## ビルド・書き込み

端末ごとの Wi-Fi / MQTT / LTE-M 設定は `include/secrets.example.h` を
`include/secrets.h` にコピーして編集する。`secrets.h` は git 管理しない。

```bash
cd firmware

pio run -e xiao-s3 -t upload
pio device monitor -e xiao-s3
```

開発中に Deep Sleep させず、数秒間隔でローカル MQTT へ送信する場合:

```bash
pio run -e xiao-s3-debug -t upload
pio device monitor -e xiao-s3-debug
```

LTE-M モジュールだけを動作確認する場合（センサ・MQTT は使わない）:

```bash
pio run -e xiao-s3-lte-test -t upload
pio device monitor -e xiao-s3-lte-test
```

**モデム poweroff / 復帰だけを検証する場合**（#25。MQTT・Deep Sleep なし）:

```bash
pio run -e xiao-s3-lte-poweroff-test -t upload
pio device monitor -e xiao-s3-lte-poweroff-test | tee ../tools/power-logger/phase0-poweroff-test.log
```

奇数サイクル: 強化 CPOWD（`CNACT/CGATT` 切断 → `AT+CPOWD=1` → post-check）。  
偶数サイクル: `CFUN=0` のみ（比較用）。

**2026-07-10 実機:** `modemSilent=yes` でも **NETLIGHT 消灯せず**、U200 **50〜120 mA** — UART 停止 ≠ 低消費電力。詳細は [25-low-power-mode.md](../docs/25-low-power-mode.md) §1.4。

シリアルに `modem init` → `network registration` → `data attach` の 4 段階が出る。
`RESULT: PASS` なら UART・SIM・電波・APN まで通っている。

- `FAIL: no AT response` … Grove UART ケーブル、モジュール電源、TX/RX
- `FAIL: not registered` … SIM、アンテナ、電波
- `FAIL: GPRS attach failed` … APN（SORACOM: `soracom.io` / `sora` / `sora`）

SIM 側のステータス・セッション状態は [SORACOM CLI](../tools/soracom/README.md) で確認できる（#35）。
例: `tools/soracom/sim-status.sh <sim-id>`、セッション詰まり時は `delete-session.sh`。

## ローカル Mosquitto 検証（#6）

Mac 上でブローカーを立てる手順は `tools/mosquitto/` を参照。

```bash
# ターミナル1: ブローカー起動
tools/mosquitto/start.sh

# ターミナル2: 受信ログ（JSONL に蓄積）
tools/mosquitto/subscribe.sh 192.168.0.42
```

`secrets.h` の `PSS_MQTT_HOST` は **Mosquitto を動かす Mac の LAN IP**（例: `192.168.0.42`）。
`PSS_WIFI_SSID` が空でなければ Wi-Fi を優先する。Wi-Fi が未設定または失敗し、
`PSS_LTE_ENABLED=1` の場合だけ LTE-M にフォールバックする。

受信例:

```
mosquitto_sub -h 192.168.0.42 -t 'parking-status/#' -F '%I %t %p'
```

- `W` は VEML6040 の White チャンネル（MQTT ペイロードの `raw.clear` に対応）
- `R-G` は赤/緑分離の目安（完了基準: 差 ≥ 100）
- MQTT ペイロードには電流値そのものではなく、`power.activeMsBeforePublish`、
  `network.networkConnectMs`、`network.mqttConnectMs`、`power.sleepSeconds` を含める。
  USB 電流計や電源ロガーの実測値と突き合わせて消費電力を評価する。

## AWS IoT Core 切り替え（#6 → #27）

証明書が `firmware/certs/` に作成済みであれば、同じ全件送信ファームを
AWS IoT Core 向けにビルドできる。

必要な証明書ファイル:

- `certs/AmazonRootCA1.pem`
- `certs/device.pem.crt`
- `certs/private.pem.key`

`include/secrets.h` の MQTT 設定を AWS IoT Core 向けに変更する。

```cpp
#define PSS_MQTT_HOST "xxxxxxxxxxxxxx-ats.iot.ap-northeast-1.amazonaws.com"
#define PSS_MQTT_PORT 8883
#define PSS_MQTT_USE_TLS 1
#define PSS_MQTT_BASIC_INGEST_RULE "parking_status_telemetry"
#define PSS_MQTT_TOPIC ""
```

Basic Ingest を使わない場合は、通常トピック
`parking-status/xiao-e83dc1fb05fc/telemetry` を指定する。

```bash
cd firmware
pio run -e xiao-s3-aws -t upload
pio device monitor -e xiao-s3-aws
```

AWS 接続も現時点では **全件送信** のまま行う。変化時のみ送信・heartbeat は
24h ローカル検証後の次ステップとして扱う。

### LTE-M + AWS IoT Core（推奨 PoC 経路）

Grove UART に LTE-M モジュール（SIM7080G）を接続し、SORACOM SIM で AWS IoT Core へ
MQTT over TLS する。Wi-Fi は使わない。

`secrets.h` 例:

```cpp
#define PSS_WIFI_SSID ""
#define PSS_WIFI_PASSWORD ""
#define PSS_LTE_ENABLED 1
#define PSS_LTE_ONLY 1
#define PSS_MQTT_HOST "xxxxxxxxxxxxxx-ats.iot.ap-northeast-1.amazonaws.com"
#define PSS_MQTT_PORT 8883
#define PSS_MQTT_BASIC_INGEST_RULE "parking_status_telemetry"
```

```bash
cd firmware
# 開発中（Deep Sleep なし・AT ログあり）
pio run -e xiao-s3-aws-lte-debug -t upload
pio device monitor -e xiao-s3-aws-lte-debug

# 本番運用（Deep Sleep あり）
pio run -e xiao-s3-aws-lte -t upload
```

TLS は **SIM7080 モデム内蔵 TLS**（`GsmClientSecureSIM7080` + mTLS）で AWS IoT Core へ接続する。
証明書は初回にモデム FS へアップロードし、以降は NVS フラグでスキップする（`PSS_LTE_FORCE_CERT_UPLOAD=1` で再投入）。

従来の ESP32 `SSLClient` → UART AT 平文 TCP 経由は `PSS_LTE_MODEM_TLS=0` のときのみ（非推奨）。

LTE 接続は Wi-Fi より時間がかかるため、`xiao-s3-aws-lte` は active 上限を 120 秒にしている。

#### 実測タイミングと送信間隔（2026-07 実機）

LiPo + Deep Sleep + `xiao-s3-aws-lte` + **モデム内蔵 TLS** で AWS IoT Core へ送信した際の目安:

| 指標 | 改善前（ESP32 TLS） | 改善後（モデム TLS + Fix A） |
|---|---|---|
| `networkConnectMs`（LTE 接続） | 約2.5秒 | 約2.5秒（初回コールドスタートは〜10秒） |
| `tcpTlsConnectMs` | （未分解、`mqttConnectMs` に含む） | 約 **1.5秒** |
| `mqttHandshakeMs` | （未分解） | 約 **0.2秒** |
| `mqttConnectMs`（TLS + MQTT 合計） | 約 **34〜35秒** | 約 **1.7秒** |
| `activeMsBeforePublish` | 約 **68〜77秒** | 定常約 **6秒**（初回 power_on は〜14秒） |
| **1 サイクル mAh（U200 実測）** | — | 定常 **≈2.1 mAh**（スリープ **≈22 mA**） |
| `timestamp` | **null**（#30） | **ISO8601 UTC**（モデム時刻・Fix A） |
| クラウド受信間隔 | 約 **8分** | 約 **5分弱**（見込み、`PSS_SLEEP_SECONDS=300`） |

`PSS_SLEEP_SECONDS` は **スリープ時間** であり受信間隔ではない。受信間隔 ≈ active + sleep + モデム切断待ち。

- 改善前は NTP 空振り（約30秒）+ ESP32 TLS over UART（約34秒）が支配的だった（[docs/lte-active-investigation.md](../docs/lte-active-investigation.md)）
- mAh 実測: [docs/power-measurement.md](../docs/power-measurement.md) §6（#31 完了）。**待機 ≈22 mA** → #25 Phase 0 完了: [25-low-power-mode.md](../docs/25-low-power-mode.md)

**LTE 時刻同期（#30）:** `syncClock()` は lwIP SNTP を使わず、モデム `AT+CCLK`（NITZ）→ 未提供時 `+CNTP` で ESP32 の system clock を設定する。LTE-only では `configTime()` を呼ばない。

関連: README §6.2、#25（低消費電力）、#30（LTE 時刻同期）、#31（消費電力実測）、[lte-active-investigation.md](../docs/lte-active-investigation.md)

#### 一晩通し試験（2026-07-07）

構成: LiPo 給電、`xiao-s3-aws-lte`（Deep Sleep）、SORACOM plan-D、AWS IoT Core（TLS 8883、QoS1）。
端末: `xiao-e83dc1fb05fc`。検証は CloudWatch（Lambda `parking-status-bridge`）の受信ログ。

| 項目 | 結果 |
|---|---|
| 期間 | 初回 LiPo 投入 約 22:32 JST 〜 boot 75 受信 約 08:42 JST（約10時間） |
| 送信件数 | **75件**（`bootCount` 1〜75、**欠番なし**） |
| 送信確認 | 全件 `deliveryConfirmed: true`（ログ上） |
| 起床 | boot 2 以降 `wakeCause: timer` / `resetReason: deep_sleep` |
| 受信間隔 | おおよそ **7分59秒〜8分21秒**（フェーズ1） |
| SORACOM 課金 | **385円**（試験期間の利用分） |
| ローカル Mosquitto（先行） | 24h / 285件 / `bootCount` 欠番 0（#6） |

**フェーズ1（おおよそ boot 2〜42）**

| 指標 | 値 |
|---|---|
| `activeMsBeforePublish` | 約 68〜77秒 |
| `networkConnectMs` | 約 2.5秒 |
| `mqttConnectMs` | 約 34〜35秒 |
| `network.transport` | `lte` |

**フェーズ2（boot 43 以降）**

| 項目 | 観測 |
|---|---|
| boot 42→43 の受信間隔 | 約 17分（他より長い） |
| boot 43 の `activeMsBeforePublish` | 185184 ms（約185秒） |
| boot 44〜75 の `activeMsBeforePublish` | おおよそ 128000〜131000 ms（約128〜131秒） |
| ペイロード `network` | `transport` / `networkConnectMs` / `mqttConnectMs` が **含まれない** 件がある |
| 送信 | `deliveryConfirmed: true` は継続 |

**試験終了時の操作（08:50 JST 頃）**

LiPo 残量測定のためバッテリーを抜き差しした。直後のログは `bootCount: 1`, `wakeCause: power_on`, `resetReason: power_on`。
残量計測の結果、**残量は目立った減少なし**（実測者確認）。

**未解決・フォロー**

- 送信サイクル再設計（SyncLedger、旧 outbox ラッチ）: #32 → [docs/sync-delivery-design.md](../docs/sync-delivery-design.md)
- 本番 LiPo 長時間試験（定常 active・`wakeCause: timer` 確認）
- 電流計による消費電力の実測（#31 → [docs/power-measurement.md](../docs/power-measurement.md)）

**解消済み（2026-07-07）**

- `timestamp: null` → モデム時刻同期（Fix A、#30）
- `network` メトリクス欠落 → `flushOutbox` 修正（Fix C）
- active 68秒 → モデム内蔵 TLS + Fix A で定常約6秒（[lte-active-investigation.md](../docs/lte-active-investigation.md)）

## 関連 Issue

| Issue | 内容 |
|---|---|
| #22 | PoC ロードマップ |
| #16 | 試作1台の組み立て・通電確認 |
| #5 | カラーセンサ読み取り（VEML6040） |
| #6 | 判定ロジック + MQTT + Deep Sleep |
| #25 | 低消費電力運用 |
| #30 | LTE-M 時刻同期（NTP） |

## MQTT ペイロード

[docs/data-model.md](../docs/data-model.md) および Issue #6 を参照。PoC 段階では `deviceId` をファームにハードコードする（#14）。
