# 開発ベンチ配線（ESP32 DevKit）

Issue #5 第1段階向け。机上で TCS34725 の読み取りと色判定の先行検証を行う構成。

- **対象**: ESP32 DevKit（ESP-WROOM-32 系）+ TCS34725 + RGB LED（オプション）
- **対象外**: XIAO 実証機・LiPo・延長ケーブル・防水筐体（→ [docs/wiring.md](../docs/wiring.md)）
- **PlatformIO 環境**: `devkit`（[platformio.ini](platformio.ini)）
- **ピン定義の正**: [include/board_devkit.h](include/board_devkit.h)

---

## 1. 構成概要

```
[USB 5V] ──→ [ESP32 DevKit]
                 │
                 ├── I2C ──┬→ [TCS34725]  ← 満空灯・テスト光源の光を読む
                 │         └→ [SSD1306]   ← RGBC 数値表示（開発用）
                 │
                 └── PWM ──→ [RGB LED]    ← センサが見ている色を視覚表示（開発用）
```

| 部品 | 備考 |
|---|---|
| ESP32 DevKit | USB シリアル（CP2102 等）付き。USB 給電 |
| TCS34725 モジュール | ストロベリーリナックス #13472 等。I2C `0x29` |
| SSD1306 OLED | 128×64 I2C。アドレス `0x3C`（`0x3D` の場合あり） |
| RGB LED | **共陰極**（Cathode → GND）。開発ベンチでの色確認用 |
| 抵抗 220Ω ×3 | RGB の R/G/B 各線（LED 内蔵抵抗付きモジュールなら不要な場合あり） |
| ジャンパ線・ブレッドボード | オス-メス、オス-オス |

---

## 2. TCS34725 モジュール

### 2.1 ピン配置（実機確認済み・#13472 系）

モジュールによって並びは異なる。**シルクを必ず確認**すること。本リポジトリで手元確認した 8 ピン配置:

| 番号 | 信号 | DevKit 接続 | 備考 |
|---|---|---|---|
| **1** | GND | GND | 必須 |
| **2** | SDA | GPIO21 | I2C データ |
| **3** | SCL | GPIO22 | I2C クロック |
| **4** | VDD | **3V3** | 必須。**5V 禁止**（動作 2.7〜3.6V） |
| 5 | LEDC | 未接続 | 搭載 LED カソード。ファームで消灯 |
| 6 | NC | 未接続 | — |
| 7 | INT | 未接続 | 割り込み出力 |
| 8 | LEDA | 未接続 | 搭載 LED アノード |

- 開発ベンチでは **1〜4 番にオスピンヘッダ**（1×4 または 1×8 の未使用側は配線しない）をはんだ付けして使用。
- 同梱のピンヘッダは未はんだのことが多い。はんだ付け後に配線する。

### 2.2 DevKit ↔ TCS34725 接続一覧

| TCS34725（番号） | 信号 | ESP32 DevKit |
|---|---|---|
| 1 | GND | GND |
| 2 | SDA | **GPIO21** |
| 3 | SCL | **GPIO22** |
| 4 | VDD | **3V3** |

```
TCS34725          ESP32 DevKit
────────          ────────────
1 GND      ───→   GND
2 SDA      ───→   GPIO21
3 SCL      ───→   GPIO22
4 VDD      ───→   3V3
```

### 2.3 注意

- **5V ピンに VDD を接続しない**
- I2C アドレス: `0x29`
- 白色 LED はファーム側で消灯（`setInterrupt(true)`）。表示灯・テスト光源の光のみ読む

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

## 4. SSD1306 OLED（開発ベンチ・オプション）

TCS34725 の生値（R/G/B/C）と R-G 差分を 128×64 OLED に表示する。Issue #5 の机上確認用。**PoC 実証機には搭載しない。**

### 4.1 I2C バス共有（追加 GPIO 不要）

SSD1306 は I2C デバイスのため、TCS34725 と **同じ SDA/SCL** に並列接続する。RGB LED 用の GPIO25〜27 とは独立。

| 信号 | ESP32 DevKit | TCS34725 | SSD1306 OLED |
|---|---|---|---|
| SDA | **GPIO21** | 2 SDA | SDA |
| SCL | **GPIO22** | 3 SCL | SCL |
| VCC | **3V3** | 4 VDD | VCC |
| GND | GND | 1 GND | GND |

- I2C アドレス: **`0x3C`**（モジュールによっては `0x3D`。表示されない場合は `board_devkit.h` の `OLED_I2C_ADDR` を変更）
- TCS34725（`0x29`）とアドレスが異なるためバス共有可能
- 配線はブレッドボード上で TCS34725 と OLED の同名ピンをまとめて DevKit に接続する

