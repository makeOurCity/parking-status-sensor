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

### 通常モードの時間分解能（注意）

ファームの `ina226.setAverage(...)` の引数は回数ではなく enum 値。旧コードの `setAverage(4)` は **128 回平均**（`INA226_128_SAMPLES`）を意味しており、変換 1.1 ms × 電流・電圧 2 回 × 128 で、**1 回の値は約 282 ms の平均**になっている（CSV の出力は 15 Hz だが、同じ値が 4〜9 行続く）。過去ログと比較できるよう、通常モードはこの設定のまま据え置いている。ms 単位の突入電流を見たいときは、次の高速モードを使う。

## 高速モード（Issue #74: 瞬間的な電圧低下の計測）

LTE-M に電源を入れた瞬間の突入電流のように、ms 単位で起きる電圧低下を捉えるためのモード。配線は通常モードと同じで、試験対象機も LiPo で動かす構成のまま測れる。

- INA226 を変換時間 140 µs・平均 1 回に設定し、delay なしで読み続ける
  - **電圧**: 毎回読む。1 ウィンドウ 50 ms あたり約 108 サンプル（**約 0.46 ms 間隔**、2026-09-27 に実測）
  - **電流**: 電圧 8 回に 1 回だけ読む（約 4 ms 間隔、`LOGGER_CURRENT_EVERY`）。電流を読むにはレジスタポインタを切り替える必要があり、電圧の約 4 倍の時間がかかるため、最優先の電圧のサンプル密度を落とさないよう間引いている
  - ESP32 の Wire では、I2C の 1 回の通信に約 0.3 ms の固定の時間がかかる。I2C のクロックを 400 kHz から 1 MHz に上げても速くならなかったので、仕様の範囲内の 400 kHz にしている
- 50 ms ごとに、そのウィンドウの**最低電圧**・平均電圧・最大電流・最小電流・平均電流を 1 行出力する
- OLED の更新には I2C を数十 ms 使い、その間は計測できない。そのため、試験対象機が Deep Sleep 中（直前のウィンドウの最大電流が 5 mA 未満）のときだけ更新する。OLED には、そのウィンドウと起動からの最低電圧を表示する

```bash
pio run -e logger-devkit-fast -t upload --upload-port /dev/cu.usbserial-XXXX
pio device monitor -e logger-devkit-fast --port /dev/cu.usbserial-XXXX > capture-fast.csv
```

- Serial: `ms,samples,bus_min_mV,bus_avg_mV,current_max_mA,current_min_mA,current_avg_mA`
- `samples` は、そのウィンドウで読めた電圧のサンプル数。OLED 更新などで計測が止まると、この数が減る
- 電流の列は間引いて読んだ値から求めているので、約 4 ms より短い電流のピークは `current_max_mA` に出ないことがある。電圧の最低値（`bus_min_mV`）を主な指標にする

### 起床サイクルごとの電圧低下の集計

```bash
python3 find_dips.py capture-fast.csv
```

`current_max_mA` が 10 mA 以上のウィンドウを「起きている」とみなし、起床サイクルごとに、直前の待機電圧、最低電圧、落ち込み幅、最大電流を出力する。`integrate_mah.py` も高速モードのログ（`current_avg_mA` 列）に対応している。

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
