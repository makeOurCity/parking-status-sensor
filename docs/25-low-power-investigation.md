# Issue #25 低消費電力 — 事前調査メモ（WIP）

Issue #25（低消費電力運用モード）に着手する前の調査記録。  
**暫定・WIP** — Phase 0（実機・一次資料・計測）完了までは設計の正としない。

- 関連 Issue: [#25](https://github.com/makeOurCity/parking-status-sensor/issues/25)
- 前提実測: [#31](docs/power-measurement.md)（パターン D）
- 次ステップ: 本メモの Phase 0 チェックリスト → 確定後に `docs/25-low-power-mode.md`（設計の正）

---

## 1. 調査の位置づけ

| Issue | 役割 | 状態 |
|---|---|---|
| #6 | MQTT・Deep Sleep 骨格 | 完了 |
| #31 | 消費電力実測（U200） | 完了 |
| #32 | SyncLedger・送信サイクル | 完了 |
| **#25** | 低消費電力運用（周辺電源・変化時送信） | **調査中（本メモ）** |

#31 引き渡し後、#25 を再開。調査は Web・データシート・コードレビュー・並行サブエージェント調査を実施したが、**未取得資料に基づく断定を含んでいた**ため、本メモでは撤回と証拠ルールを明記する。

---

## 2. 調査品質の問題と撤回

### 2.1 問題

取得できていない・読めていない資料（V3 センサ回路図のタイムアウト、手元 Shield のテスター未確認など）を根拠に **confirmed** と書いた。実機の一次観察（センサ白 LED 点灯）より Wiki 未記載を優先した箇所もある。

### 2.2 撤回した断定

| 以前の断定 | 足りなかった根拠 |
|---|---|
| V3 センサに白 LED はない | V3 回路図未取得。手元実機で白 LED 点灯と矛盾 |
| Grove Shield 全ポート VCC = 3.3 V（confirmed） | 手元 Shield 改版・テスター未確認。二次要約のみ |
| 待機 22 mA の主因は LTE / Grove VCC 漏れ | 機器別抜き差し計測なし |
| VEML6040 shutdown は ≈0.2 mA で副次 | 基板 LED が VCC 直結なら見積もり無効。キャリア回路図未読 |
| `modem.poweroff()` 未成立 | Serial ログ・TinyGSM 応答待ちのコード突合未実施 |
| ハード VCC 遮断が必須（confirmed） | poweroff 修正で足りる可能性を計測前に潰した |

### 2.3 証拠ルール（#25 以降）

1. **未取得の資料に基づく結論を書かない**
2. **confirmed** は次のみ: 手元実機の計測・観察 / リポジトリに保存した回路図・DS / 本 repo のコード
3. Web 検索・要約のみは **likely 以下**
4. **実機の一次観察**は Wiki 未記載より優先
5. 設計ドキュメント（`25-low-power-mode.md`）は **Phase 0 完了後**

---

## 3. 現時点で根拠がある事実（縮小版）

| 事実 | 根拠 | 信頼度 |
|---|---|---|
| 定常 ≈2.1 mAh/サイクル、待機 ≈22 mA | [power-measurement.md](power-measurement.md) §6 | confirmed |
| 手元センサに白 LED が光っている | 実機観察（2026-07-10 調査時） | confirmed |
| `sensor.cpp` は VEML6040 `SD_ENABLE`（SD=0）固定 | `firmware/src/sensor.cpp` | confirmed |
| `mustPublish()` は骨格のみ（`PSS_CHANGE_ONLY_SEND` 未定義時は常に true） | `firmware/src/main.cpp` | confirmed |
| LTE 切断時 `disconnectTransport()` → `modem.poweroff()` | `firmware/src/transport.cpp` | confirmed |
| SyncLedger（NVS）に `lastConfirmedStatus` あり | `firmware/src/sync_ledger.cpp` | confirmed |

### 未検証（Phase 0 で閉じる）

| 項目 | 備考 |
|---|---|
| UART / I2C ポート VCC 電圧 | 「Grove 5V」表現の実態 |
| 22 mA の機器別内訳 | センサ / LTE / Shield 単体 |
| センサ白 LED の消灯手段 | SD ビットか VCC 遮断か |
| `modem.poweroff()` 成否 | Serial `NORMAL POWER DOWN`、NETLIGHT |
| Grove ポート VCC の GPIO 制御の有無 | Shield 回路図 + 実機 |
| V3 キャリア基板の LED 回路 | 回路図未取得 |

---

## 4. 文献・コード調査のメモ（likely — 実機未確認）

以下は調査で得た**仮説・参考**。Phase 0 まで設計根拠にしない。

### 4.1 Grove Shield for XIAO（SKU 103020312）

**参照（未を手元保存）:** [Seeed Wiki](https://wiki.seeedstudio.com/Grove-Shield-for-Seeeduino-XIAO-embedded-battery-management-chip/)、回路図 RAR `Grove_Shield_for_Seeeduino_XIAO_v1.0.rar`

| 記述（文献・要約） | 信頼度 |
|---|---|
| 5 V 昇圧なし、ETA3410 バックで 3.3 V | likely（RAR 要約。手元未確認） |
| 全 Grove ポート VCC が同一 3.3 V レール | likely |
| GPIO によるポート電源スイッチなし | likely |
| 物理スイッチは BAT+ 系統 | likely |
| `esp_deep_sleep()` では Grove VCC は自動 OFF しない | likely（回路 + firmware/README 趣旨） |

**既存ドキュメントとの齟齬:** `power-measurement.md` / `firmware/README.md` の「Grove 5V」は、上記が正しければ **用語誤り** の可能性。実機テスターで訂正する。

### 4.2 Grove Color Sensor V3.0（101021133 / VEML6040）

**参照:** [V3 Wiki](https://wiki.seeedstudio.com/grove_color_sensor_v3_0_iic/)、[VEML6040 DS](https://www.vishay.com/docs/84276/veml6040.pdf)  
**未取得:** `Grove_Color/SCH.pdf`（CDN タイムアウト）、マルツ `Grove - Color Sensor v3.0_SCH_PDF_240428.pdf`

| 記述 | 信頼度 |
|---|---|
| VEML6040 チップに照明 LED 駆動ピンなし | confirmed（データシート） |
| SD=1 でチップ ≈200 µA → ≈800 nA（VDD=3.6 V 条件） | confirmed（データシート） |
| SD は IC 内部のみ。Grove VCC は切れない | confirmed（データシート + Shield 趣旨） |
| **キャリア基板に白 LED なし** | **撤回** — 実機で点灯確認 |
| Wiki に照明 LED の記載なし | confirmed（Wiki 本文）— 実機と矛盾するため **記載漏れ or 改版の疑い** |

### 4.3 M5Stack SIM7080G CAT-M Unit（U128）

**参照:** [M5 Unit CatM](https://docs.m5stack.com/en/unit/cat_m)、[SIM7080G HW Design](https://edworks.co.kr/wp-content/uploads/2022/04/SIM7080G_Hardware_Design_V1.04.pdf)

| 記述 | 信頼度 |
|---|---|
| Grove 4P: GND / 5V / UART。PWRKEY 未引出し | confirmed（M5 PinMap） |
| `modem.poweroff()` → `AT+CPOWD=1`（TinyGSM） | confirmed（ライブラリ） |
| 正常 power-off 後チップ VBAT ≤15 µA | confirmed（SIMCom DS） |
| NETLIGHT 64ms/3000ms = 登録済みネットワーク | confirmed（SIMCom Table 14） |
| NETLIGHT 消灯 = Power off または PSM | confirmed（SIMCom Table 14） |
| #31: poweroff 後も青 LED 3 s 点滅 | confirmed（実測メモ）→ power-off 成功状態と整合しない **可能性**（要 Serial 突合） |

### 4.4 XIAO ESP32S3 Deep Sleep

| 記述 | 信頼度 |
|---|---|
| 単体 Deep Sleep 14 µA @ 3.8 V（Seeed Wiki） | confirmed（メーカー） |
| スタック全体 ≈22 mA（#31） | confirmed（実測） |
| 14 µA は周辺無効・単体条件 | confirmed（Seeed Forum 注記） |

---

## 5. ファームウェア現状（#25 関連）

| 機能 | 状態 | ファイル |
|---|---|---|
| Deep Sleep サイクル | 実装済 | `main.cpp` `sleepNow()` |
| 変化時のみ送信 | 骨格のみ | `mustPublish()` — 常時 true |
| skipped パス（通信なし） | 実装済 | `runCycle()` |
| VEML6040 shutdown | **未実装** | `sensor.cpp` |
| heartbeat | 未実装（Issue コメント: 当面不要） | — |
| `prod` build env | なし | `platformio.ini` |

**mustPublish 実装ギャップ:** 初回 `lastConfirmedBoot == 0` で強制送信が必要（初回 unknown だと現行骨格は送信しない）。

---

## 6. Issue #25 ソフト設計（Issue コメント — 電源調査と独立）

| 項目 | 内容 |
|---|---|
| 送信条件 | `status` 変化 + `pendingValid` |
| unknown 遷移 | 送信する |
| heartbeat | 当面不要 |
| 初回起床 | 必ず 1 回送信 |
| lastStatus 保持 | NVS（SyncLedger） |
| 運用モード案 | debug / prod / lte-test（build env 対応は Phase 2） |

---

## 7. Phase 0 チェックリスト（設計 PR の前提）

### 7-A 部品同定

- [ ] センサ SKU / シルク（101021133 等）
- [ ] Shield PMIC 改版（ETA6003 vs BQ24070）
- [ ] LTE モジュール型番

### 7-B 電圧（テスター）

- [ ] I2C ポート VCC（active / Deep Sleep）
- [ ] UART ポート VCC（active / Deep Sleep）

### 7-C 電流（U200、抜き差し）

- [ ] XIAO + Shield のみ
- [ ] + センサのみ
- [ ] + LTE のみ
- [ ] + 両方（#31 再現）
- [ ] LTE 抜き差し / センサ抜き差し → **22 mA 内訳**
- [ ] VEML6040 SD=1 後
- [ ] `poweroff()` 後（Serial 同時）

### 7-D ファーム・ログ

- [ ] `NORMAL POWER DOWN` の有無
- [ ] TinyGSM `powerOffImpl` 応答待ち（コードレビュー）
- [ ] 青 NETLIGHT パターン

### 7-E センサ白 LED

- [ ] 基板写真・回路図（取得後）
- [ ] 暗室での光
- [ ] 満空灯読取への影響（#8 連携）

### 7-F 一次資料のリポジトリ保存

- [ ] V3 センサ回路図 → `docs/datasheets/` 等
- [ ] Shield 回路図
- [ ] U128 回路図

---

## 8. 実装計画の骨子（Phase 0 後）

| Phase | 内容 |
|---|---|
| 0 | 本チェックリスト + 一次資料保存 |
| 1 | `docs/25-low-power-mode.md`（Phase 0 結果のみを根拠） |
| 2 | ファーム（poweroff / SD / mustPublish — 優先度は計測後） |
| 3 | U200 Before/After、README §6.2 更新 |

**Phase 0 完了前に設計 PR で「CANNOT」「主因」「優先度 1」を確定しない。**

---

## 9. レビューで指摘された調査上の弱点（再発防止）

1. 白 LED を Wiki 未記載だけで否定した
2. 回路図未入手のままセンサ電流・LED 有無を結論づけた
3. Shield 3.3 V を実機未確認で confirmed とした
4. LTE が動作している事実を「仕様不整合」で片付けた
5. 22 mA 内訳なしで主因を決めつけた
6. #31 の 2.1 mAh が boot 1〜2 の概算のみ
7. `poweroff()` 成否をコード未確認
8. poweroff 失敗と VCC 維持を混同
9. 変化時のみ送信の mAh 効果未試算
10. SKU 混在未排除
11. 環境光 PoC とセンサ LED 常時点灯の整合未整理
12. ハード遮断案が LTE 偏重（センサ VCC 遮断の効果は LED 次第）

---

## 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-07-10 | 初版。#25 事前調査・品質問題の撤回・Phase 0 チェックリスト |
