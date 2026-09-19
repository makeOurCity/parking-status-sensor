# Issue #50: ブートモード(電源投入直後の無条件送信+短間隔連続送信) 実装計画

対象Issue: https://github.com/makeOurCity/parking-status-sensor/issues/50

本ドキュメントは、実コード(`firmware/src/main.cpp`, `firmware/include/config.h`,
`firmware/include/sync_ledger.h`, `firmware/src/sync_ledger.cpp`,
`firmware/include/transport.h`, `firmware/src/transport.cpp`,
`firmware/src/relay.cpp`, `firmware/include/history_log.h`)と突き合わせて検証済みの
実装計画。4回のレビュー往復(v1→v4)で見つかった問題をすべて反映した最終版。

## 改訂履歴

| 版 | 主な変更点 |
|---|---|
| v1 | 初版。ブートモードをローカル変数のみで完結させる方針、`connectTransportWithRetry()`/`publishWithRetry()`の再利用、未確定事項5点への結論を提示。 |
| v2 | レビュー指摘4件を反映: (1) `relayLteOn()`が`sendIndex==0`限定で初回接続失敗時に永久復旧不能になるバグ、(2) 接続再利用時に`TransportMetrics.transport`が`kNone`のままになりペイロードが誤る、(3) 2回目以降の接続維持方式を3段階構成に、(4) ブートモードによるNVS書き込み増加への評価を追加。 |
| v3 | v2の改訂過程で混入した2件の回帰を修正: (A) `activeMs`の起点が`slotStart`ではなく`bootModeStart`になり診断値・budget判定が誤っていた、(B) `waitUntilNextBootSlot()`に最終スロット後の早期returnがなく所要時間が意図の4分ではなく5分になっていた。 |
| v4(本版) | v3で新たに生じた2件を修正: (C) 発動判定を`loop()`に移し`bootModeConsumed`というRTCラッチを追加したのは、`setup()`が実チップリセットにつき1回しか呼ばれないという既存の保証だけで十分だったところに不要な複雑さを持ち込んだものだったため、`setup()`末尾での単純な判定に戻した。(D) `buildPayload()`が生成する実際のMQTT送信ペイロードへの`bootMode`情報付与がv3で説明なく欠落していたため復活させた。 |

---

## 1. 目的・要件(Issue #50 より)

**目的**: 現地調整時、電源投入直後にクラウド側へ即座に状態が届くようにする。

現状は `mustPublish()`(`firmware/src/main.cpp:218-232`)が `kChangeOnlySend` 有効時、
状態変化 or pending or heartbeat経過(既定`kHeartbeatCycles`=12サイクル×5分=1時間)の
いずれかを満たさない限り送信しない。`SyncLedger`(NVS常駐)が電源断をまたいで
状態を永続化するため、現地での電源ON/OFFを繰り返しても実状態が変わらなければ
最大1時間送信されず、現地調整が非常にやりづらい。

**要件(確定)**:
1. コールドブート(`ESP_RST_POWERON`)検知時、`mustPublish()`の結果に関わらず
   起動後最初のサイクルで無条件送信する。Deep Sleepタイマー復帰・ソフトリセット・
   watchdogリセットでは発動しない。
2. 0, 1, 2, 3, 4分の計5回、1分間隔で無条件送信する。4分時点(5回目)の送信を
   最後にブートモードを終了し、以降は通常運用(`kSleepSeconds`間隔・変化時のみ送信)
   に戻る。
3. ブートモード中(最大約4分)はLTE接続を維持したまま(サイクルごとの接続→切断を
   行わない)、Deep Sleep以外の待機方式で待つ。消費電力増は許容する。
4. 接続・送信失敗時も通常運用と同じリトライポリシー(`connectTransportWithRetry()` /
   `publishWithRetry()`)に従う。特別なフォールバックは設けない。
5. ブートモードは単一の「起きている」期間が最大4分強に及ぶため、既存のwatchdog
   タイムアウト(`kWatchdogTimeoutMs = kCycleMaxActiveMs + kWatchdogMarginMs`)の
   前提と衝突しないよう、定期的に`esp_task_wdt_reset()`を呼ぶ。

---

## 2. 設計方針

### 2.1 コールドブート検知とブートモードの発動(setup()ベース、v4で確定)

