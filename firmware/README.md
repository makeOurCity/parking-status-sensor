# ファームウェア

ESP32 向けファームウェア（PlatformIO）。TCS34725 から満空灯の色を読み取り、AWS IoT Core へ MQTT 送信する。

## ボードと役割

| ボード | PlatformIO 環境 | 用途 |
|---|---|---|
| ESP32 DevKit（ESP-WROOM-32 等） | `devkit` | **開発ベンチ** — センサ読み取り・判定ロジック・MQTT 連携の先行検証 |
| Seeed XIAO ESP32S3 | `xiao-s3` | **PoC 実証機** — 現場設置向け（LiPo・Deep Sleep・筐体） |

- アプリロジック（センサ・判定・MQTT ペイロード）は共通の `src/` を共有する。
- ピン定義・電源まわりだけボード別ヘッダ（`include/board_*.h`）で切り替える。
- **設計ドキュメントの正**（BOM・配線・回路図）は XIAO 実証機向け。DevKit ベンチの配線は [devkit-bench.md](devkit-bench.md) を参照。

### DevKit で検証できない項目（XIAO 到着後に実施）

- LiPo 給電・内蔵充電（BAT ピン）
- Deep Sleep 消費電流（14µA 級）
- 470µF による電源安定化の実機効果
- 延長ケーブル・防水筐体での現場運用

## ディレクトリ構成

```
firmware/
├── platformio.ini       # [env:devkit] / [env:xiao-s3]
├── include/
│   ├── board.h          # ボード別ヘッダの切り替え
│   ├── board_devkit.h   # DevKit 用ピン定義
│   └── board_xiao.h     # XIAO 用ピン定義（docs/wiring.md に準拠）
├── src/
│   └── main.cpp         # Issue #5: TCS34725 読み取り（シリアル出力）
└── README.md            # 本ファイル
```

## 開発ベンチ配線（ESP32 DevKit）

**詳細は [devkit-bench.md](devkit-bench.md)**（TCS34725 8 ピン配置・RGB LED 共陰極・GPIO 一覧・確認手順）。

### 接続の要約

| 信号 | DevKit | TCS34725（1〜4 番） |
|---|---|---|
| GND | GND | 1 GND |
| SDA | GPIO21 | 2 SDA |
| SCL | GPIO22 | 3 SCL |
| VCC | 3V3 | 4 VDD |

| RGB LED（共陰極） | DevKit |
|---|---|
| Cathode | GND |
| Red / Green / Blue | GPIO25 / 26 / 27（各 220Ω） |

- I2C アドレス: `0x29`
- RGB LED は `env:devkit` のみ有効（色の視覚確認用。実証機には非搭載）

### XIAO 実証機の配線

[docs/wiring.md](../docs/wiring.md) §2・§3 を参照（D4=SDA, D5=SCL, 3V3 給電）。

## ビルド・書き込み

```bash
cd firmware

# DevKit（開発ベンチ）
pio run -e devkit -t upload
pio device monitor -e devkit

# XIAO 実証機
pio run -e xiao-s3 -t upload
pio device monitor -e xiao-s3
```

## 関連 Issue

| Issue | 内容 | 想定ボード |
|---|---|---|
| #5 | TCS34725 センサ読み取り確認 | 第1段階: DevKit → 第2段階: XIAO |
| #6 | 判定ロジック + MQTT 送信 | 第1段階: DevKit → 第2段階: XIAO（Deep Sleep は XIAO で検証） |
| #16 | 試作1台の組み立て・通電確認 | XIAO のみ |

## MQTT ペイロード

[docs/data-model.md](../docs/data-model.md) および Issue #6 を参照。PoC 段階では `deviceId` をファームにハードコードする（#14）。