```
                    ┌── SDA ── GPIO21
DevKit ── 3V3 ──────┼── VCC ── TCS34725 / OLED
          GND ──────┼── GND ── TCS34725 / OLED
                    └── SCL ── GPIO22
```

### 4.2 ファームウェア上の挙動

- `board_devkit.h` で `OLED_ENABLED 1`
- 0.3 秒ごとに R / G / B / C / R-G を更新
- キャリブレーション中は `Calibrating...` を表示
- OLED 未接続時はシリアルに WARN を出してセンサ動作は継続

`xiao-s3` 環境では `OLED_ENABLED 0`（無効）。

---

## 5. GPIO まとめ（DevKit）

| GPIO | 用途 | 接続先 |
|---|---|---|
| 3V3 | 電源出力 | TCS34725 VDD、SSD1306 VCC |
| GND | グランド | TCS34725 GND、SSD1306 GND、RGB LED Cathode |
| **21** | I2C SDA | TCS34725 SDA、**SSD1306 SDA** |
| **22** | I2C SCL | TCS34725 SCL、**SSD1306 SCL** |
| **25** | PWM | RGB LED Red |
| **26** | PWM | RGB LED Green |
| **27** | PWM | RGB LED Blue |

### 使用していない GPIO（参考）

| GPIO | 備考 |
|---|---|
| 0, 2, 4, 5, 12, 15 | 起動ストラップ関連。避ける |
| 6〜11 | 一部 DevKit で内蔵フラッシュ接続 |
| 34〜39 | 入力専用 |

DevKit の型番によってピン位置のラベル表記は異なるが、**GPIO 番号**で接続する。

---

## 6. ビルド・書き込み・確認

```bash
cd firmware

# ビルド
pio run -e devkit

# 書き込み（ポートは環境に合わせる）
pio run -e devkit -t upload --upload-port /dev/cu.usbserial-0001

# シリアルモニタ（115200）
pio device monitor -e devkit --port /dev/cu.usbserial-0001
```

### 6.1 起動ログの例

```
board=devkit i2c_sda=21 i2c_scl=22
rgb_led=r:25 g:26 b:27 (common cathode)
TCS34725 ready
Calibrating ambient baseline (2s) - leave sensor unobstructed
ambient baseline R=... G=... B=... C=... ratio=... ... ...
oled=i2c addr=0x3c sda=21 scl=22 (shared bus)
R G B C R-G  dR dG dB  ledR ledG ledB
```

| 列 | 意味 |
|---|---|
| R G B C | センサ生値 |
| R-G | 赤−緑（Issue #5 の分離確認用） |
| dR dG dB | Clear 正規化比率のベースライン差分 |
| ledR ledG ledB | RGB LED への PWM 出力（0〜255） |

### 6.2 Issue #5 の確認目安

| テスト | 期待 |
|---|---|
| 何もかざさない | `dR dG dB` ほぼ 0、LED 消灯 |
| 赤い光源 | `dR` が大きい正、LED が赤系 |
| 緑の光源 | `dG` が大きい正、LED が緑系 |
| 分離 | 赤/緑で **R-G 差 ≥ 100** 程度（生値ベースの目安） |

キャリブレーション中はセンサに手や色付き物体を近づけない。照明を大きく変えたら DevKit の **RST** で再起動しベースラインを取り直す。

---

## 7. XIAO 実証機との違い

| 項目 | DevKit ベンチ | XIAO 実証機 |
|---|---|---|
| ドキュメント | 本ファイル | [docs/wiring.md](../docs/wiring.md) |
| I2C ピン | GPIO21 / 22 | D4(5) / D5(6) |
| 電源 | USB 3V3 | LiPo + 3V3 |
| RGB LED | あり（開発用） | なし |
| SSD1306 OLED | あり（開発用） | なし |
| TCS34725 ピン順 | 本ファイル §2.1（8 ピン・GND 先頭） | 延長ケーブルは [wiring.md §3.2](../docs/wiring.md) の信号順に合わせる |

XIAO 用延長ケーブルのピン 1〜4（3V3, GND, SDA, SCL）と、本モジュールの 1〜4（GND, SDA, SCL, VDD）は**並びが異なる**。XIAO 組立時は信号名で対応させること。

---

## 関連

- [firmware/README.md](README.md) — ファームウェア全体・PlatformIO 環境
- Issue #5 — TCS34725 センサ読み取り確認（第1段階: DevKit）
- Issue #6 — 判定ロジック + MQTT（DevKit で先行可能）
