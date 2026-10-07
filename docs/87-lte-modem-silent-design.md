# Issue #87: LTE-M が応答しないとき、ウォッチドッグ再起動ループに入らず Deep Sleep する 実装計画

対象Issue: https://github.com/makeOurCity/parking-status-sensor/issues/87

**状態: 実装済み（全 env のビルド確認済み、実機検証は未実施）。** 計画から変えた点は、`connectTransportWithRetry` の hard を `min(budgetMs + 10s, kCycleMaxActiveMs)` で計算していることだけ（`config::kConnectHardMs` と同じ式）。

本ドキュメントは、実コード（`firmware/src/transport.cpp`、`main.cpp`、`sync_ledger.cpp`、`relay.cpp`、`include/config.h`、`include/transport.h`）、TinyGSM v0.12.0 のソース、Issue のログと突き合わせた計画。サブエージェントによる計画の立案に対して 3 回レビューを往復し、差し戻した点を反映した版。

## 改訂履歴

| 版 | 主な変更点 |
|---|---|
| v1 | 初版。deadline の伝播、silent 時の即失敗、`task_wdt` 起動時のスキップ。 |
| v2 | レビュー指摘を反映: TinyGSM の実コードで時間を確定、二段 deadline（soft / hard）、file-static フラグをやめて enum + `TransportMetrics`、`Deadline` 構造体をやめて `uint32_t`、native テスト基盤は本 PR のスコープ外に。 |
| v3（本版） | 追加の指摘を反映: fail-fast の適用範囲をリレーあり環境に限定、`prepareLteForPlanD` 失敗時の分岐を現行どおりに保つ、`kConnectHardMs` を `min()` で `kCycleMaxActiveMs` に抑える、無応答プローブを 1000ms × 2 回に。 |

---

## 1. 現状分析（確認した事実）

### 1.1 原因

Issue のログ（10:07〜10:14）と実コードの突き合わせ。

- `connectTransportWithRetry()`（`transport.cpp:678`）は、接続の制限時間 `PSS_CONNECT_PHASE_MS`（45s）を**試行と試行の間でしか確認しない**（`:684`）。
- `beginLteUartAndModem()`（`:292`）は最大 3 回、モデムの初期化を試す。1 回ごとに次を、制限時間を確認せずに行う。

  | 区間 | 時間（無応答のとき） |
  |---|---|
  | 電源投入後の待ち（`PSS_LTE_COLD_BOOT_SETTLE_MS`） | 5s |
  | `wakeLteModemAt()`（10 回 × (1s + 0.3s)） | 13s |
  | `modem.init()`（TinyGSM の AT ループ） | 約 10.3s |
  | `logLteInitFailure()`（AT 4 本 × 5s） | 20s |
  | `recoverLteModemFromPowerOff()` の wake | 13s |

  attempt1 は約 61s。Issue のログ（10:07:30 → 10:08:31）と一致する。
- 3 回で理論上約 169s。さらに外側の再試行で `powerOffLteModem()` が、無応答のモデムへ `AT+CPOWD=1` を 2 回送り約 33.5s かかる。
- ウォッチドッグ（`PSS_CYCLE_MAX_ACTIVE_MS` 75s + `PSS_WATCHDOG_MARGIN_MS` 20s = 95s）が先に発火して再起動する。再起動後は `ledgerRecordFailure()` に到達しないので失敗が記録されず（`prevOutcome=skipped`）、`skippedSinceConfirmed` が高いままなので毎回送信を試みる。これが無限ループの構造。

### 1.2 Issue の記述の訂正

Issue の「`modem.init()` のタイムアウト約 28s」は不正確。28s は「電源投入後の待ち 5s + wake 13s + `modem.init()` 約 10s」の合計。

### 1.3 TinyGSM v0.12.0 のソースから確定した時間

`platformio.ini` は `vshymanskyy/TinyGSM` のバージョンを指定していない（取得時の最新版）。ビルドログの `TinyGSM @ x.y.z` を PR に残し、v0.12.0 でなければ本節を再確認する。Issue のログの時間（28.2s、13.1s、10.2s）は v0.12.0 のコードと一致する。

| 箇所 | 実装 | 時間 |
|---|---|---|
| `TinyGsmClientSIM7080.h` の `initImpl` 冒頭 | 10 秒間、`AT` を送り `waitResponse(200)` + `delay(100)`（`testAT` は使わない） | 無応答なら約 10.3s |
| 同 `+CMEE=0` / `+CBATCHK=1` | `waitResponse()`（既定 1000ms） | 各 ≤1s |
| 同 `+CLTS=1` | `waitResponse(10000L)` | ≤10s |
| `getSimStatusImpl` | 10 秒未満のループ（1 周 2s） | ≤約 12s |
| **`modem.init()` 合計** | | 無応答 約 10.3s ／ 応答ありの実用最悪 約 14s ／ 理論最悪 約 34.3s |
| `waitForNetworkImpl` | `while (millis()-start < timeout)`（1 周 ≤1s + 250ms） | clamp 精度 約 +1.3s |
| `gprsConnectImpl` | `CGATT=1` が 60s、`CNACT=0,1` が最大 5 回 × 60s | 理論最悪 約 360s。応答があれば通常 1〜2s。**中断不能** |

