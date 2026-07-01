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

## 配線（XIAO 実証機）

[docs/wiring.md](../docs/wiring.md) を参照。

- XIAO + **Grove Shield for XIAO**
- I2C: Shield の Grove ポート（D4=SDA, D5=SCL）
- センサ: Grove Color Sensor V3.0（ピン入替不要）
- 電源: LiPo → Shield BAT パッド（JST）

## ビルド・書き込み

```bash
cd firmware

pio run -e xiao-s3 -t upload
pio device monitor -e xiao-s3
```

## シリアル出力（#5）

起動後、300 ms 間隔で以下を出力する。

```
board=xiao-s3 i2c_sda=5 i2c_scl=6
VEML6040 ready
R G B W R-G
1234 567 890 1500 667
```

- `W` は VEML6040 の White チャンネル（MQTT ペイロードの `raw.clear` に対応）
- `R-G` は赤/緑分離の目安（完了基準: 差 ≥ 100）

## 関連 Issue

| Issue | 内容 |
|---|---|
| #22 | PoC ロードマップ |
| #16 | 試作1台の組み立て・通電確認 |
| #5 | カラーセンサ読み取り（VEML6040） |
| #6 | 判定ロジック + MQTT + Deep Sleep |

## MQTT ペイロード

[docs/data-model.md](../docs/data-model.md) および Issue #6 を参照。PoC 段階では `deviceId` をファームにハードコードする（#14）。
