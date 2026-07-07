# 消費電力実測と LTE-M 処理時間の切り分け（Issue #31・暫定）

Issue [#31](https://github.com/makeOurCity/parking-status-sensor/issues/31) の調査メモ。  
#25（低消費電力運用）の設計再開前に、**実測手段の確立**と **LTE-M active 時間の分解**を行う。

- 関連: #25, #6, #30
- 正（試算）: [README.md §6.2](../README.md#62-消費電力連続稼働の試算)
- 実機ログ: [firmware/README.md](../firmware/README.md)「一晩通し試験（2026-07-07）」

---

## 1. 現状の課題

### 1.1 バッテリーチェッカーでは不足

LiPo 4,400mAh + バッテリーチェッカーでは、短時間試験で **80% / 4.00V 前後がほぼ不変** に見える。

| 分からないこと | #25 への影響 |
|---|---|
| 1 サイクルあたり何 mAh か | 起床間隔・変化時のみ送信の試算根拠がない |
| Deep Sleep 中の実電流 | スリープ設計の優先度が判断できない |
| LTE-M 通信中のピーク・平均 | README §6.2 の初期試算（active 5〜10秒）との差を説明できない |
| Grove 5V / LTE モジュールのスリープ漏れ | `modem.poweroff()` 後も青 LED 点滅 → 完全停止していない疑い |

### 1.2 一晩通し試験（2026-07-07）の CloudWatch 生ログ分析

構成: LiPo → Grove Shield BAT、`xiao-s3-aws-lte`（TLS 8883 / QoS1）、SORACOM plan-D、AWS IoT Core。  
出典: CloudWatch Logs `/aws/lambda/parking-status-bridge`（受信ペイロードを verbatim 記録）。生ログ 87 レコードを抽出して集計。

**要約値ではなく生データで見ると、事象は「2 フェーズの明確な切替」だった**（従来メモの「一部欠落」「原因不明の増加」を訂正）。

| 区間 | boot | 件数 | `transport` | `networkConnectMs` | `mqttConnectMs` | `activeMs`（中央値） |
|---|---|---|---|---|---|---|
| 起動直後（power_on 連発） | 1 ×約6回 | 9 | 一部 lte / 欠落 | 3.6〜12.9秒 | 34〜35秒 | 41〜111秒（ばらつき大） |
| **フェーズ1（安定）** | 2〜42 | 41 | **lte（全件あり）** | **2474ms 固定** | **約34.2秒** | **約68秒** |
| **フェーズ2** | 43〜75+ | 36 | **完全に欠落** | — | — | **約128秒**（先頭 185秒） |

観測事実（生データで確定）:

- **network メトリクス欠落は散発ではなく、boot 43 で 100% 切り替わる**。フェーズ1は全件 `transport` 等あり、フェーズ2は全件が `{deliveryConfirmed, publishAttempts, mqttQos}` のみ。
- フェーズ2の network オブジェクトは **`flushOutbox` が書く 3 フィールドと完全一致**（§4.4）。
- **1 サイクル = 1 件**が全 boot で成立（boot 43〜75 欠番なし）。データ欠損はない。
- フェーズ2で active が **約 1.9 倍**（68秒→128秒）。128秒 ≈ `PSS_CYCLE_MAX_ACTIVE_MS`(120秒) + 約8秒。
- **timestamp は LTE 定常サイクルで全件 `null`**（#30）。→ §4.2 の重要な含意。
- 起動時に **power_on が約6回連発**（クリーンな1本の連続運転ではない）。冷間起動の LTE 登録は 41〜111秒とばらつく。
- SORACOM 課金 385円 / 約10時間、`deliveryConfirmed: true` は全件。

---

## 2. 測定手段（機材選定）

### 2.0 採用品（注文済み）

| 項目 | 内容 |
|---|---|
| 品名 | **M5Stack INA226 電流電圧測定ユニット（絶縁型・±1A）** |
| 型番 | **M5STACK-U200-1A**（[スイッチサイエンス #10736](https://www.switch-science.com/products/10736)） |
| 価格 | ¥1,584（税込） |
| 注文日 | 2026-07-07 |

±10A 版（U200）ではなく **±1A 版** を選定。分解能 32 µA で active 区間（100〜300 mA）の積算に向く。  
Deep Sleep の精密計測は手持ちテスターで spot check する（§2.5）。

### 2.1 要件

| 項目 | 目安 |
|---|---|
| 測定レンジ | Deep Sleep **µA 級** 〜 LTE 送信 **500mA〜1A ピーク** |
| 電圧 | LiPo 3.7V（放電中 3.0〜4.2V）。Grove Shield 経由で 5V 昇圧あり |
| 記録 | 波形 + **積算 mAh**（1 サイクル単位で切り出せること） |
| 接続 | **BAT+ / BAT− 直列**（USB 給電と並列にならないこと） |

### 2.2 候補比較（検討記録）

| 候補 | 概算 | 長所 | 短所 | 判定 |
|---|---|---|---|---|
| **M5STACK-U200-1A** | ¥1,584 | ±1A・32µA 分解能・絶縁・ヒューズ | ロガー MCU 別途。Deep Sleep は △ | **採用** |
| Nordic PPK2 | 約 ¥15,000 | µA〜1A、PC 波形・mAh 積算 | PoC 予算に対して高い | 見送り |
| INA226 ブレークアウト + MCU | 約 ¥1,100 | 安価 | 配線・絶縁は自前 | U200-1A で代替 |
| テスター（mA / µA レンジ）直列 | 既所持なら ¥0 | Deep Sleep spot check | 積算・波形不可 | **補助** |
| USB 電流計（UM25 等） | 約 ¥2,000〜4,000 | 手軽 | LiPo 経路に使えない | ✕ |

### 2.3 配線: U200-1A + ロガー XIAO

U200-1A は単体では動かない。**計測対象（PoC 試作機）とは別の XIAO** を I2C ロガーに使う。

```
[LiPo +] ──→ [U200-1A IN+] ──→ [U200-1A IN-] ──→ [Grove Shield BAT+]
[LiPo -] ──────────────────────────────────────→ [Grove Shield BAT-]

[ロガー XIAO]          [U200-1A HY2.0-4P]
  5V (USB) ──────────── 5V
  GND      ──────────── GND
  D4/SDA   ──────────── SDA    (XIAO: GPIO5)
  D5/SCL   ──────────── SCL    (XIAO: GPIO6)
```

| 注意 | 内容 |
|---|---|
| 並列給電禁止 | 計測中は PoC 試作機の **USB を外す**（LiPo 経路のみ） |
| ロガー給電 | ロガー XIAO は **USB 給電**（DUT と電源分離。U200-1A は絶縁型） |
| 端子 | 電源直列は付属 **VH3.96 4P 端子**（IN+ / IN−）。極性をテスターで確認 |
| 過電流 | **1 A 超**で自己復帰ヒューズ溶断。溶断したら記録し再試験 |
| I2C アドレス | **0x41**（M5Stack 公式: [Unit INA226-1A](https://docs.m5stack.com/ja/unit/Unit_INA226-1A)） |

### 2.4 ロガー（到着後に実装）

| 項目 | 方針 |
|---|---|
| ハード | 予備 XIAO ESP32S3 + USB Serial |
| ライブラリ | M5Stack `M5Unit-METER` または INA226 直接 I2C |
| サンプリング | **10〜20 Hz**（active 70〜130秒なら十分。100 Hz まで可） |
| 出力 | Serial CSV: `ms,current_mA,bus_mV,power_mW` |
| 積算 | ホスト側（Python / スプレッドシート）で `Σ(current × Δt)` → mAh |
| 同期 | CloudWatch / Serial の `bootCount`・`activeMsBeforePublish` と CSV 時刻を突合 |

最初の確認手順（到着当日）:

1. ロガー単体 + U200-1A で I2C 応答・電流 0 付近を確認
2. テスターと直列し、既知負荷（例: 330Ω）で読み値を spot check
3. PoC 試作機を **パターン B**（通信なし）→ **パターン D**（LTE 1 回）の順で 1 サイクルずつ

### 2.5 記録する指標

| 指標 | 用途 |
|---|---|
| **平均電流（mA）** | Deep Sleep / active 各フェーズの目安 |
| **積算 mAh（1 サイクル）** | README §6.2 試算の更新 |
| **ピーク電流（mA）** | LTE 送信・昇圧回路の設計確認 |
| バッテリーチェッカー（% / V） | **長期トレンドの補助のみ**（短時間試験の主指標にしない） |

ファームウェアの `power.activeMsBeforePublish` 等と **時刻同期** させ、波形上の active 区間と突き合わせる（§4 参照）。

---

## 3. 実測パターン（チェックリスト）

最低限、以下を **個別に** 測る。混在させない。

| # | パターン | ビルド / 設定 | 目的 |
|---|---|---|---|
| A | Deep Sleep のみ | 通信なしの最小スケッチ、または `sensor-error` 経路 | スリープ底電流 |
| B | 起床 → センサ → 即 Sleep | Wi-Fi/LTE 無効 | センサ + MCU active のみ |
| C | Wi-Fi + ローカル MQTT 1 回 | `xiao-s3` + Mosquitto | Wi-Fi 経路の baseline |
| D | LTE-M + AWS 1 回（通常） | `xiao-s3-aws-lte` | 現行 PoC 経路 |
| E | LTE active 120秒超 | 一晩試験の再現条件 | boot 43 以降の異常 |
| F | スリープ中・青 LED 点滅時 | `modem.poweroff()` 後 | Grove 5V 漏れの確認 |

各パターンで記録する項目:

- [ ] 波形 CSV / スクリーンショット
- [ ] 1 サイクル mAh
- [ ] 対応する MQTT `power.*` / `network.*`（あれば）
- [ ] 備考（CSQ、時刻、bootCount）

---

## 4. LTE-M 処理時間の分解（コード + ログ）

### 4.1 ファームウェア上のサイクル（`runCycle`）

```
cycleStart
  ├─ initSensor / readSensor          … 未計測（数秒未満想定）
  ├─ connectTransportWithRetry        … networkConnectMs + mqttConnectMs
  │    ├─ beginLteUartAndModem        … delay(1000) + plan-D 初回のみ ~10秒+
  │    ├─ waitForNetwork              … 最大 PSS_LTE_NETWORK_TIMEOUT_MS (120s)
  │    ├─ syncClock (TLS 前)          … 最大 15s
  │    └─ connectMqtt (TLS 含む)      … mqttConnectMs（実測 ~35s）
  ├─ syncClock (再)                   … 成功済みなら即 return
  ├─ flushOutbox                      … 未送信キューがあれば追加 active
  ├─ publishCurrentWithRetry          … publishMs（**MQTT ペイロード未出力**）
  └─ disconnectTransport / sleepNow   … modem poweroff 等（**未計測**）
```

`xiao-s3-aws-lte` の主なタイムアウト（`platformio.ini`）:

| 定数 | 値 |
|---|---|
| `PSS_LTE_NETWORK_TIMEOUT_MS` | 120,000 ms |
| `PSS_CYCLE_MAX_ACTIVE_MS` | 120,000 ms |
| `PSS_MQTT_CONNECT_TIMEOUT_MS` | 30,000 ms |
| `PSS_TIME_SYNC_TIMEOUT_MS` | 15,000 ms |

### 4.2 フェーズ1（約68秒）の内訳 — NTP が最大級の浪費

生データ: `networkConnectMs`=2474ms（固定）、`mqttConnectMs`≈34.2秒。残り約31秒が未出力だった。  
コードを追うと、この「残り31秒」の正体はほぼ **NTP 同期の空振り**である。

`syncClock()` は `configTime()` = **ESP32 lwip の SNTP** を使う（`transport.cpp`）。SNTP は WiFi netif 経由でしか送信されず、**LTE-only（`PSS_LTE_ONLY=1` で WiFi OFF）では経路がない → 必ず 15秒タイムアウト**。しかも 1 サイクルで **2 回**呼ばれる:

1. `connectLte()` 内（TLS 前、line 298）… 15秒
2. `runCycle()` 内（接続後）… 15秒

これが **timestamp 全件 null（#30）** の直接原因であり、同時に約30秒の active を浪費している。

| 区間 | 値 | 根拠 | ペイロード |
|---|---|---|---|
| LTE 登録 + データ接続 | ~2.5 s | 実測 `networkConnectMs`=2474 | あり |
| **syncClock #1（TLS 前）** | **~15 s（空振り）** | `PSS_TIME_SYNC_TIMEOUT_MS`=15000・SNTP に LTE 経路なし | 未出力 |
| TLS + MQTT connect | ~34 s | 実測 `mqttConnectMs` | あり |
| **syncClock #2（接続後）** | **~15 s（空振り）** | 同上（time 未設定なので再度満了） | 未出力 |
| publish + poweroff + sensor 等 | ~2 s | 差分 | 未出力 |
| **合計** | **≈68.5 s** | 実測中央値 68.2s と一致 | `activeMsBeforePublish` |

**含意（重要）**: `mqttConnectMs`(34s) と NTP 空振り(30s) の 2 つで active の **約94%**。  
→ **#30 を直せば active は約68秒→約38秒（約44%減）** になる見込み。これは経路変更より大きい効果で、#25 より先に着手する価値がある。  
（確証のため `syncClockMs` / `publishMs` をペイロードに追加して裏取りする。）

### 4.3 boot 43 以降（約128秒）= outbox にラッチした劣化モード

生データで確定した事実（§1.2）:

- boot 43 以降は **全件が `flushOutbox` 由来のペイロード形状**（network が 3 フィールドのみ）。
- active が約68秒→約128秒（≈ `PSS_CYCLE_MAX_ACTIVE_MS` 120秒 + α）。
- それでも 1 サイクル 1 件・欠番なし・`deliveryConfirmed: true`。

これらを `main.cpp` の `runCycle` フローと突き合わせると、次の**自己保持ループ**で説明できる:

1. boot 43 で直接 publish（`publishCurrentWithRetry`）の PUBACK 確認が初めて失敗 → 現サイクルのペイロードを outbox に enqueue。
2. 以降の各サイクル: 接続 → `flushOutbox` がキューの1件を送信（成功 = 受信されるのはこれ。network は 3 フィールドに潰れる）→ 続く直接 publish が再び失敗 → 予算(120秒)まで再接続を繰り返し → 現ペイロードを再 enqueue。
3. outbox 深さ 1 のまま、毎サイクル「flush 成功 + 直接 publish 失敗」を反復。**データは（1サイクル遅れで）届くが active が恒常的に約2倍**。

つまり boot 43 の active 増加と network 欠落は**別々の異常ではなく同一現象**。従来メモの H1（ネットワークタイムアウト主因）は生データと不整合で、**主因は outbox/リトライ状態機械**。

未確認点（要調査）:

- [ ] なぜ同一サイクル内で flush は成功し直接 publish は失敗するのか（接続が publish 後に切れる／セッション再利用の不整合の疑い）
- [ ] boot 43 の最初の確認失敗の引き金（電波状態 / TLS セッション / broker 側切断）

### 4.4 `network.*` 欠落の原因（確定）

`flushOutbox` は `main.cpp` で:

```cpp
JsonObject network = doc["network"].to<JsonObject>();  // ← 既存 network を破棄して空オブジェクト化
network["deliveryConfirmed"] = true;
network["publishAttempts"] = attempt;
network["mqttQos"] = config::kMqttQos;
```

`.to<JsonObject>()` は既存キーを消すため、enqueue 時に入っていた `transport`/`networkConnectMs`/`mqttConnectMs` が**丸ごと消える**。フェーズ2で受信した network が常に 3 フィールドだった事実と完全一致する（Lambda 側は wifi/lte 行を full で通しており、欠落は端末側）。

改善方針:

- [x] **`flushOutbox` は network を破棄せず既存にマージ**（`doc["network"].as<JsonObject>()` を使用）→ 実装済み。outbox 再送でも transport/timing が残る
- [x] **`publishMs` をペイロードに追加** → 実装済み（§4.2 の空白の一部を裏取り）
- [ ] 直接 publish 失敗の再現条件を Serial（debug ビルド）で採取（Fix B・要実機再現）

---

## 5. 設計評価（中立）

生ログ分析を踏まえ、既存設計の妥当性を賛否込みで整理する。

### 5.1 妥当に機能している点

- **信頼性**: 劣化モードでも欠番ゼロ・全件 `deliveryConfirmed`。QoS1 + outbox の at-least-once は効いている。
- **plan-D キャッシュ**: `ltePlanDReady` を RTC 保持し毎回の再設定を回避。定常 `networkConnectMs` は 2.5秒で安定（設計意図どおり）。
- **PoC 目的（満空を読みクラウドへ）としては成立**している。

### 5.2 見直すべき点（データが示す優先順）

| 優先 | 論点 | 種別 | 効果の見積り | 状態 |
|---|---|---|---|---|
| **1** | **NTP 空振り 2×15秒**（#30 と同根）。`configTime` は LTE 経路で機能しない | **バグ** | active 約68→38秒（約44%減）。最大の即効 | **修正済**（要実機確認） |
| **2** | **outbox ラッチ劣化モード**（§4.3）。1度の確認失敗で active が恒常2倍 | **バグ/堅牢性** | フェーズ2の約1.9倍を解消 | 未（要実機再現） |
| **3** | `flushOutbox` が network を破棄（§4.4） | **バグ（可観測性）** | 劣化時に診断可能に | **修正済** |
| **4** | 毎 wake フル TLS ハンドシェイク ~34秒 | **アーキ選択** | 経路/間隔で amortize（下表） | 実測後に判断 |

論点1・3をコードで対処済み。論点2は状態機械の再現が必要（推測での書き換えは避ける）。論点4は実測後に方式比較。

**Fix A の実装**（`transport.cpp`）: lwIP SNTP（`configTime`）を廃し、`modem.getNetworkTime()`（`AT+CCLK`／NITZ）で system clock を設定。NITZ 未提供時は `modem.NTPServerSync()`（`+CNTP`・データベアラ経由で LTE でも動作）にフォールバック。`syncClock()` は Wi-Fi 未接続時に lwIP SNTP を試みないようガードし、`runCycle` 側の 2 回目呼び出しの空振りも解消。#30（timestamp=null）も同時に解消見込み。

### 5.3 方式比較（論点4・実測後に判断）

| 案 | 削減対象 | 実測で見るポイント |
|---|---|---|
| 現行: Deep Sleep + 毎回 modem poweroff + ESP32 TLS | mqttConnect ~34s | パターン D の mAh |
| SORACOM Beam / Funnel（端末 TLS 省略） | mqttConnectMs (~34s) | TLS 手前後の電流・時間 |
| モデム内蔵 MQTT / 接続維持 | 毎回 attach/detach | スリープ中漏れ vs active 短縮 |
| 送信間隔を延ばす（TLS コストを希釈） | サイクル数 | §6.2 電池試算の再計算 |
| Grove 5V ハード切断 | スリープ中 ~数十 mA? | パターン F |
| Wi-Fi / LoRaWAN 優先 | LTE active 全体 | パターン C vs D |

### 5.4 中立的な結論

- **満空 PoC の技術成立性は問題なし**。ただし **#25（低消費電力）の前提として現状の LTE active は電池試算の基準にできない**。
- ネックは「LTE-M が遅い」より **(a) LTE で動かない NTP を毎回叩いている（30秒）** と **(b) outbox ラッチ（+60秒）** の 2 つの**ソフト要因**。合わせれば理論上 active 約128秒→約38秒まで縮む可能性がある。
- したがって **方式変更（Beam / LoRaWAN 等）より先に、#30 と outbox 状態機械の修正を優先**するのが妥当。機材（U200-1A）到着前に着手できる。

---

## 6. 次のアクション

### すぐできる（機材なし）

| 優先 | タスク | 状態 |
|---|---|---|
| 1 | 本ドキュメントで機材候補・配線・パターンを固定 | 本稿 |
| 2 | boot 43 前後の CloudWatch 生 JSON を Issue #31 に貼る | 未 |
| 3 | ファームウェア: `publishMs` 追加メトリクス | **済** |
| 4 | `flushOutbox` の network メトリクス保持 | **済** |
| 5 | Fix A（モデム時刻）実装 | **済**（3 env ビルド確認） |
| 6 | Fix A/C + モデム TLS を実機で再走し active・timestamp を再測定 | **済**（§7） |
| 7 | Fix B（outbox ラッチ）を debug ビルドで再現・修正 | 未 |
| 8 | 本番ビルド（Deep Sleep 300秒）LiPo 長時間試験 | **進行中**（boot 1 受信確認） |

### 機材入手後（U200-1A 到着〜）

| 優先 | タスク | 状態 |
|---|---|---|
| 5 | U200-1A 到着・§2.3 配線・ロガー動作確認 | 注文済み・到着待ち |
| 6 | ロガー用スケッチ（INA226 CSV 出力） | 未 |
| 7 | パターン B → D を 1 サイクルずつ実測 | 未 |
| 8 | パターン A / F（Deep Sleep・青 LED）はテスター併用 | 未 |
| 9 | README §6.2 / firmware README の試算更新 | **一部済**（active 時間・改善前後。mAh は U200-1A 後） |

### 完了条件（Issue #31）

- [x] 電流計・電源ロガーを使った測定方法が決まっている → **§2.0 M5STACK-U200-1A + ロガー XIAO**
- [ ] 1 サイクルあたりの消費量を測れる → 到着・配線後
- [x] LTE active がどの処理で支配されているか説明できる → **§4.2（改善前）+ §7（改善後）**
- [x] boot 43 以降の active 増加の原因または次調査方針 → **§4.3: outbox ラッチ劣化モード**（Fix B 未実装）
- [x] README §6.2 更新材料 → **active 時間の改善前後は揃った**（mAh は機材到着後）
- [ ] #25 再開可能 → Fix B 長時間確認 + mAh 実測後を推奨

---

## 7. 改善実装と再計測（2026-07-07）

Issue #31 / #30 に紐づくファームウェア改善と実機結果の記録。

### 7.1 実装サマリ

| 項目 | 内容 | 関連 |
|---|---|---|
| **Fix A** | lwIP SNTP 廃止 → モデム `CCLK` / `CNTP` で system clock 設定 | #30, `transport.cpp` |
| **Fix C** | `flushOutbox` が `network` を破棄しない（`.as<JsonObject>()`） | `main.cpp` |
| **メトリクス** | `tcpTlsConnectMs`, `mqttHandshakeMs`, `publishMs` をペイロードに追加 | `main.cpp` |
| **モデム TLS** | `GsmClientSecureSIM7080` + 証明書のモデム FS 投入（NVS キャッシュ） | `lte_modem_tls.cpp`, `PSS_LTE_MODEM_TLS=1` |

### 7.2 改善前後の比較（定常サイクル）

| 指標 | 改善前（一晩試験・フェーズ1） | 改善後（debug 定常 / 本番 boot 1） |
|---|---|---|
| `activeMsBeforePublish` | 約 **68秒** | 約 **6秒** / 初回 **14秒** |
| `networkConnectMs` | 約 2.5秒 | 約 2.5秒 / 初回 10.5秒 |
| TLS + MQTT | `mqttConnectMs` 約 **34秒** | `tcpTlsConnectMs` 約 **1.5秒** + `mqttHandshakeMs` 約 0.2秒 |
| NTP 空振り | 約 **30秒**（コード解析） | **0秒** |
| `timestamp` | **null** | **ISO8601 有効** |
| 受信間隔（sleep 300秒） | 約 **8分** | 約 **5分弱**（見込み） |
| `deliveryConfirmed` | true | true |

**削減率**: 定常 active 約 **91%** 削減（68秒 → 6秒）。

### 7.3 本番切替（2026-07-07）

- ビルド: `xiao-s3-aws-lte`（Deep Sleep 300秒、LTE-only、モデム TLS）
- 端末: `xiao-e83dc1fb05fc`
- boot 1（`wakeCause: power_on`）を AWS Lambda で受信確認
- USB 抜き後 LiPo 単独運用の長時間試験を継続中

### 7.4 残タスク

| 優先 | 内容 | 状態 |
|---|---|---|
| 1 | Fix B（outbox ラッチ劣化モード）の再現・修正 | 未 |
| 2 | 本番 LiPo 長時間試験（boot 2+、`wakeCause: timer`、active 6秒台） | 進行中 |
| 3 | `disconnectTransport` / `poweroff` 時間の計測 | 未 |
| 4 | U200-1A による mAh 実測（パターン A〜D） | 到着待ち |
| 5 | #25 再開（変化時のみ送信・間隔・`lastStatus`） | Fix B + 実測後 |

---

## 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-07-07 | 初版。機材候補・配線・LTE タイミング分解・boot 43 仮説 |
| 2026-07-07 | M5STACK-U200-1A 注文。PPK2 見送り。§2.3 配線・ロガー方針を追記 |
| 2026-07-07 | CloudWatch 生ログ 87 件を分析。§1.2/§4 を実データで訂正（NTP 空振り30秒・outbox ラッチを特定）、§5 に中立的設計評価を追加 |
| 2026-07-07 | Fix A（lwIP SNTP→モデム時刻 CCLK/CNTP・#30 と共通）、Fix C（flushOutbox の network 保持）、publishMs 追加を実装。3 env ビルド確認 |
| 2026-07-07 | モデム内蔵 TLS 実装・実機確認。§7 に改善前後比較・本番切替を追記。active 68s→6s |