自前コードの時間: `prepareLteForPlanD()` は待ちの合計が約 99s（`CMNB=1` 失敗時は約 109s）。電源投入時と WDT 再起動の直後は毎回走る（`ltePlanDReady` は RTC 変数で、非タイマー起動でリセットされる、`main.cpp:880`）。

---

## 2. 設計方針

### 2.1 無応答のモデムは再試行せず、すぐ諦める

- **silent の定義**: `modem.init()` が失敗したあと、AT プローブに**一切の応答（OK でも ERROR でも）が無い**。wake の結果には依存しない。プローブは 1000ms × 2 回（誤判定の被害は、CPOWD を省く・残りの再試行を省く、なので 1 回の取りこぼしで断定しない。無応答時 +1.5s）。
- silent と判定したら UART を停止して `kSilent` を返す。`powerOffLteModem()` は UART 未開始なら即 return する（`transport.cpp:906-912`）ので、無応答のモデムへの CPOWD（約 33.5s）が走らない。電源の遮断は直後の `relayLteOff()` が担う（`sleepNow()` が無条件に呼ぶ、`main.cpp:166-170`）。
- 無応答時の所要は約 **30s**（settle 5 + wake 13 + init 10.3 + プローブ 2）。ウォッチドッグまで約 65s 残して Deep Sleep に入る。
- **リトライを打ち切るのは、リレーあり環境（`config::kLtePowerRelayEnabled`）だけ。**
  - リレーありのコールド通電では、通電から AT 応答までは通常 5.5〜6.6s（`tools/power-logger/results/74/` のシリアルログ 2 例）。約 28s 無応答なら故障とみなせる。誤判定の被害は、そのサイクルを逃して 5 分後に再試行になるだけ（`pendingValid` で必ず再試行される）。
  - リレー無し環境（`xiao-s3-aws-lte` など）は、CPOWD 後に UART だけが無応答になる構成で、PWRKEY の制御手段も無い（docs/25-low-power-investigation.md）。「後から応答が戻る」のが物理的にあり得るため、証拠なしに変えない。従来のリトライ順序を残し、hard deadline で時間だけ縮める。
  - 「無応答と確定して返すときは UART を止める」は全環境に入れる（CPOWD を省く）。
- 検討して採用しなかった案: (a) settle を延ばして 1 回だけ再試行（通電から AT 応答は約 6s なので、延ばしても意味がない）、(c) wake が失敗したら `init` を呼ばない（短縮は 10s で、サイクル周期の約 3%。`init` の AT ループは「後から起動したモデムを拾う」追加の窓）。
- 再試行が成功した記録は、docs・ログ・git 履歴のどこにも無い（根拠なし）。逆に、`LTE modem init retry` や `no AT during wake` が出るのは docs/60 の #63 のログだけで、電源の入れ直しでしか回復していない。

### 2.2 deadline は二段にして、下位関数には hard の 1 本だけを渡す

- **soft** = `kConnectPhaseMs`（45s）: `connectTransportWithRetry` のループ先頭で、**新しい試行を始めるか**の判断にだけ使う（既存どおり）。
- **hard** = `min(kConnectPhaseMs + 10000, kCycleMaxActiveMs)`: 実行中の AT 待ち・`delay`・`waitForNetwork` を縮める上限。
  - 根拠は `docs/sync-delivery-design.md` §4.1 の「cycle 75 = connect 45 + publish 20 + マージン 10」。hard で接続が終わっても publish 20s が残る。
  - `secrets.h` で `PSS_CYCLE_MAX_ACTIVE_MS` を変えても hard が超えないよう、`min()` で抑える（`secrets.example.h:53` の例は 45000）。
  - publish フェーズの再接続（`reconnectActiveTransport`）では hard = `cycleStart + kCycleMaxActiveMs`（75s、WDT の 20s 手前）。BootMode のスロット ≥1 の再接続では hard = `slotStart + kConnectHardMs`。
- 引数の表現は、絶対 millis の `uint32_t`（0 = 無期限）。`deadlineAfter()` が 0 になるときは 1 に置き換える。差の比較は `int32_t(end - now)` で wrap 安全にする。

### 2.3 hard で縮めるもの（clamp）と閾値

| 対象 | 扱い |
|---|---|
| AT の `waitResponse`、`delay`（wake、recover、plan-D） | `min(元の値, remaining)` |
| `waitForNetwork` | `min(kLteNetworkTimeoutMs, remaining)`。残りが 5s（`kMinNetworkWaitMs`。実測 attach 約 2.5s の約 2 倍）未満なら待たずに失敗 |
| `modem.init()`（中断不能） | 残りが `kInitReserveMs`（20s。実用最悪 14s + 余裕）以上のときだけ呼ぶ |
| 再試行（attempt ≥2）の開始 | 残りが `kInitReserveMs + 5s`（= 25s。stop 2s + settle 2.5s を含む）以上のときだけ |
| `logLteInitFailure()` | 残りが 20s 以上、かつ**応答があるときだけ**（無応答だと出力が空で約 20s の無駄） |
| `prepareLteForPlanD()` | 各待ちを clamp。残りが 0 になったら以降を呼ばずに `false` |
| `gprsConnect`、証明書、`connectMqtt` の前 | 残りが 0 なら失敗（軽いチェックのみ。各 API 内部の待ちは clamp しない） |

