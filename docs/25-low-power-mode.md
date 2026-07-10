# Issue #25 低消費電力運用 — 結論（Phase 0 時点）

Issue #25 の **Phase 0（実機・一次資料・計測）完了時点**の記録。  
Grove 構成での電源挙動と、PoC 経路選択への含意をまとめる。

- 関連 Issue: [#25](https://github.com/makeOurCity/parking-status-sensor/issues/25)
- 調査過程: [25-low-power-investigation.md](25-low-power-investigation.md)
- 計測手順・生ログ: [25-low-power-phase0-runbook.md](25-low-power-phase0-runbook.md)
- 前提実測: [power-measurement.md](power-measurement.md) §6（#31 パターン D）

**送信ポリシー（変化時のみ・初回必送・heartbeat 不要）** の詳細は Issue #25 本文が正。本ドキュメントは **電源・ハード構成・経路選択** に限定する。

---

## 1. Phase 0 で確定した事実（confirmed）

### 1.1 待機電流の機器別内訳（U200 抜き差し、2026-07-10）

| 構成 | 待機電流 (mA) | 寄与 |
|---|---|---|
| XIAO ESP32S3 + Grove Shield | **1.60**（CSV 平均 1.65） | ベース |
| + Grove Color Sensor V3（白 LED 込み） | **1.75** | **+0.15** |
| + M5Stack SIM7080G CAT-M Unit（フル） | **20〜30** 往復（CSV 平均 **≈23.2**） | **+21〜28** |

ログ: [capture-phase0-N.csv](../tools/power-logger/capture-phase0-N.csv)

**結論:** [#31](power-measurement.md) で観測した待機 **≈22 mA のほぼ全量は LTE-M モジュール**。XIAO + Shield + センサだけなら **≈1.75 mA** であり、センサ（Fill-light 白 LED 含む）は待機の主因ではない。

20〜30 mA の秒オーダー往復は **≈21 mA / ≈31 mA の 2 水準**（NETLIGHT 3 s 点滅と整合）。スリープ中も U128 Unit が mA 級で動き続けている。

### 1.2 Grove Shield の電源（回路図で確定）

| 事実 | 根拠 |
|---|---|
| Grove ポート VCC = **3.3 V レール直結**・昇圧なし | [grove-shield-xiao-v1.0-sch.pdf](datasheets/grove-shield-xiao-v1.0-sch.pdf) |
| ポートごとの **GPIO 電源スイッチなし** | 同上 |
| `esp_deep_sleep()` 中も Grove VCC は **自動では落ちない** | 同上 + `firmware/README.md` |

### 1.3 `modem.poweroff()` と実機の乖離

| 試験 | Serial | NETLIGHT（スリープ中） |
|---|---|---|
| 通常ファーム `xiao-s3-aws-lte` | `sleep reason=confirmed` まで OK。**`NORMAL POWER DOWN` ログなし** | **3 s 点滅継続** |
| 専用ファーム `xiao-s3-lte-poweroff-test`（旧シーケンス） | **`NORMAL POWER DOWN` 応答あり** | **3 s 点滅継続** |

ログ: [phase0-poweroff.log](../tools/power-logger/phase0-poweroff.log)、[phase0-poweroff-test.log](../tools/power-logger/phase0-poweroff-test.log)

### 1.4 強化 CPOWD シーケンス（2026-07-10 追試 — confirmed）

ファーム改善後（`CNACT/CGATT` 明示切断 → `AT+CPOWD=1` → 2 s 待機 → AT 無応答 post-check → `Serial1.end()`）の `xiao-s3-lte-poweroff-test` 実機結果:

| 項目 | 結果 |
|---|---|
| `cpowdAccepted` | **yes** |
| `modemSilent`（post-check `AT` 無応答） | **yes** |
| NETLIGHT（shutdown 後 30 s 観察） | **3 s 点滅継続（消灯せず）** |
| U200（shutdown 観察中） | **50〜120 mA 往復**（旧 Phase 0 待機 ≈23 mA より高い） |
| recover attach | OK（UART 再開 + AT で復帰） |

ログ: [phase0-poweroff-v2.log](../tools/power-logger/phase0-poweroff-v2.log)

**結論:** **UART 上の「silent」は RF/NETLIGHT の停止を意味しない。** M5 U128 上では強化 CPOWD でもチップは登録済みネットワーク状態（Table 14: 64 ms / 3000 ms）のまま。電流も待機改善どころか悪化しうる。**Grove 構成でのソフト電源断は電池運用の解にならない** — Phase 0 判断を補強する結果。

**解釈:** `NORMAL POWER DOWN` + UART 無応答は「ホストから見た通信停止」にとどまり、SIM7080G の RF サブシステムと NETLIGHT 駆動は VCC 供給のまま動作継続。U128 キャリア基板の電源・起動回路の影響も否定できない（回路図未取得）。

### 1.5 センサ周り（参考）

| 事実 | 根拠 |
|---|---|
| 手元 V3 基板に Fill-light（白 LED）あり | 実機観察 + [基板写真](datasheets/grove-color-sensor-v3-board.png) |
| VEML6040 の SD ビットはチップ内部のみ。SD=1 でも基板 LED は消えない見込み | [veml6040.pdf](datasheets/veml6040.pdf) |
| 現行ファームは `SD_ENABLE`（SD=0）固定 | `firmware/src/sensor.cpp` |

待機 +0.15 mA のため、Phase 0 時点ではセンサ電源対策の優先度は低い。

---

## 2. Grove PoC 構成の限界（電源）

```
esp_deep_sleep() が止めるのは ESP32 本体のみ
  → Grove Shield の 3.3 V / ポート VCC は維持
  → UART に接続した LTE モジュールは VCC 供給され続ける
  → ソフトの poweroff() 成功応答・UART 無応答と、NETLIGHT・実機電流は一致しない（§1.4）
```

**Grove ケーブル接続のまま LTE Unit の VCC をハード遮断することはできない。** これは配線上の制約であり、Phase 0 で実測・観察により確認した。

---

## 3. PoC 経路の位置づけ（現時点）

### 3.1 LTE-M を実証のコアに据えない

Phase 0 の結果から、**Grove + LiPo + LTE-M での電池長期運用は現実的でない**（待機 ≈23 mA → [#31](power-measurement.md) の連続稼働目安 ≈7 日は LTE 待機が支配的）。

LTE-M 経路は以下の位置づけにとどめる:

| 観点 | 内容 |
|---|---|
| 到達性の実証 | キャリア網・SORACOM・AWS IoT までの **通信パイプライン検証**としては有効（[#30](lte-active-investigation.md) 等） |
| 電池 PoC の主経路 | **現時点では採用しない** |
| Grove 上での待機対策 | **強化 CPOWD 含めソフトのみでは不可**（§1.4）。PSM は未実機 |

README §4.3 の経路優先順位（LoRaWAN > LTE > Wi-Fi）は、**電池運用**の観点では Phase 0 が裏付ける。ゲートウェイが置ける現場では LoRaWAN を優先する方針は維持する。

### 3.2 専用基板の必要性 — 優先度低

LTE 待機電流を落とすには **LTE Unit の VCC を ESP32 から制御できる配線**（専用基板・リレー・Load Switch 等）が必要になる。Phase 0 でその要件は明確になった。

ただし **現時点では LTE を PoC コアに据えない**ため、専用基板設計・製作は **優先度低**。LoRaWAN や Wi-Fi 経路の評価が先。将来 LTE を電池運用で再検討する段階になったら改めて Issue を起票する。

---

## 4. 引き続き有効なソフト対策（#25）

電源内訳と**独立**に、送信回数削減は有効。Issue #25 コメント確定分:

| 項目 | 内容 |
|---|---|
| 送信条件 | `status` 変化 + `pendingValid` |
| unknown 遷移 | 送信する |
| heartbeat | 当面不要 |
| 初回起床 | 必ず 1 回送信（`lastConfirmedBoot == 0` 対応が未実装 — 実装時に要対応） |
| lastStatus | NVS（SyncLedger） |

`mustPublish()` は骨格のみ（`PSS_CHANGE_ONLY_SEND` 未定義時は常に true）。**Wi-Fi / LoRaWAN 経路でも適用する**。

active 時間短縮（モデム TLS 等）は [#30](lte-active-investigation.md) で実施済み。待機 mA の主因にはならない。

---

## 5. 次の評価（Phase 0 以降）

| 項目 | 内容 | 状態 |
|---|---|---|
| **LoRaWAN** | Grove Wio-E5 の待機・送信評価 | モジュール到着済（技適付き） |
| **mustPublish 実装** | 変化時のみ送信の本番有効化 | [#39](https://github.com/makeOurCity/parking-status-sensor/issues/39) |
| **README §6.2** | LoRa 実測後に比較表を更新 | 一部済 |
| **Grove LTE ソフト電源断** | 強化 CPOWD 追試済 — **不成立**（§1.4） | 打ち切り |
| **専用基板** | LTE 電池運用再検討時 | **保留・優先度低** |

LoRaWAN 評価の最小手順: UART 応答確認 → U200 3 構成計測 →（ゲートウェイがあれば）1 パケット送信。

---

## 6. 一次資料

[datasheets/](datasheets/) に Phase 0 で保存した資料一覧（VEML6040 DS、Shield SCH、SIM7080G HW Design、V3 基板写真等）。

---

## 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-07-10 | Phase 0 完了に伴い初版。LTE を PoC コアから外す判断・専用基板優先度低を明記 |
| 2026-07-10 | §1.4 追記: 強化 CPOWD で modemSilent=yes でも NETLIGHT 点滅・U200 50〜120 mA — ソフト電源断は不成立 |