`esp_reset_reason() == ESP_RST_POWERON` を`setup()`の末尾で1回だけ判定する。

`setup()`はArduino/ESP32フレームワークにより実チップリセットにつき必ず1回だけ
呼ばれ、`loop()`だけが繰り返し呼ばれる。`config::kDisableDeepSleep=true`の
デバッグenv(`xiao-s3-aws-lte-relay-debug`)でも、`sleepNow()`(`main.cpp:120-145`)は
`esp_deep_sleep_start()`を呼ばず`delay()`して戻るだけでチップは実際にはリセット
されないため、`loop()`は何度も呼ばれるが`setup()`は再実行されない。

したがって、`setup()`内に判定を置くだけで一回性は自然に保証され、RTCメモリ等の
専用ラッチは不要(既存の`bootCount++`や`initSyncLedger()`が同じ前提で
`setup()`に素朴に書かれているのと同じ扱い)。

```cpp
void runBootMode() {
  // setup()から1回だけ呼ばれる前提(ループ内再入は考慮しない)。
  ...(§4.1)
}

void setup() {
  // ...既存の初期化(initRelay/Serial/watchdog/initDeviceIdentity/initSyncLedger/
  //   initHistoryLog/bootCount++/wake cause分岐/historyLogDumpToSerial/
  //   computeWakeDiagnostics等)はすべて不変...

#if !PSS_LTE_POWEROFF_TEST_MODE && !PSS_LTE_TEST_MODE
  // 電源投入(コールドブート)でのみ、setup()の最後に一度だけ実行。
  // タイマー起床・パニックリセット・WDTリセット等ではrunCycle()に進む。
  // ベンチ用テストモードとは #if で排他(loop()側のifdef分岐と重複させない)。
  if (config::kBootModeEnabled && esp_reset_reason() == ESP_RST_POWERON) {
    runBootMode();
  }
#endif
}

void loop() {
#if PSS_LTE_POWEROFF_TEST_MODE
  runLtePoweroffTest();
#elif PSS_LTE_TEST_MODE
  runLteTest();
#else
  runCycle();
#endif
}
```

`loop()`は既存のままで変更不要。

### 2.2 送信スロットのスケジュール

`kBootModeSendCount = 5`, `kBootModeSlotIntervalMs = 60000` とし、`sendIndex`
(0始まり)番目の送信は`bootModeStart`から`sendIndex * 60000ms`の時点で行う。
送信自体は待たずに即座に行い、次スロットへの**待機**だけを
`waitUntilNextBootSlot()`が担う。目標時刻は`bootModeStart`基準の絶対時刻
(`(sendIndex+1) * kBootModeSlotIntervalMs`)にすることで、あるスロットの処理が
長引いても後続スロットの間隔がドリフトして遅れ続けることがない
(§5.3で詳述)。

### 2.3 LTE接続維持方式(3段階接続)

要件3「ブートモード中はLTE切断しない」を満たすため、接続確立は毎スロットではなく
以下の3段階で行う。

- **Stage 1(`sendIndex == 0`)**: 通常サイクルと同じ`connectTransportWithRetry()`
  によるフル接続(LTEアタッチ+MQTT接続)。
- **Stage 2(`sendIndex >= 1` かつ `activeMqttState() == 0`)**: MQTT接続が
  生きている。何もしない(再接続不要)。
- **Stage 3(`sendIndex >= 1` かつ `activeMqttState() != 0`)**: `reconnectActiveTransport()`
  でMQTTレイヤのみ再接続(LTEベアラは維持)。失敗した場合のみ、要件4(通常運用と
  同じリトライポリシー)に従い`connectTransportWithRetry()`でフル再接続に
  フォールバックする。

`relayLteOn()`はループの外・`bootModeStart`直後に1回だけ呼ぶ。ループ内で毎回
呼ぶと「切断していないのに毎回ONパルスを送る」という設計上の不整合になる
(`relay.cpp`確認済み: ラッチング(自己保持)リレーのため電気的な実害はないが、
要件3の意図と矛盾する)。

