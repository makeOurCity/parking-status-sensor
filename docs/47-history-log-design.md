# 端末側 状態変化履歴ログの設計(Issue #47)

端末(XIAO)単体で、過去のセンサー観測(満車⇔空車⇔不明の判定結果とその根拠となるraw値)を、現地でUSB接続した際にシリアルログから確認できるようにする。クラウド側の分析・ダッシュボード用途ではなく、**現地での端末単体診断**が目的。

- 関連 Issue: #47
- 前提: [docs/sync-delivery-design.md](sync-delivery-design.md) §1.4 で Outbox(送信再送キュー)を撤廃した経緯があるが、**本Issueはこれを覆すものではない**。ここで追加するのは送信とは無関係な読み取り専用のローカル診断ログであり、Outbox問題(接続失敗時の再送・重複publish)の再発条件には該当しない。

## 改訂履歴

- v1〜v4: サブエージェントによる4回のドラフト・レビューサイクルを経て、NVS容量計算・整合性を確定(状態変化イベントのみを記録する設計)。
- **v5(本版)**: レビュー後の追加確認により、記録方針を「状態が変化した瞬間のみ」から**「毎サイクル(5分ごと)無条件に記録」**へ変更。あわせて記録内容をMQTTペイロードの`raw`(red/green/blue/white)と同一にする方針に確定。これに伴いエントリのデータモデル・容量計算・保持期間の見積もりを全面的に再計算した。

---

## 1. 概要とスコープ

### 1.1 やること

- **毎起床サイクル(5分ごと)、無条件に**1エントリをNVS上のリングバッファへ追記する読み取り専用ローカル診断ログを追加する(状態変化の有無は問わない)。
- 1エントリには、そのサイクルで観測した `status` と、MQTTペイロードの `raw`(`red`/`green`/`blue`/`white`)と同一のセンサー生値を記録する。
- 新規モジュール `firmware/include/history_log.h` / `firmware/src/history_log.cpp` として実装し、既存の `sync_ledger.*` には**一切変更を加えない**。
- `main.cpp` の `runCycle()` 内、`classifyStatus()` 直後の1箇所にのみフック(1関数呼び出し)を追加する。センサー読み取り成功時は毎回呼ぶ(`mustPublish()`の判定より前)。
- USB再接続(=非タイマー起床)を検知したとき、`setup()` 内でリングバッファ全件をシリアルへダンプする。
- `waitForSerial()` の待機ウィンドウ内で1文字コマンド(`'h'`)を受け付け、任意タイミングでも(本番・デバッグ両ビルドで)ダンプできるようにする。
- MQTT payload・`sync.*`・`mustPublish()`・`publishWithRetry()`・`SyncLedger` には一切触れない。LTE接続や再送を一切トリガーしない。

### 1.2 やらないこと(スコープ外)

- 未送信データの再送キュー化(Outbox の復活)は行わない。
- クラウド側での参照・ダッシュボード化(bridge/Orion変換)は対象外。
- 複数コマンド・フィルタ機能等、高度なシリアルCLIは対象外。
- 時刻同期そのものの改善(NTP/NITZの信頼性向上)は対象外。既存の`ensureLteClock()`/`syncClock()`の挙動をそのまま利用する。
- raw値のチャンネル削減・ビット圧縮・差分エンコード等は行わない(**確定事項**: MQTTペイロードの`raw`と同一の情報を保持する。理由は§3.5参照)。

---

## 2. データ設計

### 2.1 エントリのバイトレイアウト(16バイト固定)

「状態変化イベント」ではなく「そのサイクルの観測スナップショット」を1エントリとする。

| offset | フィールド | 型 | 説明 |
|---|---|---|---|
| 0-3 | `timestampEpoch` | u32 (LE) | UTC unix time。`0` = 未同期 |
| 4 | `status` | u8 | そのサイクルで観測した `ParkingStatus`(0=full, 1=available, 2=unknown) |
| 5 | `flags` | u8 | bit0 = 時刻同期済みフラグ。bit1-7予備(常に0) |
| 6 | `bootCountLo8` | u8 | `bootCount & 0xFF`(下位8bit) |
| 7 | (予備) | u8 | 未使用。将来項目用に確保 |
| 8-9 | `red` | u16 (LE) | MQTTペイロード `raw.red` と同一値 |
| 10-11 | `green` | u16 (LE) | 同 `raw.green` |
| 12-13 | `blue` | u16 (LE) | 同 `raw.blue` |
| 14-15 | `white` | u16 (LE) | 同 `raw.clear` |

