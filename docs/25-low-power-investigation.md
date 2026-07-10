# Issue #25 低消費電力 — 調査記録

Issue #25（低消費電力運用モード）の調査・Phase 0 計測の作業記録。

- 関連 Issue: [#25](https://github.com/makeOurCity/parking-status-sensor/issues/25)
- **結論（設計の正）:** [25-low-power-mode.md](25-low-power-mode.md) — Phase 0 完了時点
- 計測手順: [25-low-power-phase0-runbook.md](25-low-power-phase0-runbook.md)
- 前提実測: [power-measurement.md](power-measurement.md)（#31 パターン D）
- 一次資料: [datasheets/](datasheets/)

---

## 1. 調査の位置づけ

| Issue | 役割 | 状態 |
|---|---|---|
| #6 | MQTT・Deep Sleep 骨格 | 完了 |
| #31 | 消費電力実測（U200） | 完了 |
| #32 | SyncLedger・送信サイクル | 完了 |
| **#25** | 低消費電力運用（周辺電源・変化時送信） | **Phase 0 完了 → [結論](25-low-power-mode.md)** |

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
| 手元センサに白 LED（Fill-light）が実装されている | 実機観察 + [基板写真](datasheets/grove-color-sensor-v3-board.png) | confirmed |
| `sensor.cpp` は VEML6040 `SD_ENABLE`（SD=0）固定 | `firmware/src/sensor.cpp` | confirmed |
| `mustPublish()` は骨格のみ（`PSS_CHANGE_ONLY_SEND` 未定義時は常に true） | `firmware/src/main.cpp` | confirmed |
| LTE 切断時 `disconnectTransport()` → `modem.poweroff()` | `firmware/src/transport.cpp` | confirmed |
| SyncLedger（NVS）に `lastConfirmedStatus` あり | `firmware/src/sync_ledger.cpp` | confirmed |

### Phase 0 着手後に閉じた項目（2026-07-10）

| 項目 | 結論 | 根拠 |
|---|---|---|
| UART / I2C ポート VCC | **3.3 V レール直結・昇圧なし** | [Shield SCH](datasheets/grove-shield-xiao-v1.0-sch.pdf) |
| Grove ポート VCC の GPIO 制御 | **なし**（Deep Sleep 中も給電） | 同上 |
| センサ白 LED と SD ビット | VEML6040 に LED ピンなし → **SD=1 では消えない見込み** | [VEML6040 DS](datasheets/veml6040.pdf) |

### Phase 0 で閉じた項目（2026-07-10 — confirmed）

| 項目 | 結論 |
|---|---|
| **22 mA の機器別内訳** | **LTE 支配的**（+21〜28 mA）。ベース 1.60 / センサ +0.15 / フル 20〜30 mA |
| **`modem.poweroff()` 後の実態** | 専用ファームで `NORMAL POWER DOWN` 応答あり。NETLIGHT は **3 s 点滅継続** → Grove LTE Unit は実質停止していない |

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

## 7. Phase 0（設計 PR の前提）

**手順の正:** [25-low-power-phase0-runbook.md](25-low-power-phase0-runbook.md)

Phase 0 の問いは 1 つ: **待機 22 mA はどこで消えているか。** 初版のチェックリスト（部品同定・電圧テスター・SD=1 計測など）は、BOM・動作実績・保存済み回路図で答えが出るものを含んでいたため縮小した（§3 参照）。

### 計測 1 結果（2026-07-10 — confirmed）

| # | 構成 | 待機 I (mA) | Δ | ログ |
|---|---|---|---|---|
| 1 | XIAO + Shield | 1.60（CSV 1.65） | — | [capture-phase0-N.csv](../tools/power-logger/capture-phase0-N.csv) |
| 2 | + センサ | 1.75 | +0.15 | 同上（連続記録） |
| 3 | + LTE（フル） | 20〜30 往復（CSV 平均 **23.2**） | +21〜28 | 同上 |

**所見:** #31 の待機 ≈22 mA は **LTE-M がほぼ全量**。XIAO+Shield+センサだけなら **≈1.75 mA**。20〜30 mA の往復は **≈21 / ≈31 mA の 2 水準**（NETLIGHT 点滅と整合）— U128 Unit がスリープ中も mA 級で動き続けている補強証拠。

**異常区間:** ログ先頭はバッテリー逆接続（負電流 → ≈1 A スパイク）。以降の区間のみ有効。

**Phase 2 暫定優先度（計測 2 待ち）:** LTE 停止 > mustPublish >> センサ VCC / SD=1

### 計測 2 結果（2026-07-10 — confirmed）

| 項目 | 結果 |
|---|---|
| Serial | `sleep reason=confirmed` まで OK。[phase0-poweroff.log](../tools/power-logger/phase0-poweroff.log) に **`AT+CPOWD=1` / `NORMAL POWER DOWN` 無し** |
| NETLIGHT（スリープ中） | **3 秒点滅継続**（消灯せず）— 実機目視 2026-07-10 |
| 判定 | 通常ファームでは `poweroff()` の成功確認不可。NETLIGHT から **U128 Unit は停止していない** |

### poweroff 専用ファーム結果（2026-07-10 — confirmed）

`xiao-s3-lte-poweroff-test` で Deep Sleep なしに attach → poweroff → 30 s 観察 → recover を実施（[phase0-poweroff-test.log](../tools/power-logger/phase0-poweroff-test.log)）。

| 項目 | 結果 |
|---|---|
| attach | OK |
| `powerOffLteModem()` | **true (`NORMAL POWER DOWN`)** — cycle 1: 1408 ms、cycle 2: 17402 ms |
| NETLIGHT | **3 秒点滅継続**（ユーザー目視。「今も点滅」） |
| recover attach | OK |

**結論:** AT コマンド上の SIM7080G poweroff は成功応答を返すが、M5Stack U128 Unit としては青 NETLIGHT が消えず、計測 1 の mA 級待機も残る。Grove 接続のままでは LTE Unit の VCC を切れない。

**PoC 方針（2026-07-10）:** この状態では **LTE を実証のコアに据えない**。専用基板は要件としては明確だが **優先度低**（LoRaWAN 等の経路評価が先）。詳細は [25-low-power-mode.md](25-low-power-mode.md)。

### 強化 CPOWD 追試（2026-07-10 — confirmed）

`CNACT/CGATT` 切断 → `CPOWD=1` → 2 s 待機 → AT post-check → `Serial1.end()` 実装後:

| 項目 | 結果 |
|---|---|
| Serial | `cpowd=yes` **`modemSilent=yes`** |
| NETLIGHT | **3 s 点滅継続**（消灯せず） |
| U200 | **50〜120 mA 往復**（旧待機 ≈23 mA より悪化） |

ログ: [phase0-poweroff-v2.log](../tools/power-logger/phase0-poweroff-v2.log)

**判定:** UART 無応答だけでは真の power-off にならない。Grove U128 上のソフト電源断追試はここで打ち切り。

### 済（2026-07-10）

- [x] コードレビュー — スリープ前 `AT+CPOWD=1` 送信・`NORMAL POWER DOWN` 待ち。`disconnectTransport()` は戻り値未使用。`PSS_LTE_KEEP_MODEM` は未配線
- [x] 一次資料 — [datasheets/](datasheets/) に VEML6040 DS / Shield SCH / SIM7080G HW Design を保存（V3 センサ SCH・U128 SCH は未取得 — 内訳判明後に必要なら入手。[datasheets/README.md](datasheets/README.md)）
- [x] Grove VCC 3.3 V・昇圧なし・スイッチなし（Shield SCH で確定 — §3）

---

## 8. Phase 0 後の方針（2026-07-10 確定）

| 優先度 | 内容 | 備考 |
|---|---|---|
| 記録 | [25-low-power-mode.md](25-low-power-mode.md) | **済** |
| 高 | LoRaWAN（Grove Wio-E5）の待機・送信評価 | モジュール到着済（技適付き） |
| 中 | `mustPublish` 実装 | Wi-Fi / LoRa でも有効 |
| 低 | 専用基板 / LTE VCC 制御 | LTE 電池運用を再検討する段階まで保留 |
| 見送り | Grove 上での LTE poweroff ファーム修正を主戦場にする | Phase 0 で効果限定的と判断 |

LTE-M は **通信パイプライン実証**（SORACOM → AWS IoT）としては残すが、**電池 PoC の主経路にはしない**。

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
12. Grove 構成で実現できない VCC 切断を、既存配線で可能な対策のように扱った

---

## 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-07-10 | 初版。#25 事前調査・品質問題の撤回・Phase 0 チェックリスト |
| 2026-07-10 | Phase 0 着手: `datasheets/` 保存、`25-low-power-phase0-runbook.md`、7-D コードレビュー、7-F 一部完了 |
| 2026-07-10 | Phase 0 計画を全面縮小: 既知事項をチェックリストから外し、**22 mA 内訳 + poweroff 成否の 2 点**に絞る |
| 2026-07-10 | VEML6040 DS（Seeed 版）・Grove V3 基板写真を `datasheets/` に保存 |
| 2026-07-10 | Phase 0 計測 2 + poweroff 専用ファーム完了: `NORMAL POWER DOWN` 応答あり、NETLIGHT 3 s 点滅継続 → Grove LTE Unit は停止せず |
| 2026-07-10 | Phase 0 完了。`25-low-power-mode.md` 起票。LTE を PoC コアから外す・専用基板は優先度低を明記。Wio-E5 到着 |
| 2026-07-10 | 強化 CPOWD 追試: modemSilent=yes でも NETLIGHT 点滅・U200 50〜120 mA — ソフト電源断は Grove では不成立 |