通常運用への影響は無い。実測の接続は約 6〜17s（`docs/hardware.md`、`docs/sync-delivery-design.md` §4.1）で、hard の 55s に余裕がある。soft（45s）を基準にすると、`init` が遅れて成功した場合に attach の待ちが 5s しか残らないので、二段にした。

### 2.4 状態の持ち方

- `beginLteUartAndModem()` だけが enum `LteInitResult { kOk, kSilent, kFailed, kDeadline }` を返す（無名 namespace 内の内部関数）。
- `connectLte()` が `kSilent` のとき `metrics.modemSilent = true` にする（`TransportMetrics` に `bool modemSilent = false;` を追加）。公開 API の戻り値は bool のまま。
- 伝達経路は既存の out-param `TransportMetrics&` で、新しい隠れ状態（file-static フラグ）は作らない。`buildPayload()` は `TransportMetrics` を丸ごと出力しないので、新フィールドが JSON に漏れることはない。
- リトライの打ち切りは、明示 bool 引数 `failFastWhenSilent`（`connectLte` から `config::kLtePowerRelayEnabled` を渡す）。`probeLteModem`（test 系 env）は `kNoLimit, false` で、従来の 3 回リトライ・診断ありのまま。

### 2.5 `task_wdt` で起動したサイクルは送信しない

入れる。ワンショットのラッチ付き。

- 修正 1・2 で防げない未知のハングが WDT を踏んでも、「95s 起きっぱなしの連続再起動」ではなく「5 分のスリープを挟む周期」になる。失敗が `sync.prevOutcome` に残る（現状は `skipped` と誤表示）。
- 副作用は小さい。WDT 後は次の定期サイクル（約 5 分後）に回るだけで、取りこぼしではない（`pendingValid=true` なので次サイクルは `kPendingRetry` で必ず送る）。skip するのは `reset=task_wdt` の起動だけで、スリープ後の起動は `deep_sleep` なので通常に戻る。連続 WDT で永久に送らなくなることはない。
- **ラッチ必須**: `kDisableDeepSleep` のデバッグ env では `sleepNow()` が return してチップはリセットされず、`esp_reset_reason()` が同じ起動中ずっと `TASK_WDT` のままになる。`static bool` で 1 回だけ処理しないと、永久にスキップし続ける。
- 記録は `kBudgetExhausted` を流用する。新しい enum は作らない（`lorawan_payload.cpp:22` が 3 ビットで、`bridge/lorawan.py`、`tools/lorawan/decode.py`、テストベクタに波及するため）。bridge・tools・log-viewer に outcome で分岐する箇所は無く、混ざって困る consumer は見つからなかった。outcome だけでは本物の予算超過（約 75〜80s）と WDT（95s）を区別できないので、`prevActiveMs=95000` とシリアルの `sleep reason=watchdog-reset` で見分ける。
- `activeMs` に `kWatchdogTimeoutMs` を入れる近似は、`prevActiveMs` の消費者（JSON の診断表示、LoRaWAN バイトは `/250` で 63750 に飽和、NVS の `uint32_t`）に悪影響が無い。

env・経路ごとの挙動:

| 経路 | 挙動 |
|---|---|
| 通常（Deep Sleep あり、relay-pot） | センサー読み取りと履歴ログのあとに `kBudgetExhausted` を記録して Deep Sleep |
| BootMode | `runBootMode` に入るのは `ESP_RST_POWERON` のときだけ（`main.cpp:905`）。WDT 起動では入らず、`runCycle` のスキップに入る |
| LoRaWAN env | `runCycle` が共通。`sleepNow` → `disconnectTransport` の LoRaWAN 分岐が Wio-E5 を `AT+LOWPOWER` に寝かせる |
| `kDisableDeepSleep` の debug env | ラッチで最初の 1 回だけ |
| test モード | `loop()` が `runCycle` を呼ばないので影響なし |

### 2.6 採用しなかった案

- **無応答時にリレーの SET を再パルスする案**: #87 では約 9 時間（約 340 回）SET を送り続けても切り替わらなかった。再パルスが効く根拠が無い。パルス幅の変更も効果がない（コイルの通電幅は基板側の RC で決まる）。詳細は #88。
- **グローバルな cycle deadline**: `connectTransport` が BootMode のスロット基準でも呼ばれ、起点が違う。隠れた結合になる。
- **`Deadline` 構造体、native テスト基盤の新設**: 本 PR のスコープ外（1PR = 1目的）。
- **新しい `CycleOutcome`**: 上記のとおり波及が大きい。
- **連続失敗時のバックオフ**: ledger のスキーマ変更が要るので別 Issue（#89）。

---

## 3. ファイル別の具体的変更

### 3.1 シグネチャ変更（grep 結果ベースの全列挙）

