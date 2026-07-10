# Power Logger（Issue #31）

M5Stack **U200-1A**（INA226 @ `0x41`）と **SSD1306 OLED**（`0x3C` / `0x3D`）を ESP32 DevKit の I2C（GPIO21/22）に載せ、試験対象機（XIAO + LiPo）の消費電流を CSV 記録する。

設計・配線: [docs/power-measurement.md](../../docs/power-measurement.md)

## 構成

| 役割 | ハード |
|---|---|
| ロガー | ESP32 DevKit（USB 給電） |
| 電流計 | M5Stack U200-1A（Grove → DevKit I2C） |
| 表示 | SSD1306 128×64 OLED（DevKit I2C 共有） |
| 試験対象機 | XIAO ESP32S3 + Grove Shield（LiPo 経由、**USB 外す**） |

### 電源配線（U200-1A 端子台）

```
LiPo (+) → IN+
LiPo (-) → IN-
OUT+     → Grove Shield BAT+
OUT-     → Grove Shield BAT-
```

### I2C（ロガー DevKit）

| 信号 | DevKit | U200 Grove / OLED |
|---|---|---|
| SDA | GPIO21 | 黄（M5 PORT.A） |
| SCL | GPIO22 | 白 |
| GND | GND | 黒 |
| 5V | 5V | 赤（U200 Grove） |
| 3V3 | 3V3 | OLED VCC |

**SDA/SCL 注意:** M5 U200 の Grove（PORT.A）は **黄=SDA → GPIO21、白=SCL → GPIO22**。  
[firmware/devkit-bench.md](../../firmware/devkit-bench.md) の色センサ向け表記（黄=SCL/白=SDA）と**逆**なので混同しない。  
I2C スキャンで `0x3C` のみ・`0x41` なしのときは SDA/SCL を疑う。

## ビルド・書き込み

```bash
cd tools/power-logger
pio run -e logger-devkit
pio run -e logger-devkit -t upload --upload-port /dev/cu.usbserial-XXXX
```

## 計測

```bash
pio device monitor -e logger-devkit --port /dev/cu.usbserial-XXXX > capture.csv
```

- Serial: `ms,current_mA,bus_mV,power_mW`（15 Hz）
- OLED: 電流・電圧・電力・セッション mAh・ピーク・経過秒（約 4 Hz 更新）

### mAh 積算（ホスト）

```bash
python3 integrate_mah.py capture.csv
```

## OLED 表示例

```
#31 Power Logger
I: 12.34 mA
V: 3.78 V
P: 46.6 mW
S: 0.0420 mAh
pk:185.0mA 45s n=678
```

µA 級（Deep Sleep）では `I:` 行が `45.0 uA` 形式になる。

## トラブルシュート

| 症状 | 確認 |
|---|---|
| `INA226 not found` | U200 Grove ケーブル、I2C 配線、DevKit USB |
| OLED 無し（CSV のみ） | アドレス `0x3C` / `0x3D`、`platformio.ini` の `LOGGER_OLED_ADDR` |
| 電流符号が逆 | U200 の IN/OUT を逆にしていないか（M5 公式: IN=電源、OUT=負荷） |
| mAh が合わない | 試験対象機 USB が刺さっていないか |
