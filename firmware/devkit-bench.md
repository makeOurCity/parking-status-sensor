# 開発ベンチ配線（ESP32 DevKit）

> **アーカイブ（2026-07）**: DevKit による検証は完了。PoC 試作は XIAO ESP32S3 のみで進める。配線の正は [docs/wiring.md](../docs/wiring.md)。ロードマップは Issue #22。

Issue #5 第1段階向け。机上で Grove Color Sensor V3.0 の読み取りと色判定の先行検証を行う構成。

- **対象**: ESP32 DevKit（ESP-WROOM-32 系）+ **Grove - I2C Color Sensor V3.0** + RGB LED（オプション）
- **対象外**: XIAO 実証機・LiPo・防水筐体（→ [docs/wiring.md](../docs/wiring.md)）
- **PlatformIO 環境**: `devkit`（[platformio.ini](platformio.ini)）
- **ピン定義の正**: [include/board_devkit.h](include/board_devkit.h)

試作機（XIAO）と**同一の Grove センサモジュール**を使う。DevKit には Grove 変換ケーブルで接続する。

---

## 1. 構成概要

```
[USB 5V] ──→ [ESP32 DevKit]
                 │
                 ├── I2C ──→ [Grove Color Sensor V3.0]  ← 満空灯・テスト光源の光を読む
                 │              （Grove 変換ケーブル経由）
                 │
                 └── PWM ──→ [RGB LED]   ← センサが見ている色を視覚表示（開発用）
```

| 部品 | 備考 |
|---|---|
| ESP32 DevKit | USB シリアル（CP2102 等）付き。USB 給電 |
| Grove - I2C Color Sensor V3.0 | SKU 101021133。VEML6040 搭載。I2C `0x10` |
| Grove 4 pin Female Jumper to Grove 4 pin 変換ケーブル | DevKit の GPIO21/22 へ接続（[bom.md](../docs/bom.md) #9） |
| RGB LED | **共陰極**（Cathode → GND）。開発ベンチでの色確認用 |
| 抵抗 220Ω ×3 | RGB の R/G/B 各線（LED 内蔵抵抗付きモジュールなら不要な場合あり） |
| ジャンパ線・ブレッドボード | RGB LED 用。センサは Grove ケーブルで接続 |

---

## 2. Grove Color Sensor V3.0

### 2.1 センサ仕様

| 項目 | 値 |
|---|---|
| 製品名 | Grove - I2C Color Sensor V3.0 |
| 搭載 IC | Vishay VEML6040（RGBW） |
| インターフェース | I2C（Grove コネクタ内蔵） |
| I2C アドレス | `0x10`（7-bit） |
| 動作電圧 | 3.3 V（DevKit の 3V3 ピンから供給） |

XIAO 実証機と同一モジュール。詳細は [docs/wiring.md](../docs/wiring.md) §3。

### 2.2 DevKit ↔ Grove センサ接続

**Grove 変換ケーブル**（Grove 4 pin → オスデュポン）を使用する。

| Grove 信号（線色） | ESP32 DevKit |
|---|---|
| 黄 SCL | **GPIO22** |
| 白 SDA | **GPIO21** |
| 赤 VCC | **3V3** |
| 黒 GND | **GND** |

```
Grove Color Sensor V3.0    変換ケーブル    ESP32 DevKit
──────────────────────    ────────────    ────────────
Grove コネクタ ─────────→  オスデュポン ──→  GPIO21/22, 3V3, GND
```

### 2.3 注意

- **5V ピンに VCC を接続しない**（3.3 V 系統を使用）
- I2C アドレス: `0x10`（VEML6040）
- 現行ファームウェア（`main.cpp`）は **TCS34725 用ライブラリのまま**。VEML6040 ドライバへの移行は Issue #5 で実施予定

---

## 3. RGB LED（開発ベンチ・オプション）

センサが検出した色を RGB LED でおおよそ再現し、Issue #5 の赤/緑分離を目視確認するための部品。**PoC 実証機には搭載しない。**

### 3.1 LED の種類

手元確認済み: **共陰極**タイプ（4 本線）

| 線のラベル | 接続先 |
|---|---|
| **Cathode** | GND |
| **Red** | GPIO25（+ 220Ω） |
| **Green** | GPIO26（+ 220Ω） |
| **Blue** | GPIO27（+ 220Ω） |