| 関数 | 変更 | 呼び出し元 |
|---|---|---|
| `beginLteUartAndModem()`（`transport.cpp:292`） | `LteInitResult beginLteUartAndModem(uint32_t hardEndMs, bool failFastWhenSilent)` | `connectLte`:520（`hardEndMs`, `config::kLtePowerRelayEnabled`）、`probeLteModem`:722（`kNoLimit`, `false`） |
| `wakeLteModemAt()`（:220） | `(uint32_t hardEndMs)` | begin:312、`recoverLteModemFromPowerOff`:241,251 |
| `recoverLteModemFromPowerOff()`（:239） | `(uint32_t hardEndMs)` | begin:330 |
| `prepareLteForPlanD()`（:164） | `(uint32_t hardEndMs)` | begin:317 |
| `connectLte()`（:508） | `(TransportMetrics&, uint32_t hardEndMs)` | `connectTransport`:675 |
| `reconnectTransport()`（:606） | `(TransportMetrics&, uint32_t hardEndMs)` | `reconnectActiveTransport`:708 |
| `connectTransport()`（:652、公開） | `(TransportMetrics&, uint32_t hardEndMs)` | `reconnectTransport`:627,639、`connectTransportWithRetry`:698 |
| `reconnectActiveTransport()`（:707、公開） | `(TransportMetrics&, uint32_t hardEndMs)` | `main.cpp:365`（`publishWithRetry`）、`main.cpp:773`（BootMode） |
| `connectTransportWithRetry()` | **変更なし** | `main.cpp:621,768,778` |
| `probeLteModem()` | 変更なし（内部で `kNoLimit, false`） | `main.cpp:401,496,539` |
| `powerOffLteModem()` | 変更なし | — |

### 3.2 `firmware/include/transport.h`

- `TransportMetrics` に `bool modemSilent = false;` を追加。
- Arduino 非依存の inline を追加（g++ 単体で確認できる）。

```cpp
constexpr uint32_t kNoLimit = 0;
inline uint32_t deadlineAfter(uint32_t startMs, uint32_t budgetMs) {
  const uint32_t e = startMs + budgetMs;
  return e == kNoLimit ? 1u : e;
}
inline uint32_t remainingMsAt(uint32_t endMs, uint32_t nowMs) {
  if (endMs == kNoLimit) return UINT32_MAX;
  const int32_t d = static_cast<int32_t>(endMs - nowMs);
  return d > 0 ? static_cast<uint32_t>(d) : 0;
}
```

- 上表の公開 2 関数のシグネチャを更新。

### 3.3 `firmware/include/config.h`

```cpp
constexpr uint32_t kConnectHardMs =
    (PSS_CONNECT_PHASE_MS + 10000 < PSS_CYCLE_MAX_ACTIVE_MS)
        ? PSS_CONNECT_PHASE_MS + 10000
        : PSS_CYCLE_MAX_ACTIVE_MS;
```

「cycle = connect 45 + publish 20 + margin 10」の根拠をコメントに書く。`static_assert` は入れない（LoRaWAN・既定 env で `connect + publish > cycle` になるため）。

### 3.4 `firmware/src/transport.cpp` — 置換コード

前提: `logModemAt` に既定引数を追加する（`void logModemAt(const char* cmd, uint32_t timeoutMs = 5000)`、`waitResponse(timeoutMs, response)`）。以下を、現行の `wakeLteModemAt` / `recoverLteModemFromPowerOff` / `prepareLteForPlanD` / `beginLteUartAndModem` と置き換える。`logLteInitFailure`、`startLteUart`、`stopLteUart`、`modemRespondsToAt` は変更しない。