`TransportMetrics metrics`もループの外で1回だけ宣言し、以降は参照で使い回す。
ループ内で毎回`TransportMetrics metrics{};`すると、`TransportKind`のデフォルトが
`kNone`(`transport.h:12`)であるため、Stage 2(再接続を省略するスロット)で
`metrics.transport`が`kNone`のままになり、そのスロットの送信ペイロードの
`network.transport`が実際は"lte"で送信しているにもかかわらず"none"相当の
値になってしまう。

`reconnectTransport()`(`transport.cpp:563-593`)の「既に接続済みなら即
`return true`」系の分岐、および「MQTTのみ再接続」する分岐(`connectMqtt()`
呼び出し)は、いずれも`metrics.transport`をセットしない(この値をセットするのは
`connectWifi()`/`connectLte()`内部のみ)。既存の`runCycle()`ではこれが問題に
ならないのは、`publishWithRetry()`に渡す`metrics`が必ず直前の
`connectTransportWithRetry()`でフル初期化済みだからであり、ブートモードで
新規にローカル`TransportMetrics`を作り直す設計だとこの前提が崩れる。

**対策**: Stage 2で何もしない場合、および Stage 3 の`reconnectActiveTransport()`が
成功した場合の両方で、`metrics.transport = activeTransportKind();`を明示的に
セットする。

### 2.4 `activeTransportKind()`の新設(transport.h/transport.cpp)

`transport.cpp`の`activeTransport`(44行目)は匿名namespace内のファイルローカル
変数で、外部公開アクセサが存在しない。既存の`activeMqttState()`/
`activeMqttLastError()`(789-801行目)と同じパターンで追加する。

**`firmware/include/transport.h`**(48-49行目付近、既存宣言の並びに追加)
```cpp
int activeMqttState();
int activeMqttLastError();
TransportKind activeTransportKind();  // 追加: 現在アクティブな接続種別を公開
```

**`firmware/src/transport.cpp`**(`activeMqttState()`の直後、789行目付近に追加)
```cpp
TransportKind activeTransportKind() {
  return activeTransport;
}
```

### 2.5 Watchdog整合

`config::kWatchdogEnabled`が真の場合、`esp_task_wdt_reset()`を
(a) 各スロットの先頭、(b) `waitUntilNextBootSlot()`の1秒刻みチャンク待機ループの
毎チャンク、の2箇所で呼ぶ。既存の`kWatchdogTimeoutMs`(実測環境で95000ms)に対し
最悪ケースでも1秒ごとにフィードされるため、ブートモードの総所要時間
(約4分強)がタイムアウトに抵触することはない。

### 2.6 NVS書き込み増加への評価

通常運用は`kSleepSeconds`(既定300秒)ごとに1回、`ledgerRecordConfirmed()`/
`ledgerRecordFailure()`経由で`SyncLedger`をNVSへ書き込む(`sync_ledger.cpp:47-62`の
`persist()`)。`historyLogRecordCycle()`も同様に毎回`pss_hlog`名前空間へ書き込む。
ブートモードは1回の電源投入につき最大5回、約4分間に集中してこれらの書き込みが
発生する。

