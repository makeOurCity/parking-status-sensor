# 一次資料（Issue #25 Phase 0）

低消費電力調査で参照する回路図・データシートのローカルコピー。  
**出典 URL は各ファイル名のコメントまたは下表を正とする。**

| ファイル | 部品 | 出典 | 取得日 |
|---|---|---|---|
| [veml6040.pdf](veml6040.pdf) | VEML6040 IC | [Vishay DS 84276](https://www.vishay.com/docs/84276/veml6040.pdf) | 2026-07-10 |
| [veml6040-a3og-datasheet.pdf](veml6040-a3og-datasheet.pdf) | 同上（Seeed Wiki 同梱版） | 手元提供 `314020801_VISHAY_VEML6040A3OG_Datasheet.pdf` | 2026-07-10 |
| [grove-color-sensor-v3-board.png](grove-color-sensor-v3-board.png) | Grove Color Sensor V3.0 基板 | 手元実機写真（VEML6040 + **Fill-light** LED 位置） | 2026-07-10 |
| [grove-shield-xiao-v1.0-sch.pdf](grove-shield-xiao-v1.0-sch.pdf) | Grove Shield for XIAO v1.0 | Seeed Wiki RAR 内 `…SCH_20200423.pdf` | 2026-07-10 |
| [grove-shield-xiao.rar](grove-shield-xiao.rar) | 上記 + Eagle `.brd`/`.sch`、ETA3410/ETA6003 DS | [Seeed Wiki](https://wiki.seeedstudio.com/Grove-Shield-for-Seeeduino-XIAO-embedded-battery-management-chip/) | 2026-07-10 |
| [sim7080g-hw-design.pdf](sim7080g-hw-design.pdf) | SIM7080G モジュール | SIMCom HW Design V1.04（公開ミラー） | 2026-07-10 |

## Grove Color Sensor V3.0 — 基板写真メモ（confirmed）

[grove-color-sensor-v3-board.png](grove-color-sensor-v3-board.png)（手元実機、2026-07-10）より:

- シルク: **Grove - Color Sensor v3.0** / **VEML6040** / I2C `0x10`
- キャリア基板に **Fill-light**（白 LED）が VEML6040 チップ横に実装 — IC の SD ビットでは消灯不可（VEML6040 DS どおり）
- 回路図 PDF（`SCH.pdf`）は未取得。写真で LED 実装は確認済み

## 未取得（必要になった場合のみ）

| 資料 | 状況 | 次の手 |
|---|---|---|
| V3 センサ回路図 (`SCH.pdf`) | Seeed CDN 403 | LED 駆動経路の詳細が必要になった場合。現時点は基板写真で Fill-light 実装を確認済み |
| M5Stack Unit CatM（U128）回路図 | M5 docs に PinMap のみ | LTE 寄与が支配的と分かった場合に [M5 docs CatM](https://docs.m5stack.com/en/unit/cat_m) から入手 |

## Shield 回路図の読み取りメモ（confirmed — リポジトリ保存済み SCH）

RAR 内 SCH（2020-04-23）より:

- Grove 各ポートの **VCC** は Shield 上の **3.3 V レール**（`+3V3`）に直結
- **5 V 昇圧回路なし**（ETA3410 は LiPo → 3.3 V）
- ポート別の **GPIO 電源スイッチなし**
- 物理スイッチは **BAT+ 系統**（XIAO / Shield 給電の遮断）

→ 各所の「Grove 5V」表記は **用語の整理対象**（M5 の Grove 赤ピン名 or「周辺給電継続」の略）。テスターでの電圧再確認は不要。