```cpp
// ---- deadline helper（無名 namespace 内。hardEndMs: 絶対 millis、0 = 無期限）----
constexpr uint32_t kInitReserveMs = 20000;  // modem.init() 実用最悪約14s + 余裕
constexpr uint32_t kRetryMinMs = kInitReserveMs + 5000;  // stop 2s + settle 2.5s
constexpr uint32_t kDiagMinMs = 20000;                   // 診断 AT 4本
constexpr uint32_t kMinNetworkWaitMs = 5000;             // 実測 attach 約2.5s の約2倍

enum class LteInitResult : uint8_t { kOk, kSilent, kFailed, kDeadline };

uint32_t remainingMs(uint32_t endMs) { return remainingMsAt(endMs, millis()); }
uint32_t clampMs(uint32_t ms, uint32_t endMs) {
  const uint32_t r = remainingMs(endMs);
  return ms < r ? ms : r;
}
void delayBounded(uint32_t ms, uint32_t endMs) {
  const uint32_t d = clampMs(ms, endMs);
  if (d > 0) delay(d);
}

// OK でも ERROR でも「生きている」。waitResponse は無応答のとき 0 を返す。
bool modemAnyResponse(uint32_t timeoutMs) {
  modem.sendAT("");
  return modem.waitResponse(timeoutMs) != 0;
}

// 1回の取りこぼしで無応答と断定しない（1000ms x 2）。clamp しない（最大 +2s）。
bool modemIsSilent() {
  return !modemAnyResponse(1000) && !modemAnyResponse(1000);
}

bool wakeLteModemAt(uint32_t hardEndMs) {
  for (uint8_t i = 0; i < 10; ++i) {
    if (remainingMs(hardEndMs) < 1000) {
      return false;  // 1回分（waitResponse 1s）に満たなければ打ち切り
    }
    modem.sendAT("");
    if (modem.waitResponse(1000L) == 1) {
      return true;
    }
    delayBounded(300, hardEndMs);
  }
  return false;
}

bool recoverLteModemFromPowerOff(uint32_t hardEndMs) {
  Serial.println("LTE: recovering modem (AT wake + CFUN=1,1)...");
  if (!wakeLteModemAt(hardEndMs)) {
    Serial.println("LTE: no AT during wake");
    return false;
  }
  const uint32_t cfunMs = clampMs(30000L, hardEndMs);
  if (cfunMs == 0) {
    return false;
  }
  modem.sendAT("+CFUN=1,1");
  if (modem.waitResponse(cfunMs) != 1) {
    Serial.println("LTE: CFUN=1,1 failed");
    return false;
  }
  delayBounded(3000, hardEndMs);
  return wakeLteModemAt(hardEndMs);
}

// 各 AT の待ちを hard で縮める。期限に達したら false（打ち切り）。
// 期限内に最後まで進めば、現行どおり true を返す。
bool prepareLteForPlanD(uint32_t hardEndMs) {
  Serial.println("configure plan-D (Docomo Cat-M1)...");
  auto waitOk = [&](uint32_t ms) -> int8_t {
    return modem.waitResponse(clampMs(ms, hardEndMs));
  };
  auto expired = [&]() { return remainingMs(hardEndMs) == 0; };

  modem.sendAT("+CFUN=0");
  waitOk(10000L);
  if (expired()) return false;

  modem.sendAT("+CBANDCFG=\"CAT-M\",1,19");
  if (waitOk(10000L) != 1) {
    Serial.println("WARN: CBANDCFG 1,19 failed");
  }
  if (expired()) return false;
  logModemAt("+CBANDCFG?", clampMs(5000, hardEndMs));

  modem.sendAT(String("+CGDCONT=1,\"IP\",\"") + config::kLteApn + "\"");
  waitOk(10000L);
  if (expired()) return false;
  modem.sendAT(String("+CNCFG=0,1,\"") + config::kLteApn + "\"");
  waitOk(10000L);
  if (expired()) return false;

  modem.sendAT("+CMNB=1");
  if (waitOk(10000L) != 1) {
    Serial.println("WARN: CMNB=1 failed, trying CMNB=3");
    modem.sendAT("+CMNB=3");
    waitOk(10000L);
  }
  if (expired()) return false;
  modem.sendAT("+CNMP=38");
  waitOk(10000L);
  modem.sendAT("+CEREG=1");
  waitOk(1000L);
  modem.sendAT("+COPS=0");
  waitOk(10000L);
  if (expired()) return false;

  modem.sendAT("+CFUN=1");
  waitOk(15000L);
  delayBounded(3000, hardEndMs);
  if (expired()) return false;

  logModemAt("+CMNB?", clampMs(5000, hardEndMs));
  return true;
}

// hardEndMs: 絶対 millis（0 = 無期限）。failFastWhenSilent: 無応答と判定したら再試行せず諦める。
// failFastWhenSilent に関係なく、無応答が確定して返すときは UART を止める
// （無応答モデムへの CPOWD 約33.5s を省く。powerOffLteModem は UART 未開始なら即 return）。
LteInitResult beginLteUartAndModem(uint32_t hardEndMs, bool failFastWhenSilent) {
  constexpr uint8_t kMaxAttempts = 3;
  bool lastAttemptSilent = false;
  bool deadlineHit = false;

  // 諦めるとき: 無応答なら UART を止めて kSilent、応答があれば ifAlive
  // （UART は開いたまま。後段の CPOWD に任せる）
  auto abandon = [&](LteInitResult ifAlive) -> LteInitResult {
    ltePlanDReady = false;
    if (modemIsSilent()) {
      stopLteUart();
      return LteInitResult::kSilent;
    }
    return ifAlive;
  };

  for (uint8_t attempt = 1; attempt <= kMaxAttempts; ++attempt) {
    lastAttemptSilent = false;

    if (attempt > 1) {
      if (remainingMs(hardEndMs) < kRetryMinMs) {
        Serial.println("LTE modem init: deadline, no more retries");
        deadlineHit = true;
        break;
      }
      Serial.printf("LTE modem init retry %u/%u\n", attempt, kMaxAttempts);
      stopLteUart();
      delayBounded(2000, hardEndMs);
    }

    startLteUart();
    if (attempt == 1 && config::kLtePowerRelayEnabled) {
      // #46: このサイクルの relayLteOn() で今まさにコールド電源投入された直後。
      delayBounded(config::kLteColdBootSettleMs, hardEndMs);
    } else {
      // After CPOWD the modem needs Toff-on >= 2 s before UART is reliable.
      delayBounded(attempt == 1 ? 1500 : 2500, hardEndMs);
    }
    (void)wakeLteModemAt(hardEndMs);

    // modem.init() は中断できない（無応答 約10.3s、応答ありの実用最悪 約14s）。
    // 残りが kInitReserveMs 未満なら呼ばない。
    const bool canInit = remainingMs(hardEndMs) >= kInitReserveMs;

    if (canInit && modem.init()) {
      if (!ltePlanDReady) {
        Serial.println("LTE plan-D setup (first boot this power cycle)");
        if (!prepareLteForPlanD(hardEndMs)) {
          // 現行: logLteInitFailure(); continue;（recover は呼ばない）を維持。
          if (remainingMs(hardEndMs) >= kDiagMinMs) {
            logLteInitFailure();
          }
          if (remainingMs(hardEndMs) == 0) {
            // deadline で打ち切られた。init 成功直後なので通常は生きているが、
            // 途中で落ちた場合だけ CPOWD を省くため確認する。
            return abandon(LteInitResult::kDeadline);
          }
          continue;
        }
        ltePlanDReady = true;
      }
      return LteInitResult::kOk;
    }

    if (canInit) {
      Serial.printf("LTE modem.init() failed (attempt %u/%u)\n", attempt,
                    kMaxAttempts);
    } else {
      Serial.println("LTE modem.init() skipped: deadline");
      deadlineHit = true;
    }

    const bool silent = modemIsSilent();
    lastAttemptSilent = silent;
    if (silent && failFastWhenSilent) {
      Serial.println("LTE modem silent: giving up");
      stopLteUart();
      ltePlanDReady = false;
      return LteInitResult::kSilent;
    }
    if (!canInit) {
      break;
    }

    if (!silent && remainingMs(hardEndMs) >= kDiagMinMs) {
      logLteInitFailure();  // 無応答だと出力が空で約20s 無駄なので応答があるときだけ
    }
    if (attempt < kMaxAttempts && recoverLteModemFromPowerOff(hardEndMs)) {
      lastAttemptSilent = false;  // 復旧した。次の attempt で判定し直す
      continue;
    }
  }

  ltePlanDReady = false;
  if (lastAttemptSilent) {
    stopLteUart();
    return LteInitResult::kSilent;
  }
  return deadlineHit ? LteInitResult::kDeadline : LteInitResult::kFailed;
}
```