構造体の暗黙のパディングに依存させず、`encodeEntry(uint8_t out[16], ...)` / `decodeEntry(const uint8_t in[16], ...)` という明示的なシリアライズ関数で実装する。

**設計判断: raw値を4チャンネルそのまま保持する理由(確定)** — 判定ロジック(`classifyStatus()`)自体は`red-green`の差分しか使わないが、本ログの目的は「クラウドに送っているのと同じ生データを、現地で通信なしに確認できること」であり、チャンネルを間引く・圧縮すると「ログの意味がない」(ユーザー判断)。よって圧縮や間引きは行わず、MQTTペイロードの`raw`と完全に同じ4チャンネルをそのまま保持する。

**設計判断: 未同期表現に専用flagsビットを使う理由(変更なし)** — `timestampEpoch` が「実時刻」か「無効値」かを、値の大小(閾値判定)だけに頼らず明示的な `flags.bit0` で表現する。詳細な根拠は§3.4参照。

### API シグネチャ

```cpp
#include "sensor.h"  // RawSample

void historyLogRecordCycle(ParkingStatus status, const RawSample& sample,
                            uint32_t bootCount);
```

`historyLogRecordIfChanged()`という名称・「変化検知」のロジックは廃止し、**無条件記録**を表す`historyLogRecordCycle()`に変更した。時刻取得(`currentTimestampOrZero()`)は関数内部で行う。

### 2.2 リングバッファの実装方式

NVS(Preferences)の `putBytes`/`getBytes` は**キー単位の全置換**であり、部分追記はできない。方式を3つ比較する(この比較自体は記録トリガーが「変化時のみ」でも「毎サイクル」でも同じ)。

| 方式 | 概要 | 1回の書き込みあたりの量 | 判定 |
|---|---|---|---|
| A. 単一blob全体書き換え | 全エントリを1つのNVSキーに保持 | capacity全体(数KB)を毎回rewrite | 不採用 |
| **B. セグメント分割**(採用) | `segments`個のセグメントに分割し、`entries_per_segment`件をまとめて1NVSキー(blob)として保持。書き込みは対象セグメントのみ | 該当セグメント分のみ(§2.4で800B) | **採用** |
| C. 個別キー(1件=1キー) | エントリごとに独立したNVSキー | 16Bのみだが、NVSプリミティブエントリは1キー最低32B消費するため大容量化に不向き | 不採用 |

**セグメントのペイロードに独自ヘッダは持たせない**。各セグメントのNVS blobは、そのセグメント分のエントリ(16B×`entries_per_segment`)を隙間なく連結した生バイト列のみである。書き込み位置は、ハウスキーピングキー `total`(§2.5)から算出する:

```
書き込み先セグメント番号 = (total / entries_per_segment) mod segments
セグメント内オフセット   = total mod entries_per_segment
```

`total` は**毎サイクル**1つずつ増加するモノトニックカウンタであり、この値だけで「次にどこへ書くか」と「累積で何サイクル記録したか」の両方を導出できる。

**「毎サイクル記録」への変更に伴う簡素化**: 従来の「変化検知」設計では、前回観測値と比較するための`lastobs`キーが必要だった。無条件記録に変わったことで、この比較ロジックと`lastobs`キー自体が不要になった(§2.5でハウスキーピングキーが1個減っている)。

### 2.3 NVS容量計算モデル(変更なし)

ESP32のNVS(ESP-IDF)は、1キーにつき**32バイト固定長の内部エントリ**を単位として値を保存する。

- プリミティブ型(u8/u16/u32/bool等): 1キー = 1エントリ(32B)。既存 `SyncLedger`(`pss_sync`、11キーすべてプリミティブ)の実消費量が **352B**(=11×32B)であることと整合する。
- blob型(`putBytes`): **1個のインデックスエントリ(32B)** + **データ本体をceil(サイズ/32)個の32Bデータエントリに分割**して保存する。
- 新規namespace(`pss_hlog`)の追加自体にも、NVS内部のnamespace名→ID登録用エントリが**約32B**消費される。