ラベルは `Blue, Green, Cathode, Red` のように並んでいても、**名前どおりの線を GPIO に接続**する（物理並び ≠ 接続先）。

### 3.2 DevKit ↔ RGB LED 接続一覧

| RGB LED | ESP32 DevKit |
|---|---|
| Cathode | GND |
| Red | **GPIO25** |
| Green | **GPIO26** |
| Blue | **GPIO27** |

### 3.3 ファームウェア上の挙動

- `board_devkit.h` で `RGB_LED_ENABLED 1`
- 起動後 **2 秒間**、何もかざさずに環境光のベースライン（Clear 正規化比率）をキャリブレーション
- その後、センサの色比率がベースラインから変化したときだけ LED が点灯
- 色の算出は **絶対値ではなく R/C・G/C・B/C の比率差分**（光源を近づけて全体が暗くなっても反応する）

`xiao-s3` 環境では `RGB_LED_ENABLED 0`（無効）。

---

## 4. GPIO まとめ（DevKit）

| GPIO | 用途 | 接続先 |
|---|---|---|
| 3V3 | 電源出力 | Grove センサ VCC（赤） |
| GND | グランド | Grove センサ GND（黒）、RGB LED Cathode |
| **21** | I2C SDA | Grove センサ SDA（白） |
| **22** | I2C SCL | Grove センサ SCL（黄） |
| **25** | PWM | RGB LED Red |
| **26** | PWM | RGB LED Green |
| **27** | PWM | RGB LED Blue |

DevKit の型番によってピン位置のラベル表記は異なるが、**GPIO 番号**で接続する。

---

## 5. ビルド・書き込み・確認

```bash
cd firmware

# ビルド
pio run -e devkit

# 書き込み（ポートは環境に合わせる）
pio run -e devkit -t upload --upload-port /dev/cu.usbserial-0001

# シリアルモニタ（115200）
pio device monitor -e devkit --port /dev/cu.usbserial-0001
```

### 5.1 起動ログの例

> **注**: 現行ファームは TCS34725 用。VEML6040 ドライバ移行後はログ文言・アドレスが変わる。

```
board=devkit i2c_sda=21 i2c_scl=22
rgb_led=r:25 g:26 b:27 (common cathode)
TCS34725 ready
Calibrating ambient baseline (2s) - leave sensor unobstructed
ambient baseline R=... G=... B=... C=... ratio=... ... ...
R G B C R-G  dR dG dB  ledR ledG ledB
```

| 列 | 意味 |
|---|---|
| R G B C | センサ生値（移行後は R G B W） |
| R-G | 赤−緑（Issue #5 の分離確認用） |
| dR dG dB | Clear 正規化比率のベースライン差分（RGB LED デバッグ用） |
| ledR ledG ledB | RGB LED への PWM 出力（0〜255） |

### 5.2 Issue #5 の確認目安

| テスト | 期待 |
|---|---|
| 何もかざさない | `dR dG dB` ほぼ 0、LED 消灯 |
| 赤い光源 | `dR` が大きい正、LED が赤系 |
| 緑の光源 | `dG` が大きい正、LED が緑系 |
| 分離 | 赤/緑で **R-G 差 ≥ 100** 程度（生値ベースの目安） |

キャリブレーション中はセンサに手や色付き物体を近づけない。照明を大きく変えたら DevKit の **RST** で再起動しベースラインを取り直す。

---

## 6. XIAO 実証機との違い

| 項目 | DevKit ベンチ | XIAO 実証機 |
|---|---|---|
| ドキュメント | 本ファイル | [docs/wiring.md](../docs/wiring.md) |
| センサモジュール | **同一**（Grove Color Sensor V3.0） | 同一 |
| センサ接続 | Grove 変換ケーブル → GPIO21/22 | Grove 4芯ケーブル → Grove Shield I2C |
| I2C ピン | GPIO21 / 22 | D4(5) / D5(6) |
| 電源 | USB 3V3 | LiPo + 3V3 |
| RGB LED | あり（開発用） | なし |

---

## 関連

- [firmware/README.md](README.md) — ファームウェア全体・PlatformIO 環境
- Issue #5 — カラーセンサ読み取り確認（第1段階: DevKit）
- Issue #6 — 判定ロジック + MQTT（DevKit で先行可能）