現行の分岐は保たれている。`init` 失敗 → 診断 → `attempt < 3 && recover` → `continue`。`init` 成功・plan-D 失敗 → 診断 → `continue`（recover なし）。意図した差分は次の 3 点だけ。

1. `init` 失敗後の無応答プローブ（最大 +2s）。
2. 無応答のときは診断 AT 4 本を省く。
3. 無応答が確定したまま返るときは UART を止める。

`probeLteModem`（`hardEndMs = 0`、`failFast = false`）では `remainingMs()` が常に `UINT32_MAX` で、deadline の分岐が一切効かず、従来の 3 回リトライになる。

呼び出し側:

```cpp
// connectLte（:520 付近）
const LteInitResult init =
    beginLteUartAndModem(hardEndMs, config::kLtePowerRelayEnabled);
if (init != LteInitResult::kOk) {
  metrics.modemSilent = (init == LteInitResult::kSilent);
  Serial.println("LTE modem init failed");
  return false;
}

// probeLteModem（:722）
result.initOk = beginLteUartAndModem(kNoLimit, false) == LteInitResult::kOk;
```

そのほかの `transport.cpp` の変更:

- `connectLte`: `waitForNetwork` の前で、残りが `kMinNetworkWaitMs` 未満なら待たず `powerOffLteModem()` して失敗。それ以外は `waitForNetwork(min(kLteNetworkTimeoutMs, remaining))`。`gprsConnect`・証明書処理・`connectMqtt` の前に、残りが 0 なら `powerOffLteModem()` して失敗。
- `reconnectTransport` / `connectTransport`: `hardEndMs` を下に渡すだけ。
- `connectTransportWithRetry`: ループ先頭の予算確認は現行（soft）のまま。`deadlineAfter(cycleStartMs, config::kConnectHardMs)` を作って `connectTransport` に渡す。失敗した attempt の直後に `if (metrics.modemSilent) { ログ; break; }`（次の `disconnectTransport` と `delay` は実行しない）。

### 3.5 `firmware/src/main.cpp`

`runCycle`: `historyLogRecordCycle`（602）の直後、`mustPublish`（604）の直前に追加。

```cpp
static bool wdtRebootHandled = false;
if (!wdtRebootHandled && esp_reset_reason() == ESP_RST_TASK_WDT) {
  wdtRebootHandled = true;  // kDisableDeepSleep env はリセットされないので1回だけ
  ledgerRecordFailure(CycleOutcome::kBudgetExhausted, status, bootCount, 0, 0,
                      config::kWatchdogTimeoutMs);  // 前サイクルが WDT で落ちた近似値
  Serial.println("watchdog reset: skip send this cycle");
  sleepNow("watchdog-reset", millis() - cycleStart);
  return;
}
```

- `publishWithRetry:365`: `reconnectActiveTransport(metrics, deadlineAfter(cycleStart, config::kCycleMaxActiveMs))`。
- `runBootMode:773`: `reconnectActiveTransport(metrics, deadlineAfter(slotStart, config::kConnectHardMs))`。
- `runBootMode:776-780`: reconnect が失敗しても `metrics.modemSilent` なら Stage 3 の `connectTransportWithRetry` に進まない（各スロットで約 30s の二重試行を省く）。

### 3.6 ドキュメント（最小）

- `firmware/README.md` L51 付近の 1 行を置き換え: 「接続は `PSS_CONNECT_PHASE_MS`（45 秒）を目安に打ち切る。モデムが AT に一度も応答しなければ約 30 秒で諦めて Deep Sleep する（#87）。1 サイクルが上限（`PSS_CYCLE_MAX_ACTIVE_MS`）を超えたらウォッチドッグで再起動する（#41）」
- `firmware/README.md` L65 の表の `task_wdt` 行に追記: 「`task_wdt` で起動した最初のサイクルは送信せず、`budget_exhausted` を記録して Deep Sleep する（#87）」
- `docs/sync-delivery-design.md` §4.1 の表の直後に 1 行: 「`PSS_CONNECT_PHASE_MS` は新しい試行を始める上限（soft）。実行中の待ち（AT・`waitForNetwork`）は +10 秒の hard で縮める（#87）」

### 3.7 ブランチ・PR