### 2.4 デフォルト容量の再計算(エントリ16B・毎サイクル書き込み前提)

```
NVS全体                 20480B (20KB)
既存 pss_sync           -352B  (SyncLedger、11キー×32B)
安全マージン            -8192B (2ページ相当)
────────────────────────────
pss_hlog に使える予算    11936B
```

**候補値: `capacity=672`, `segments=14`(`entries_per_segment = 672/14 = 48`)**

```
セグメントのデータ本体 = 48エントリ × 16B = 768B  (768/32=24、32Bエントリの端数ゼロ)
セグメント1個の消費   = 32B(インデックスエントリ) + 768B(24個のデータエントリ) = 800B
セグメント14個の消費  = 14 × 800B = 11200B

ハウスキーピングキー(§2.5の4キー: sv/cap/segs/total。lastobsは削除) = 4 × 32B = 128B
namespace登録エントリ(pss_hlog新規)                                = 32B
──────────────────────────────────────────────
pss_hlog 総消費                                                    11360B

予算11936Bに対する余裕 = 11936 - 11360 = 576B(約4.8%)
```

**保持期間の見積もり(最重要の変更点)**:

```
毎サイクル(5分ごと)書き込み = 288件/日
保持期間 = 672件 ÷ 288件/日 ≈ 約2.3日分
```

以前(状態変化時のみ記録、8Bエントリ)の試算では約1344件で数週間〜数ヶ月分をカバーする設計だったが、「毎サイクル記録」+「エントリ16B(4チャンネル分のraw値を含む)」への変更により、**保持期間は約2.3日分まで縮小する**。ユーザー確認の結果、「最低でも1日分取れれば問題ない」という許容ラインに対し2.3日は余裕があり、この前提で確定する。

