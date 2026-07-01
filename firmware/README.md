# ファームウェア

XIAO ESP32S3 向けファームウェア（PlatformIO）。Grove - I2C Color Sensor V3.0（VEML6040）から満空灯の色を読み取り、AWS IoT Core へ MQTT 送信する。

ロードマップ: [Issue #22](https://github.com/makeOurCity/parking-status-sensor/issues/22)

## 対象ボード

| ボード | PlatformIO 環境 | 用途 |
|---|---|---|
| Seeed XIAO ESP32S3 | `xiao-s3` | **PoC 試作機**（LiPo・Deep Sleep・現場設置） |

- 配線の正: [docs/wiring.md](../docs/wiring.md)
- `env:devkit` は過去の検証用。新規作業は `xiao-s3` のみ（[devkit-bench.md](devkit-bench.md) はアーカイブ）

### センサモジュール

**Grove - I2C Color Sensor V3.0**（VEML6040、I2C `0x10`）。Grove Shield の I2C ポートにケーブル1本で接続。

> **ファームウェア移行中**: 現行 `main.cpp` は Adafruit TCS34725 ライブラリを使用している。VEML6040 ドライバ（Seeed ライブラリ等）への移行が必要（Issue #5）。

## ディレクトリ構成

```
firmware/
├── platformio.ini       # デフォルト: xiao-s3
├── include/
│   ├── board.h          # ボード別ヘッダの切り替え
│   ├── board_xiao.h     # XIAO 用ピン定義（docs/wiring.md に準拠）
│   └── board_devkit.h   # （アーカイブ）DevKit 用
├── src/
│   └── main.cpp         # Issue #5: センサ読み取り（VEML6040 移行予定）
└── README.md            # 本ファイル
```

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

## 関連 Issue

| Issue | 内容 |
|---|---|
| #22 | PoC ロードマップ |
| #16 | 試作1台の組み立て・通電確認 |
| #5 | カラーセンサ読み取り（VEML6040） |
| #6 | 判定ロジック + MQTT + Deep Sleep |

## MQTT ペイロード

[docs/data-model.md](../docs/data-model.md) および Issue #6 を参照。PoC 段階では `deviceId` をファームにハードコードする（#14）。