- ブランチ: `fix/87-lte-modem-silent-watchdog-loop`。コミットは `fix(#87): ...`。PR 本文に `Closes #87`、事故の経緯、実機検証ログ、`TinyGSM @ x.y.z` を載せる。
- 1PR = 1目的に収まる。BootMode の 1 行と `prepareLteForPlanD` の clamp は、同じ目的（無応答・途中で落ちるモデムで WDT を踏まない）。

---

## 4. 最悪時間の計算表

relay-pot、起点 = `cycleStart`、soft 45s、hard 55s、WDT 95s。

| # | ケース | 現状 | 修正後 |
|---|---|---|---|
| 1 | モデム無応答（今回の事象） | 理論約 169s。実測では WDT 95s が先に発火 | settle 5 + wake 13 + init 10.3 + プローブ 2 = **約 30s** で `kSilent` → UART 停止 → `connect_failed` → relay OFF → Deep Sleep。WDT まで約 65s |
| 2 | 同上（publish 中の再接続・BootMode スロット ≥1） | deadline なし | 約 30s で失敗。Stage 3 の二重試行は `modemSilent` で省略 |
| 3 | 応答ありだが init が失敗し続ける（SIM 異常など。実用最悪） | 数分 | 1 回約 19s（settle 5 + init 14）。attempt 2 は残り ≥25s のときだけ。CPOWD（応答あり）約 5s を含めて **約 55〜60s** |
| 4 | 3 の理論最悪（init が 34.3s かかる） | — | init の開始は残り ≥20s（≤35s）。35 + 34.3 + CPOWD 約 5 = **約 74s**。途中でモデムが落ちたらプローブで `kSilent` になり CPOWD が走らない |
| 5 | init が遅れて成功（40s）→ attach できない | 40 + 45 + CPOWD 5 = 約 90s（**WDT 95s と競合**） | `waitForNetwork(min(45, 15))` で約 56.3s で失敗 + CPOWD 約 5s = **約 61s** |
| 6 | plan-D 中にモデムが落ちる | 待ちの合計約 99s で **WDT を超える** | 各待ちを hard で clamp。**約 61s** |
| 7 | 通常の送信サイクル | 約 16.8s（中央値） | 変化なし |
| 8 | `gprsConnect` の内部（応答あり・網に登録済み） | 理論約 360s。通常 1〜2s | **変更なし（残余リスク）**。呼び出し前の hard チェックのみ |
| 9 | `connectMqtt` の TLS（`modemSslConnectAws` 1 回） | 理論約 60s 台。実績約 1.5s | **変更なし（残余リスク）** |

- publish フェーズの再接続（hard = 75s）の後始末込みの上限: 75 + clamp 精度 1.3 + CPOWD 約 5 ≈ 81s < 95s。init が理論最悪（34.3s）かかる二重故障でも 75 − 20 + 34.3 + 5 = 94.3s で、WDT まで 0.7s の余裕。実用最悪の init（14s）なら約 74s。この余裕は `PSS_WATCHDOG_MARGIN_MS`（20s）に依存する。

### 4.1 hard の実値（`platformio.ini` の全 env）

| env | CYCLE_MAX | CONNECT | `kWatchdogTimeoutMs` | hard（`min`） |
|---|---|---|---|---|
| `xiao-s3-aws-lte`、`-debug`、`-relay`、`-relay-debug`、`-relay-pot` | 75000 | 45000 | 95000 | 55000 |
| `xiao-s3-lorawan` 系 | 60000 | 30000 | 80000 | LTE 経路を通らないので未使用 |
| `xiao-s3`、`xiao-s3-aws` 系 | 60000（既定） | 45000 | WDT 無効 | 55000 |
| test 系 env | 既定 | 既定 | — | `runCycle` を通らない |
| `secrets.example.h:53` の例（`CYCLE_MAX 45000`） | 45000 | 45000 | 65000 | `min` により **45000** |

---

## 5. テスト・検証計画

### 5.1 ビルド確認（証明書のある別マシンで）

準備（git 管理外）: `cp firmware/include/secrets.example.h firmware/include/secrets.h` して編集し、`firmware/certs/` に証明書 3 ファイル（`AmazonRootCA1.pem` / `device.pem.crt` / `private.pem.key`）を置く。

`transport.cpp` と `transport.h` は全 env に効くので、LTE 以外も含めてビルドする。

```bash
cd firmware
pio run -e xiao-s3-aws-lte-relay-pot
pio run -e xiao-s3-aws-lte-relay
pio run -e xiao-s3-aws-lte
pio run -e xiao-s3-lte-test
pio run -e xiao-s3-lte-poweroff-test
pio run -e xiao-s3-lorawan-pot
pio run -e xiao-s3
```

ビルドログの `TinyGSM @ x.y.z` を PR に残す。

### 5.2 deadline ヘルパの使い捨て確認（コミットしない）

`transport.h` の inline（`deadlineAfter`、`remainingMsAt`）は Arduino 非依存。実装後に、実際の `firmware/include/transport.h` を `#include` した小さな `check.cpp` を `g++ -std=c++17 -Wall -Wextra` で単体コンパイルして実行し、次を確認する（計画段階で同じコードを別ファイルで実施済み、OK）。