**候補値である旨の注記**: この`capacity=672`は机上計算上の候補値であり、実装のデフォルト値として即座にコミットするものではない。[§10](#10-デフォルト容量に関する決定)の通り、実機の`nvs_get_stats()`検証を経てから最終確定する。なお、机上モデルに多少の誤差があり実際に使える容量がここから2〜3割小さくなったとしても(例: 672→500件相当)、保持期間は500÷288≈1.7日分となり、依然として「1日分以上」の要件は満たせる見込みである。

### 2.5 NVSキー一覧(namespace: `pss_hlog`)

| キー | 型 | 意味 |
|---|---|---|
| `sv` | u8 | schemaVersion(初期値1)。存在有無で初回起動を判定 |
| `cap` | u16 | 書き込み時点のコンパイル済み容量(`PSS_HISTORY_LOG_CAPACITY`) |
| `segs` | u16 | 同上、セグメント数(`PSS_HISTORY_LOG_SEGMENTS`) |
| `total` | u32 | 起動来の記録サイクル数の累積総数(モノトニック増加、ラップしても保持)。書き込み位置の算出と`historyLogLifetimeTotal()`の両方に使う |
| `seg0`〜`seg13` | blob(768Bの生バイト列) | 各セグメントの実データ(48エントリ×16B、追加ヘッダなし) |

※ 旧設計にあった`lastobs`(直近観測status、変化検知用)は、無条件記録への変更に伴い**不要になったため削除**した(§2.2)。

---

## 3. 記録処理の実装方針

### 3.1 なぜ`SyncLedger`と完全に独立させるか

`SyncLedger.lastConfirmedStatus`(namespace `pss_sync`、キー`lstatus`)は「**配送が確認できた**最新status」であり、`mustPublish()`(main.cpp:204-218)の変化検知にのみ使われる。history_logは「**端末が観測した**生の値」を毎サイクル記録するものであり、配送の成否や送信トリガーの判定とは無関係であるべきなので、`pss_sync`とは完全に別のNVS namespace(`pss_hlog`)を持ち、キーも一切共有しない。

これにより、history_log側の実装・キー構成をどう変更しても(§2.2で`lastobs`キーを削除したように)、`mustPublish()`や送信フローには一切影響しない。この独立性は`grep`/`nm`でも検証できる(§9.2)。

### 3.2 main.cpp への組み込み箇所

`runCycle()` 内、`classifyStatus()` 呼び出し直後(`status` 確定直後)に1行追加する:

```cpp
const ParkingStatus status = classifyStatus(sample, config::kStatusThreshold);
Serial.printf(...);                                     // 既存ログ
historyLogRecordCycle(status, sample, bootCount);        // ★追加: 無条件・毎サイクル
if (!mustPublish(status)) {                              // 既存ロジックは変更なし
  ...
```

この位置を選ぶ理由:
- `mustPublish()` / `publishWithRetry()` / `relayLteOn()` / `connectTransportWithRetry()` / `ledgerRecordConfirmed`/`ledgerRecordFailure` の**どの分岐が実行される前**にも記録が完了する。`mustPublish()==false`(skip)でも`connect_failed`でも、記録は送信結果に依存せず必ず行われる。
- `initSensor()` 失敗パスは `status`/`sample` が未確定のまま return するため、このルートでは記録しない(観測自体が存在しないため)。
- `history_log.cpp` は `transport.h`/`relay.h`/`sync_ledger.h` を一切 `#include` しない。呼び出しグラフレベルで送信フローと非依存であることを機械的に確認できる(§9.2)。

### 3.3 内部ロジック(擬似コード)

```
historyLogRecordCycle(status, sample, bootCount):
  if !config::kHistoryLogEnabled: return

  (ts, synced) = currentTimestampOrZero()  // §3.4
  entry = encodeEntry(ts, synced, status, bootCount & 0xFF,
                       sample.red, sample.green, sample.blue, sample.white)

  total = loadTotal()
  segIndex = (total / entriesPerSegment) mod segments
  offset   = total mod entriesPerSegment
  seg = loadSegment(segIndex)              // 初回はゼロ埋め
  writeEntryAt(seg, offset, entry)
  storeSegment(segIndex, seg)

  saveTotal(total + 1)
```

変化検知の分岐(`if status == prevStatus: return`)がなくなり、**毎回無条件に実行される**シンプルなロジックになった。

### 3.4 `formatTimestamp`ロジックの複製について(変更なし)

`history_log.cpp` は `currentTimestampOrZero()` として、`main.cpp` の無名namespace内 `formatTimestamp()` と同等の閾値判定(`now <= 1700000000`)を独自に複製する。共有ヘッダへの切り出しはmain.cpp側の構造変更を伴うため、変更範囲最小化のため複製のままとする。両ファイルに相互参照コメントを残す。

### 3.5 未同期フラグが必要な理由(確認済み事項の記録)

`transport.cpp`の`ensureLteClock()`を確認した結果:

```cpp
bool ensureLteClock() {
  if (time(nullptr) > 1700000000) {
    return true;  // すでに有効な時刻ならNITZ/NTPへの問い合わせすらしない
  }
  ...
}
```

「通信が確立していれば必ず時刻同期される」という前提は成り立たない。正確には「一度でも同期に成功していれば、以後は接続してもしなくても時刻は有効なまま(ESP32の`time()`はDeep Sleepをまたいで保持される内部RTCドメインに基づくため)」であり、**未同期になるのは「完全な電源断(バッテリー切れ→交換/充電)からの復帰後、最初のLTE接続成功まで」の間に限られる**。

このプロジェクトは実際に現地でのバッテリー切れが発生しており(#46のリレー実装もその対策)、この「完全な電源断からの復帰」は理論上のレアケースではなく実運用上のシナリオである。よって**未同期フラグは残す**(ユーザー確認済み)。

---

## 4. シリアル出力の設計

### 4.1 起動時ダンプ(メイン方式)

`setup()` 内、既存の起床要因判定ブロック(`main.cpp:505-512`)の非タイマー起床(電源投入 or USBリセット)側に `historyLogDumpToSerial()` を追加する:

```cpp
if (cause == ESP_SLEEP_WAKEUP_TIMER) {
  consecutiveTimerWakes++;
} else {
  consecutiveTimerWakes = 0;
  lastSleepEntryUs = 0;
  resetLteRadioCache();
  historyLogDumpToSerial();   // ★追加
}
```

**理由**: 通常運用(Deep Sleepの5分タイマー起床)では発火せず、USB接続タイミングとほぼ一致する。

**ダンプ形式**: newest-first、1行1エントリ。raw値を含む:

```
history: count=672 capacity=672 (full)
[0] boot=142 2026-09-19T08:15:03Z status=full   r=812 g=201 b=340 w=1500
[1] boot=142 <unsynced>          status=full   r=805 g=198 b=335 w=1490
[2] boot=141 2026-09-19T08:10:02Z status=available r=120 g=610 b=95  w=980
...
```

容量672件を全ダンプする場合、1行約65バイト×672 ≈ 44KB。115200bps(≈11.5KB/s)で約3.8秒。この所要時間は非タイマー起床時のみ発生し、通常のDeep Sleepサイクルの `active_ms` 予算には影響しない。

### 4.2 全件 vs 直近N件

デフォルトは全件ダンプ。`PSS_HISTORY_LOG_DUMP_MAX`(0=無制限)で将来の容量拡張時に上限を設けられるようにしておく。

### 4.3 シリアルコマンドによる任意タイミングダンプ

既存の `waitForSerial()` の3秒待機ウィンドウ内で `Serial.available()` を非ブロッキングでチェックし、`'h'` 入力でダンプを強制する:

```cpp
void waitForSerial() {
  const uint32_t start = millis();
  while (!Serial && (millis() - start) < kSerialWaitMs) {
    delay(10);
  }
  while (Serial.available()) {              // ★追加。新たな待機時間は増やさない
    if (Serial.read() == 'h') {
      g_forceHistoryDump = true;
    }
  }
}
```

本番・デバッグ両ビルドで有効にする。Watchdog有効時も `delay()` を挟まない即時チェックのみ。

---

## 5. ファイル構成・API設計

### 5.1 ファイル構成の比較

| 案 | 内容 | 評価 |
|---|---|---|
| A. `sync_ledger.*` を拡張 | 既存構造体・namespace `pss_sync` にフィールド追加 | 送信管理(sync)と診断ログ(history)という無関係な責務が同一ファイルに混在するリスクが高い。**非推奨** |
| B. 新規ファイル `history_log.h`/`.cpp` | 独立モジュール、独立NVS namespace `pss_hlog` | `sync_ledger.*`に一切触れずに済み、影響範囲の説明が容易。**推奨** |

### 5.2 公開API(`firmware/include/history_log.h`)

```cpp
#pragma once
#include <stdint.h>
#include "classify.h"
#include "sensor.h"

// pss_hlog namespace を読み込む。initSyncLedger() の後、setup() 内で呼ぶ。
void initHistoryLog();

// 毎サイクル無条件に1エントリを追記する(観測が存在するサイクルでのみ呼ぶこと。
// initSensor()失敗パスからは呼ばない)。
// LTE/MQTT/SyncLedger には一切依存しない(NVS I/O と Serial のみ)。
void historyLogRecordCycle(ParkingStatus status, const RawSample& sample,
                            uint32_t bootCount);

// リングバッファ全件(または PSS_HISTORY_LOG_DUMP_MAX 件)を Serial へ出力する。
void historyLogDumpToSerial();

// 診断用アクセサ。
uint32_t historyLogStoredCount();     // 現在保持している有効件数(<= capacity)
uint32_t historyLogLifetimeTotal();   // 起動来の累積記録サイクル数(上書きされた分も含む)
```

`history_log.cpp` は `config.h`(定数)、`classify.h`(`ParkingStatus`型)、`sensor.h`(`RawSample`型)をincludeする。`transport.h` / `relay.h` / `sync_ledger.h` は一切includeしない。

内部関数: `encodeEntry`/`decodeEntry`、`segmentKeyFor(slot) -> "seg0".."seg13"`、`loadSegment`/`storeSegment`、`currentTimestampOrZero()`。

---

## 6. config.h に追加するマクロ

```cpp
// #47: 毎サイクルのセンサー観測ログ(NVSリングバッファ)。送信・LTE接続には一切影響しない。
#ifndef PSS_HISTORY_LOG_ENABLED
#define PSS_HISTORY_LOG_ENABLED 1
#endif

// 1エントリ16バイト(timestamp+status+flags+bootCountLo8+raw4ch)。
// §2.4の計算により予算11936Bに対し余裕576B(約4.8%)、保持期間約2.3日分(候補値)。
#ifndef PSS_HISTORY_LOG_CAPACITY
#define PSS_HISTORY_LOG_CAPACITY 672
#endif

// capacity はこの値で割り切れる必要がある(static_assertで保証)。
#ifndef PSS_HISTORY_LOG_SEGMENTS
#define PSS_HISTORY_LOG_SEGMENTS 14
#endif

// 起動時ダンプの最大表示件数。0 = 無制限(全件)。
#ifndef PSS_HISTORY_LOG_DUMP_MAX
#define PSS_HISTORY_LOG_DUMP_MAX 0
#endif
```

```cpp
namespace config {
constexpr bool kHistoryLogEnabled = PSS_HISTORY_LOG_ENABLED;
constexpr uint16_t kHistoryLogCapacity = PSS_HISTORY_LOG_CAPACITY;
constexpr uint16_t kHistoryLogSegments = PSS_HISTORY_LOG_SEGMENTS;
constexpr uint16_t kHistoryLogDumpMax = PSS_HISTORY_LOG_DUMP_MAX;
}  // namespace config

static_assert(PSS_HISTORY_LOG_CAPACITY % PSS_HISTORY_LOG_SEGMENTS == 0,
              "capacity must divide evenly into segments");
static_assert((PSS_HISTORY_LOG_CAPACITY / PSS_HISTORY_LOG_SEGMENTS) * 16 % 32 == 0,
              "segment body must be a multiple of 32B to avoid NVS data-entry padding waste");
```

**安全策**: 実機検証(§9.3)で理論値と乖離が判明した場合、コード変更なしにビルドフラグの変更のみで即座に容量を引き下げられる。

---

## 7. マイグレーション設計(schemaVersion方式、変更なし)

`sync_ledger.cpp` の `initSyncLedger()` と同じパターンを踏襲する。`sv`/`cap`/`segs`不一致時は`prefs.clear()`して再初期化する(診断専用ログのため、継続性より安全性を優先)。

---

## 8. 影響範囲の分析

### 8.1 SyncLedger / 送信フローへの影響: ゼロ(変更なし)

- `sync_ledger.h` / `sync_ledger.cpp` は1バイトも変更しない。
- `history_log.cpp` は `transport.h`/`relay.h`/`sync_ledger.h` を一切includeしない。`nm`/`objdump -t`で機械的に確認できる(§9.2)。
- MQTT payloadには一切フィールドを追加しない。

### 8.2 電力消費への影響(再評価: 毎サイクル書き込みに変更)

従来設計(変化時のみ記録)では「ほとんどのサイクルはNVS読み取りのみ」という前提だったが、**毎サイクル無条件記録に変更したことで、この前提はなくなった**。

- 毎サイクル、セグメント1件分(800B)のNVS書き込みが**必ず**発生する。
- ただし、これは既存の`ledgerRecordConfirmed`/`ledgerRecordFailure`が**元々毎サイクル**呼んでいる`persist()`(11キー分の書き込み、約352B相当)と同種の処理であり、既存フローがすでに毎サイクルNVS書き込みを行っている以上、history_logの追加書き込み(800B)もオーダーとして許容範囲と考えられる。
- LTEモデムへの通電(`relayLteOn()`)や接続処理は本モジュールから一切呼ばれないため、history_log自体が起床時間や消費電力の主要因になることはない。ただし正確な影響は実機での`active_ms`計測(§9.4)で確認する。

### 8.3 フラッシュ摩耗試算(再評価)

毎サイクル(5分ごと、288回/日)、必ずセグメント1個分(800B)を書き込む。これは偶然にも旧設計(8Bエントリ)の「最悪ケース」試算と同じ書き込み量になる。

```
288回/日 × 800B = 225KB/日
NVSパーティション相当のセクタ消去耐性の目安: 約10万回消去 × 20KB ≈ 1.9GB
寿命試算: 1.9GB ÷ 225KB/日 ≈ 8,400日 ≈ 約23年相当(オーダー感の目安)
```

「毎サイクル書き込み」は旧設計では稀な故障モード(センサーのフリッピング)として扱っていたが、本改訂では**これが平常運転そのもの**になる。試算上の数値は変わらないため、実用上の懸念は小さいと判断する。

### 8.4 実装上の制約(実機検証で判明): ESP32-S3ネイティブUSB CDCの起動直後の出力欠落

実機検証(§9.3)の過程で、**ESP32-S3のネイティブUSB CDC(`Serial`)は、ホストが再接続した直後の数行の`Serial.print`出力を確実に取りこぼす**ことが判明した。`pio device monitor`(自前の再接続処理あり)、自前のPythonシリアル読み取りスクリプト、`log2file`フィルタでのファイル直接書き出し、の3種類の手法すべてで再現したため、キャプチャ側の実装の問題ではなく、USB再列挙~ホスト接続確立までの間に送出された分がハードウェア/USBスタックレベルで失われる現象と判断している(CP210x/CH340等のUSB-UARTブリッジと異なり、ネイティブUSB CDCはホストが接続していない間の出力を保持しない)。

この制約により、`initHistoryLog()`内で起動直後に`Serial.printf`していた`hlog: nvs stats ...`は再現性なく欠落した。対策として、この出力は`historyLogDumpToSerial()`の**末尾**(ダンプ本体を出し終えた後)に移した。ダンプ本体は欠落しやすい先頭の数行を過ぎた後も十分な行数があるため、末尾に置いた診断情報は確実に届く。

**教訓**: 今後この`setup()`内で新たな診断出力を追加する場合、起動直後(`waitForSerial()`直後)ではなく、ある程度の出力が先行した後(ダンプの後、など)に置くこと。

---

## 9. 検証計画

### 9.1 単体・境界値テスト(デバッグビルド、Deep Sleep無効)

- [ ] 初回起動(NVS未初期化)で `sv`/`cap`/`segs`/`total` が正しい初期値で書き込まれること
- [ ] **状態変化の有無に関わらず、毎サイクル必ず1件ずつ`total`が増えること**(旧テスト「変化なしなら増えない」は廃止)
- [ ] raw値(red/green/blue/white)が正しくエンコード/デコードされ、MQTTペイロードの`raw`と同じ値であること
- [ ] capacity(テスト用に小さい値、例16)を超えて書き込み、古いものから上書きされ`historyLogStoredCount()`がcapacityで頭打ちになること
- [ ] ラップアラウンド後のダンプが正しい時系列順(newest-first)で、上書き済みの古いエントリが出てこないこと
- [ ] `PSS_HISTORY_LOG_CAPACITY`/`PSS_HISTORY_LOG_SEGMENTS`を変更して再フラッシュし、レイアウト変更時に安全に再初期化されること
- [ ] 時刻未同期状態でエントリを記録し、`timestampEpoch=0, flags.bit0=0`で保存され、ダンプ時に`<unsynced>`と表示されること
- [ ] `bootCount`下位8bitのラップアラウンド(256サイクル)が正しく記録・表示されること

### 9.2 「送信に一切影響しないこと」の確認方法(変更なし)

- [ ] **静的確認**: `grep -n "#include" firmware/src/history_log.cpp` で`transport.h`/`relay.h`/`sync_ledger.h`が含まれないことを確認。ビルド成果物を`nm`/`objdump -t`し、送信関連シンボルへの参照が一切無いことを確認する。
- [ ] **動的確認(実機、LTEビルド)**: `PSS_CHANGE_ONLY_SEND=1`かつ`PSS_LTE_POWER_RELAY_ENABLED=1`の環境で、状態変化を起こさず(`mustPublish()==false`を維持)複数サイクル回す。Serialログに通信起動ログが一切出ないことを確認しつつ、`historyLogRecordCycle()`が**毎サイクル**動作し`total`が増え続けていること。
- [ ] MQTT payloadに履歴ログ由来の新規フィールドが含まれていないことを確認。

### 9.3 容量・フラッシュ摩耗の実機検証(完了)

実機(`xiao-s3-aws-lte-relay-debug`)で`nvs_get_stats()`を実測した。ログ出力は`historyLogDumpToSerial()`の末尾に置いている(初期化直後だとESP32-S3ネイティブUSB CDCがホスト再接続直後の数行を確実に取りこぼすため。§8.4参照)。

```
hlog: nvs stats used=72 free=558 total=630 namespaces=4
```

(履歴95件・セグメント2個分書き込み時点での実測値)

- **実測 total_entries=630**。机上計算(20480B/32B=640)に近いが完全一致ではない(差10エントリはページ予約領域等、NVS内部実装依存)。実測値の方を正とする。
- この時点で`pss_hlog`はまだ14セグメント中2セグメントしか書き込んでおらず、残り12セグメント分(12×25=300エントリ)が今後追加で消費される。
- **満杯時(capacity=672到達時)の推定使用量**: 72(現在値) + 300(残り12セグメント分) = **約372エントリ**。
- **満杯時の推定空き**: 630 - 372 = **約258エントリ(≈8.06KB)**。これは設計時に確保しようとしていた安全マージン(8KB)にほぼ一致しており、`capacity=672`が実機でも安全に収まることが確認できた。
- [x] `nvs_get_stats()`実測完了
- [x] 理論値との突き合わせ完了(近似が妥当と確認)
- [x] `capacity=672, segments=14`を最終値として確定(引き下げ不要)

### 9.3.1 補足: 満杯到達後の完全な実測は本セッションでは未実施

672件到達(セグメント全14個の書き込み)には毎サイクル記録で約2.3日かかるため、本セッションでは満杯到達後の`nvs_get_stats()`は実測していない。上記は部分実測からの単純な線形外挿であり、モデルの前提(1セグメントあたりのエントリ消費が一定)を疑う理由はないが、長期運用の初期段階で余裕があれば満杯到達後の値も確認するとより確実。

### 9.4 シリアルダンプ・電力影響の実地確認

- [x] USBケーブルを挿して電源投入(またはリセット)したとき、自動的に履歴ログが全件ダンプされることを確認済み(非タイマー起床=`wake=power_on`のたびに`history: count=... capacity=672`ヘッダ+各エントリが出力されることを確認)。
- [x] 電源を完全に断って(ケーブル抜き差し)からの再起動でも、NVSに書いたエントリが失われずダンプに反映されることを確認済み(90件以上のエントリが電源断をまたいで保持されていた)。
- [x] `mustPublish()==false`(skip)・`true`(接続してpublish)の両方の周期で`historyLogRecordCycle()`が正常に動作し、クラッシュ・ハングが発生しないことを確認済み。
- [ ] 履歴が672件(満杯)近くまで溜まった状態でのダンプ所要時間の実測(§4.1の見積もり約3.8秒との比較) — 満杯到達に約2.3日かかるため本セッションでは未実施。
- [ ] `waitForSerial`中の`'h'`コマンドによるダンプの実機確認 — 未実施(起動時ダンプでの検証を優先したため)。
- [ ] 毎サイクルの追加NVS書き込み(§8.2)が`active_ms`に与える影響の定量計測 — 未実施。参考として、確認済みの`skipped`サイクルは`active_ms=1514〜1561ms`で安定しており、既存の予算に対して問題になる兆候はない。

---

## 10. デフォルト容量に関する決定(確定)

**決定(ユーザー確認済み・実機検証済み)**:
- 記録方針は「毎サイクル無条件記録」、内容は「MQTTペイロードの`raw`と同一の4チャンネル」で確定(チャンネル削減・圧縮は行わない)。
- 保持期間は「1日分以上取れれば問題ない」という条件のもと、`capacity=672`(約2.3日分)で確定する。
- `capacity=672, segments=14`は§9.3の実機`nvs_get_stats()`検証により、満杯時でも約258エントリ(≈8KB)の空きを残すことを確認した。**候補値ではなく最終値として`config.h`に採用済み。**

---

## Critical Files for Implementation

- `firmware/src/main.cpp` — `runCycle()`の`classifyStatus()`直後、`setup()`の起床要因判定ブロック、`waitForSerial()`へのフック追加箇所
- `firmware/include/history_log.h`(新規) — 公開API(§5.2)
- `firmware/src/history_log.cpp`(新規) — NVSリングバッファ実装本体
- `firmware/include/config.h` — `PSS_HISTORY_LOG_*`マクロ追加箇所
- `firmware/include/sync_ledger.h` / `firmware/src/sync_ledger.cpp` — 変更しないが、NVS namespace設計・schemaVersionマイグレーションパターンの参照元
- `firmware/include/classify.h` / `firmware/include/sensor.h` — `ParkingStatus`/`RawSample`定義の参照元(変更なし)