このプロジェクトは過去にNVS書き込み過多を懸念してOutbox設計を廃止した経緯
([Issue #47](https://github.com/makeOurCity/parking-status-sensor/issues/47)の
背景)があり、NVS書き込み量に感度が高い。評価: これは電源投入(コールドブート)の
たびに1回だけ起きるバーストであり、定常運用の書き込み頻度(1回/5分)を継続的に
上回るものではない。現地調整で1日に数十回電源を入れ直しても、追加書き込み回数は
「電源投入回数×最大5回」程度に留まり、ESP32のNVS(wear-leveling付きフラッシュ、
耐用回数は概ね10万〜数十万回オーダー)の消耗観点で無視できる増分と判断する。
ただし、将来「ブートモードを日常的な再起動トリガーとして頻用する」運用が
計画される場合は、この評価の再検討が必要である旨をコード内コメントと
本ドキュメントに明記しておく(黙って触れないのではなく、検討済みであることを
明示する)。

---

## 3. 設定値の追加(`firmware/include/config.h`)

既存の`PSS_*`マクロ + `config::k*`定数という命名規約(247-292行目)に倣う。

```cpp
#ifndef PSS_BOOT_MODE_ENABLED
#define PSS_BOOT_MODE_ENABLED 1
#endif

#ifndef PSS_BOOT_MODE_SEND_COUNT
#define PSS_BOOT_MODE_SEND_COUNT 5
#endif

#ifndef PSS_BOOT_MODE_SLOT_INTERVAL_MS
#define PSS_BOOT_MODE_SLOT_INTERVAL_MS 60000  // 5回 x 60秒 = 総所要時間 約4分
#endif
```

```cpp
namespace config {
// ...既存定数群の末尾に追加...
constexpr bool kBootModeEnabled = PSS_BOOT_MODE_ENABLED;
constexpr uint8_t kBootModeSendCount = PSS_BOOT_MODE_SEND_COUNT;
constexpr uint32_t kBootModeSlotIntervalMs = PSS_BOOT_MODE_SLOT_INTERVAL_MS;
}  // namespace config
```

スロットの予算判定には新規定数を設けず、既存の`config::kCycleMaxActiveMs`を
そのまま流用する(§5.1参照。ただし`slotStart`基準で使うことが前提)。

---

## 4. 疑似コード最終版

### 4.1 `runBootMode()`

```cpp
void runBootMode() {
  const uint32_t bootModeStart = millis();

  if (config::kLtePowerRelayEnabled) {
    // ブートモード中はLTE接続を切断しない(要件3)ため、SETパルスは
    // ループの外、ここで1回だけ送る。
    relayLteOn();
  }

  // ループの外で1回だけ宣言する。ループ内で毎回`TransportMetrics metrics{};`
  // すると、再接続を省略したスロット(Stage 2)でtransport種別の情報が失われ、
  // payloadのnetwork.*が誤って"none"/0になる。
  TransportMetrics metrics{};
  bool transportReady = false;

  for (uint8_t sendIndex = 0; sendIndex < config::kBootModeSendCount; ++sendIndex) {
    if (config::kWatchdogEnabled) esp_task_wdt_reset();
    const uint32_t slotStart = millis();

    if (!initSensor()) {
      const uint32_t activeMs = millis() - slotStart;  // slotStart基準(§5.1)
      ledgerRecordFailure(CycleOutcome::kSensorError, ParkingStatus::kUnknown,
                          bootCount, 0, 0, activeMs);
      waitUntilNextBootSlot(bootModeStart, sendIndex);
      continue;
    }

    RawSample sample{};
    readSensor(sample);
    const ParkingStatus status = classifyStatus(sample, config::kStatusThreshold);

    // #47の規約どおり、送信可否に関わらず毎回記録する。
    historyLogRecordCycle(status, sample, bootCount);

    // 3段階接続方式(§2.3)。
    if (sendIndex == 0) {
      // Stage 1: 通常サイクルと同じフル接続(LTEアタッチ+MQTT接続)。
      transportReady =
          connectTransportWithRetry(metrics, slotStart, config::kConnectPhaseMs);
    } else if (activeMqttState() == 0) {
      // Stage 2: 接続維持中。何もしないが、metrics.transportを明示的に補う(§2.3)。
      transportReady = true;
      metrics.transport = activeTransportKind();
    } else {
      // Stage 3: MQTTレイヤのみ再接続(LTEベアラは維持)。
      transportReady = reconnectActiveTransport(metrics);
      if (transportReady) {
        metrics.transport = activeTransportKind();  // §2.3
      } else {
        // 要件4: 通常運用と同じリトライポリシーへフォールバック。
        transportReady =
            connectTransportWithRetry(metrics, slotStart, config::kConnectPhaseMs);
      }
    }

    if (!transportReady) {
      const uint32_t activeMs = millis() - slotStart;
      const int16_t mqttErr = static_cast<int16_t>(activeMqttLastError());
      ledgerRecordFailure(CycleOutcome::kConnectFailed, status, bootCount, 0,
                          mqttErr, activeMs);
      waitUntilNextBootSlot(bootModeStart, sendIndex);
      continue;
    }

    syncClock(config::kTimeSyncTimeoutMs);

    const BootModeSendInfo bootInfo{/*active=*/true,
                                    /*slot=*/static_cast<uint8_t>(sendIndex + 1),
                                    /*totalSlots=*/config::kBootModeSendCount};

    char payload[kPayloadSize]{};
    PublishResult pub{};
    const bool ok = publishWithRetry(sample, status, metrics, slotStart,
                                     /*faultInject=*/false, bootInfo, payload,
                                     sizeof(payload), pub);
    const uint32_t activeMs = millis() - slotStart;  // slotStart基準(§5.1)
    const int16_t mqttErr = static_cast<int16_t>(activeMqttLastError());

    if (ok) {
      ledgerRecordConfirmed(status, bootCount, pub.attempts, mqttErr, activeMs);
      Serial.println(payload);
    } else {
      // slotStart基準のactiveMsとkCycleMaxActiveMs(このスロットの予算)を
      // 比較する。bootModeStart基準だと2スロット目以降は開始時点で既に
      // 閾値付近に達しており常に誤爆する(§5.1)。
      const CycleOutcome outcome = (activeMs >= config::kCycleMaxActiveMs)
                                       ? CycleOutcome::kBudgetExhausted
                                       : CycleOutcome::kPublishFailed;
      ledgerRecordFailure(outcome, status, bootCount, pub.attempts, mqttErr,
                          activeMs);
      Serial.println(payload);
    }

    waitUntilNextBootSlot(bootModeStart, sendIndex);
  }

  // sleepNow()がdisconnectTransport()/relayLteOff()を内部で必ず呼ぶため
  // (main.cpp:120-145)、ここで個別に切断処理を行う必要はない。
  Serial.println("boot-mode: complete, resuming normal cadence");
  sleepNow("boot-mode-done", millis() - bootModeStart);
}
```

### 4.2 `waitUntilNextBootSlot()`

```cpp
// 次スロットの目標時刻(bootModeStart起点の絶対時刻)まで、Watchdog給餌を
// 挟みながらチャンク単位で待機する。最終スロットの後は待たずに即終了する。
void waitUntilNextBootSlot(uint32_t bootModeStart, uint8_t sendIndex) {
  if (sendIndex + 1 >= config::kBootModeSendCount) {
    return;  // 最後の送信の後は待たない(ブートモードは4分で終わる)
  }

  const uint32_t targetElapsed =
      static_cast<uint32_t>(sendIndex + 1) * config::kBootModeSlotIntervalMs;
  const uint32_t now = millis();
  const uint32_t elapsed = now - bootModeStart;
  if (elapsed >= targetElapsed) {
    return;  // このスロットの処理が長引き、既に次の目標時刻を過ぎていた
  }

  uint32_t remaining = targetElapsed - elapsed;
  constexpr uint32_t kChunkMs = 1000;
  while (remaining > 0) {
    const uint32_t chunk = (remaining < kChunkMs) ? remaining : kChunkMs;
    delay(chunk);
    if (config::kWatchdogEnabled) esp_task_wdt_reset();
    remaining -= chunk;
  }
}
```

### 4.3 `buildPayload()` / `publishWithRetry()` へのブートモード情報追加

現地作業者がクラウド側ダッシュボード/ログ(Serial接続なし)でも「今のはブート
モードの何回目の送信か」を判別できるよう、Serialログだけでなく**実際の
MQTT送信JSONペイロード自体**にブートモード情報を含める。

```cpp
// main.cpp (namespace内、buildPayload()の直前に追加)
struct BootModeSendInfo {
  bool active = false;      // ブートモード中の送信かどうか
  uint8_t slot = 0;         // 何回目の送信か(1-5)。非ブートモード時は0
  uint8_t totalSlots = 0;   // 予定送信回数(5)。非ブートモード時は0
};

void buildPayload(const RawSample& sample, ParkingStatus status,
                  const TransportMetrics& transportMetrics, uint32_t activeMs,
                  uint8_t publishAttempts, const BootModeSendInfo& bootModeInfo,
                  char* out, size_t outSize) {
  JsonDocument doc;
  // ...既存フィールド(deviceId/status/raw/threshold/timestamp/power/network/sync)
  //    は不変...

  // #50: クラウド側ログでブートモード送信を区別できるようにする。
  // 常にオブジェクトを出す(非ブートモード時はactive=false/slot=0/totalSlots=0)
  // ことで、パース側のスキーマを常に一定に保つ。
  JsonObject bootMode = doc["bootMode"].to<JsonObject>();
  bootMode["active"] = bootModeInfo.active;
  bootMode["slot"] = bootModeInfo.slot;
  bootMode["totalSlots"] = bootModeInfo.totalSlots;

  serializeJson(doc, out, outSize);
}

bool publishWithRetry(const RawSample& sample, ParkingStatus status,
                      TransportMetrics& metrics, uint32_t cycleStart,
                      bool faultInject, const BootModeSendInfo& bootModeInfo,
                      char* payload, size_t payloadSize, PublishResult& result) {
  result = PublishResult{};
  const uint32_t phaseStart = millis();

  for (uint8_t attempt = 1; attempt <= config::kPublishMaxAttempts; ++attempt) {
    // ...既存の予算チェック・reconnect処理(255-259行目)は不変...

    result.attempts = attempt;
    Serial.printf("publish attempt %u/%u\n", attempt, config::kPublishMaxAttempts);

    buildPayload(sample, status, metrics, millis() - cycleStart, attempt,
                 bootModeInfo, payload, payloadSize);

    if (faultInject) {
      Serial.println("FAULT INJECT: forcing publish failure");
      continue;
    }

    if (publishTelemetryConfirmed(payload, metrics)) {
      result.confirmed = true;
      return true;
    }
  }

  return false;
}
```

`runCycle()`側の既存呼び出し(`main.cpp:267-268`, `457-458`)は
`BootModeSendInfo{}`(デフォルト = 非アクティブ、`active=false`)を渡すだけで
無変更同然に動く。

---

## 5. 検証済みの設計上の整合性

### 5.1 `activeMs`は常に`slotStart`基準

`ledgerRecordFailure()`/`ledgerRecordConfirmed()`へ渡す`activeMs`はすべて
`millis() - slotStart`を使う。`bootModeStart`基準の経過時間は
(a) `waitUntilNextBootSlot()`の絶対時刻ターゲット計算、(b) 最後の
`sleepNow()`呼び出しでの累積active時間、の2箇所専用であり、個々のスロットの
`SyncLedger`記録・budget判定には使わない。

理由: 既存の`runCycle()`(`main.cpp:400, 422, 439, 459`)は一貫して
`millis() - cycleStart`(その1サイクル分の所要時間)を使っており、ブートモードの
各スロットも「1回のサイクル相当」なので同じ意味論であるべき。`bootModeStart`
基準にすると(i)5スロット目で実処理が一瞬でも`activeMs`が約240秒として記録され
診断データが誤解を招く、(ii)`kBudgetExhausted`判定
(`activeMs >= kCycleMaxActiveMs`)が2スロット目以降ほぼ常に誤爆し
`kConnectFailed`/`kPublishFailed`との切り分けが機能しなくなる、という2つの
実害がある。

### 5.2 ループの終了タイミング

`waitUntilNextBootSlot()`の冒頭で`sendIndex + 1 >= config::kBootModeSendCount`
なら即returnするガードにより、5回目(`sendIndex=4`)の送信後は待たずに
`sleepNow()`へ進み、ブートモードの所要時間は意図どおり約4分(240秒)に収まる
(このガードがないと5分かかってしまう)。

### 5.3 その他の整合性

- `waitUntilNextBootSlot()`が`bootModeStart`からの絶対目標時刻で待つ設計に
  なっているため、あるスロットの処理が長引いて次スロットの目標時刻を過ぎていても
  即座に戻り、待機時間が自動的に短縮される。間隔がドリフトして遅れ続けることは
  ない。
- `sleepNow()`(`main.cpp:120-145`)は`disconnectTransport()`と
  (`kLtePowerRelayEnabled`時の)`relayLteOff()`を内部で無条件に呼ぶため、
  `runBootMode()`側でこれらを重複して呼ぶ必要はない。
- `mustPublish()`はブートモード中一切呼ばれない(要件2「無条件送信」)。
  ブートモード終了後の通常`runCycle()`は今まで通り`mustPublish()`で判定するため、
  ヒステリシス(`kHeartbeatCycles`)の意味論は変わらない。
- `SyncLedger`は通常サイクルと同じ`ledgerRecordConfirmed()`/
  `ledgerRecordFailure()`を呼ぶため、`lastConfirmedStatus`/
  `skippedSinceConfirmed`/`pendingValid`は特別扱いせず正しく更新される。
  5回すべて失敗しても`pendingValid=true`が立ち、直後の通常サイクルの
  `mustPublish()`が即座に再送を試みる(要件4関連の未確定事項への回答、§6参照)。

---

## 6. 未確定事項への結論(Issue本文より)

| # | 論点 | 結論 |
|---|---|---|
| 1 | コールドブート判定の実装方法 | `esp_reset_reason() == ESP_RST_POWERON`を`setup()`末尾で1回だけ判定(§2.1)。`bootCount`/`consecutiveTimerWakes`は変更不要、ブートモードの5回の送信は同一`bootCount`を共有する(1回の物理起動という意味論と一致)。 |
| 2 | 待機方式の選定 | light sleepは不採用。チャンク分割`delay()`ループ(既存の`kDisableDeepSleep`フォールバックと同じ設計言語)を採用。理由: LTE UART/MQTTソケット状態を維持したままlight sleepするには電源ドメイン保持設定や復帰後の再初期化検証が必要でリスクが高く、要件3で消費電力増を許容する旨明記されているためメリットも薄い。 |
| 3 | 再発動防止ガードの要否 | 専用ガード不要。`setup()`は実チップリセットにつき1回しか呼ばれないため、`esp_reset_reason()==ESP_RST_POWERON`という条件そのものが自然に一回性を保証する(§2.1)。RTCメモリ等の専用ラッチは不要。 |
| 4 | 5回全滅時の終了方法 | タイムアウト(5スロット消化)のみで通常モードに戻す。`pendingValid=true`により直後の通常サイクルで即再送されるため、追加のフォールバックは不要(§5.3)。 |
| 5 | 送信ペイロード形式 | 既存スキーマに`bootMode`オブジェクト(`active`/`slot`/`totalSlots`)を追加(§4.3)。非ブートモード時も常にオブジェクトを出す(`active=false`等)ことでスキーマを一定に保つ。 |

---

## 7. エッジケース対応

| ケース | 対処 |
|---|---|
| センサー初期化失敗(`initSensor()==false`) | `kSensorError`を記録し、通信フェーズに進まず次スロットへ。リレー・LTEには触れない。 |
| 5回すべて送信失敗(電波不良等) | タイムアウトで`sleepNow()`へ進み通常サイクルに戻る。`pendingValid=true`により直後に再送。 |
| スロット2回目以降でMQTT/LTEベアラごと落ちている | `reconnectActiveTransport()`が失敗→`connectTransportWithRetry()`にフォールバック。`relayLteOn()`はStage1でのみ呼ばれる設計だが、この場合`connectLte()`内部の`beginLteUartAndModem()`が再度AT初期化を試みる(リレーの物理ON状態自体は変わっていないため追加のリレー操作は不要)。 |
| `kLteTestMode`/`kLtePoweroffTestMode`ビルド | `setup()`の`#if !PSS_LTE_POWEROFF_TEST_MODE && !PSS_LTE_TEST_MODE`ガードにより、ブートモードは発動しない(コンパイル時に除外)。 |
| `kBootModeEnabled=0`でビルドされた機体 | `runBootMode()`を呼ばず、既存の通常フローに完全復帰する安全弁。 |
| `kDisableDeepSleep=1`のデバッグenv | `setup()`は実チップリセットにつき1回しか呼ばれないため、`loop()`が何度呼ばれてもブートモードは再発動しない(§2.1)。 |

---

## 8. テスト計画

1. **正常系(電波良好)**: リレー版LTE機体(`env:xiao-s3-aws-lte-relay`)をUSB給電で
   完全に抜き差しし、コールドブートを発生させる。
   - シリアルログで`boot-mode`関連ログが0,60,120,180,240秒付近のタイミングで
     出ることを確認。
   - クラウド側(AWS IoT Core等)で5件のメッセージが同一`bootCount`、
     `bootMode.active=true`、`bootMode.slot=1..5`として届くことを確認。
   - `network.transport`がStage 2/3のスロットでも`"none"`にならず`"lte"`の
     ままであることを確認(§2.3の回帰防止)。
   - 電源投入から5回目送信完了までの総所要時間が約4分(240秒)前後に収まり、
     5分(300秒)近くにならないことを確認(§5.2の回帰防止)。
   - 5回目送信後、通常の300秒間隔(`kSleepSeconds`)に戻ることを確認。
2. **タイマー復帰では発動しないこと**: 通常のDeep Sleep復帰では`boot-mode`
   ログが一切出ないことを確認。
3. **ソフトリセットでは発動しないこと**: XIAOのRSTボタン押下時の
   `esp_reset_reason()`を実機で確認(ボード依存の可能性があるため、
   `ESP_RST_POWERON`として誤検出されないか要確認)。
4. **接続失敗系**: SIMを抜く/電波の届かない場所で電源投入し、5スロットすべて
   `connect_failed`/`publish_failed`になっても機体がハングせず、5スロット後に
   正常に通常サイクルへ復帰することを確認。`prevOutcome`が実処理時間に応じて
   `kConnectFailed`/`kPublishFailed`/`kBudgetExhausted`を正しく区別すること
   (§5.1の回帰防止)。
5. **watchdogとの共存**: `kWatchdogEnabled=1`環境で、ブートモード中(約4分)
   watchdogリセットが発生しないこと。
6. **LTE切断なし(要件3)の確認**: `disconnectTransport()`/`powerOffLteModem()`
   のログがブートモード中の4回の待機の間には出現せず、初回接続時と最終
   スロット後の1回のみ出ることを確認。
7. **デバッグビルド(`kDisableDeepSleep=1`)での回帰確認**: ブートモードが1回だけ
   実行され、その後`loop()`が通常の`runCycle()`を繰り返すことを確認
   (2回目以降の`loop()`呼び出しでブートモードが再発動しないこと、§2.1)。
8. **NVS書き込み回数の確認**: ブートモード実行前後で`pss_sync`/`pss_hlog`の
   書き込み回数が想定どおり最大5回ずつの増分であることを確認(§2.6)。

---

## 9. 実装ステップ

1. `docs/50-boot-mode-design.md`(本ドキュメント)を確定として先にコミットする
   (`#47`/`#46`と同じ、設計docを先にコミットしてから実装するプロジェクト慣習)。
2. `firmware/include/config.h`にブートモード用定数(§3)を追加。
3. `firmware/include/transport.h`/`firmware/src/transport.cpp`に
   `activeTransportKind()`を追加(§2.4)。
4. `firmware/src/main.cpp`に`BootModeSendInfo`構造体、`waitUntilNextBootSlot()`、
   `runBootMode()`を追加し、`buildPayload()`/`publishWithRetry()`の
   シグネチャを変更(§4)。`runCycle()`側の呼び出しを`BootModeSendInfo{}`付きに
   更新。
5. `setup()`末尾にトリガー条件を追加(§2.1)。
6. 短縮送信回数(`PSS_BOOT_MODE_SEND_COUNT=2〜3`)のデバッグビルドで、§8の
   テスト項目1・6・7を実施。
7. 本番の送信回数・間隔(5回/60秒間隔)に戻し、実機でコールドブート/タイマー
   復帰/ソフトリセットの3パターン(§8の1-3)を確認。
8. 接続失敗系(SIM抜き)をベンチで再現し、5スロット全滅後の復帰を確認(§8の4)。
9. `docs/data-model.md`(存在する場合)に`bootMode`フィールドを追記。

### レビュー観点(実装レビュー時に確認すること)

- `runBootMode()`が`mustPublish()`を絶対に呼んでいないこと(要件1・2の
  「無条件送信」を壊す最も起きやすいバグ)。
- Stage 2/3で`metrics.transport`が明示的にセットされていること(§2.3)。
- `activeMs`がすべて`slotStart`基準であり、`bootModeStart`基準の値と
  混同されていないこと(§5.1)。
- `waitUntilNextBootSlot()`が最終スロット後に即returnすること(§5.2)。
- `relayLteOn()`がループ外で1回だけ呼ばれ、Stage移行のたびに再度呼ばれて
  いないこと。
- `isColdBoot`判定がXIAO ESP32S3実機で本当に期待通り
  (USB抜き差し→`ESP_RST_POWERON`、RSTボタン→別理由)になるかを実機で
  必ず確認すること(フラッシュ直後の1回目起動時の挙動はツール依存の
  可能性があるため要注意)。