- `kNoLimit` が `UINT32_MAX` を返す。
- 境界（残り 1 で 1、ちょうど期限で 0、期限後で 0）。
- `millis()` が `UINT32_MAX` 付近から wrap しても 45000ms が正しく数えられる。
- 終了時刻がちょうど 0 になる場合は 1 に置き換えられ、無期限と衝突しない（1ms ずれる。許容）。

native テスト基盤は本 PR では作らない。silent 判定などの分岐の検証は実機のみ。

### 5.3 実機検証

**再現の理屈**（`relay.cpp` から）: リレーはラッチ式で、状態はパルスでしか変わらない。リレーの制御ケーブルを外すと、以降の SET / RESET は届かず、リレーは外した時点の状態で固定される。OFF のときに外せば「SET を送っても通電しない」状態になり、#87 の事象（テスターで NO が 0.77V、カチッという音が無い）と同じになる。ON の状態（サイクル中、`relay: SET` の後 〜 `relayLteOff()` の前）で外すと、通電したまま固定されて再現しない。`sleepNow()` は必ず `relayLteOff()` のあとで Deep Sleep に入るので、**Deep Sleep 中は常に OFF**。この間に外せば安全。

手順（`xiao-s3-aws-lte-relay-pot` を書き込む。Deep Sleep しない `-debug` では確認できない）:

1. 通常どおり動かし、`sleep reason=...` のログが出て USB が切れた（Deep Sleep に入った）ことを確認する。
2. その Deep Sleep 中に、リレー（D0）の Grove ケーブルを Shield 側で抜く。
3. LTE-M の Grove VCC をテスターで測り、ほぼ 0V（OFF）であることを確認する（ケーブルの抜き差しで SIG が浮き、偽のエッジが入る可能性がある）。
4. 次の起床（約 300s 後）のログを取る。Deep Sleep で USB CDC が切れるので、再接続して追従する監視を使う。
5. 期待値:
   - `relay: SET (LTE ON)` → 約 30s 後に `LTE modem.init() failed` → `LTE modem silent: giving up` → `ERROR: connect phase failed`。
   - 次が `sleep reason=connect-failed ... active_ms≈28000〜32000`。この間に `powerOffLteModem: AT+CPOWD=1` が**出ない**こと。
   - 直後に `relay: RESET (LTE OFF)`、USB が切れる。
6. 約 300s 後の再起動で `reset=deep_sleep`（`task_wdt` ではない）、`prevOutcome=connect_failed pending=1` になっていること。
7. ケーブルを戻して数サイクル待ち、送信が再開し、`sync.prevOutcome=connect_failed` と `sync.prevActiveMs≈30000` がテレメトリに残ることを確認する。
8. 電流の裏取り: `tools/power-logger`（U200）で、起きている時間が約 30s で、その後 Deep Sleep 電流（約 0.4mA）に落ちることを確認する。

`task_wdt` スキップの確認: 実際に WDT を踏ませる。(a) 修正前のファームで一度 WDT 再起動を発生させ、直後に修正版へ差し替える。(b) 一時的に `runCycle` に `delay(100000)` を入れて踏ませる（コミットしない）。期待値は `reset=task_wdt` → `watchdog reset: skip send this cycle` → `sleep reason=watchdog-reset` → 次の起床が `deep_sleep`、`prevOutcome=budget_exhausted prevActiveMs=95000`。debug env（Deep Sleep なし）では、スキップが最初の 1 回だけで、以降の周期が通常に戻ること（ラッチの確認）。

リレー無し env（`xiao-s3-aws-lte`）の確認: LTE-M の VCC を抜いた状態で、約 40s で `kSilent`（UART 停止、CPOWD なし）になること（従来のリトライ順序は残るが、hard で時間が縮む）。

---

## 6. リスク・未決事項

1. **挙動変更**: リレーあり環境で、無応答のモデムに対する attempt 2/3 のリトライが無くなる（根拠は §2.1）。test 系 env（`probeLteModem`）とリレー無し env のリトライは従来どおり。
2. **`waitForNetwork` の clamp**: 通常運用への影響は無い。弱電波で attach に 40s かかる機体は、hard までの残り時間に縮まる。
3. **残余リスク（本 PR では直さない）**: `gprsConnect` の内部（理論約 360s）と `modemSslConnectAws`（理論約 60s 台）は中断不能。応答あり・網に登録済みの状態で長引く場合だけで、通常は 1〜2s。
4. **失敗が続くとき**: 5 分ごとに約 30s 起きる。バックオフは #89。
5. **`kBudgetExhausted` の流用**: WDT と予算超過が outcome だけでは区別できない（§2.5）。
6. **`int_wdt` / `wdt` / `panic` ループ**: 同種の「Deep Sleep しない再起動ループ」になりうる。本 PR の対象外。
7. **Wi-Fi + LTE フォールバック env**: hard の期限は LTE 経路にだけ効く。現行 env に該当構成は見当たらない（`xiao-s3-aws-lte*` は `PSS_LTE_ONLY=1`）。
8. **TinyGSM のバージョン未固定**: §1.3 の時間は v0.12.0 のもの。

## 7. 関連 Issue

- #41 ウォッチドッグ、#46 ラッチングリレーによる LTE-M の電源遮断、#74 ブラウンアウトの調査
- 本件から起票したフォローアップ: #88（リレーの原因切り分け）、#89（バックオフと無通信アラート）、#90（docs の訂正）、#91（LoRaWAN 版の確認）
