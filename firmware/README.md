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
| LTE-M | Grove 5V はオン | **Wi-Fi PoC 中は UART ケーブル抜き**（物理 OFF）。LTE 利用後は `modem.poweroff()` |

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

シリアルに `modem init` → `network registration` → `data attach` の 4 段階が出る。
`RESULT: PASS` なら UART・SIM・電波・APN まで通っている。

- `FAIL: no AT response` … Grove UART ケーブル、モジュール電源、TX/RX
- `FAIL: not registered` … SIM、アンテナ、電波
- `FAIL: GPRS attach failed` … APN（SORACOM: `soracom.io` / `sora` / `sora`）

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

## 関連 Issue

| Issue | 内容 |
|---|---|
| #22 | PoC ロードマップ |
| #16 | 試作1台の組み立て・通電確認 |
| #5 | カラーセンサ読み取り（VEML6040） |
| #6 | 判定ロジック + MQTT + Deep Sleep |

## MQTT ペイロード

[docs/data-model.md](../docs/data-model.md) および Issue #6 を参照。PoC 段階では `deviceId` をファームにハードコードする（#14）。
