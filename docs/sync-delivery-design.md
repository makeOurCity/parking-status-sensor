# 送信サイクルと配送状態の設計（Issue #32）

端末が各起床サイクルでセンサー観測をクラウドに届けるための方針。  
一晩通し試験（2026-07-07）の **outbox ラッチ劣化モード**（boot 43 型）を契機に、Outbox FIFO 方式から再設計する。

- 関連 Issue: #32
- 調査記録: [lte-active-investigation.md](lte-active-investigation.md)
- 将来: 変化時のみ送信（#25）、heartbeat

---

## 1. 背景と問題

### 1.1 観測された現象

LiPo + `xiao-s3-aws-lte` の一晩通し試験で、boot 43 以降 `activeMsBeforePublish` が約 128 秒に張り付き、
受信間隔が約 13 分に悪化した。クラウド上は `deliveryConfirmed: true` が続き、送信欠落もなかった。

### 1.2 根本原因（設計）

再現実験より先に、コードと当時のファーム構成の組み合わせで説明できる。

1. **1 サイクル内で接続・outbox 再送・直接 publish が同一の `kCycleMaxActiveMs`（120 秒）を共有**
2. **publish 失敗のたびに `modem.poweroff()` 含むフル再接続**
3. 初回接続後の残予算では再接続が完了せず → outbox enqueue → 次サイクルへ
4. 劣化後は **outbox 再送（成功）+ 直接 publish（失敗）** が毎サイクル反復

タイムアウトの微調整ではなく、**送信プロセスの設計問題**。

> **注記（試験時期の文脈）**: 一晩試験は PR #33 マージ前のファーム（ESP32 側 TLS + NTP 空振り、接続約 68 秒）で実施。
> 現行（モデム TLS + Fix A）では接続コストは約 6 秒（コールドスタート〜10 秒台）に改善しているため、
> 同じ予算枯渇は起きにくいが、**「失敗 → フル再接続 → 2 段 publish」という構造欠陥自体は残っており**、本再設計の対象。

### 1.3 個別タイムアウトが予算を貫通する問題

リトライループの予算チェック（`millis() - cycleStart >= kCycleMaxActiveMs`）はループ先頭でのみ行われ、
個別のブロッキング操作はサイクル予算と独立に走る。1 回の操作がサイクル予算を大きく超過しうる。

操作を「予算で打ち切れるもの／打ち切れないもの」に分けて扱う（§4.1）。

| 打ち切り可否 | 操作 | 現行タイムアウト |
|---|---|---|
| **可**（引数で指定） | `waitForNetwork(timeout)` | `PSS_LTE_NETWORK_TIMEOUT_MS`（LTE=120s） |
| **可**（`timeout_s`） | modem-TLS `CACID` / `CAOPEN`（`modemSslConnectAws`） | `kMqttConnectTimeoutMs`（LTE=60s） |
| **不可**（固定 `waitResponse`） | `gprsConnect`, `+CFUN`, `+CSSLCFG convert`（各 30s）, FS 書き込み | ハードコード |

**方針**: 打ち切り可能な操作は `min(フェーズ残予算, 操作タイムアウト)` を渡す。
打ち切り不可能な操作は、**各操作の固定タイムアウトを短めに設定**し、その操作の**完了後**に予算チェックする
（＝1 操作分は超過を許容するが、次の操作には進まない）。

### 1.4 Outbox のドメイン不適合

現行 Outbox は未送信 JSON を FIFO（最大 3 件）で保持し、次サイクルで古い順に再送する。

| 観点 | 評価 |
|---|---|
| 満空の「最新状態」を届ける | 5 分遅れのスナップショットは価値が低い |
| 時系列の穴埋め | 端末保持に限界があり、全件送信でも次サイクルで上書き可能 |
| 変化時のみ送信（#25） | 古い遷移の再送は誤解を招く。heartbeat で正常性を担保する方が適切 |
| 通信コスト | 劣化時に 1 サイクル 2 回 publish になりうる |

**端末側での時系列復元は行わない。** 最新状態の配送と、失敗・ギャップの記録に集中する。

### 1.5 既知バグ: `deliveryConfirmed` の先行 true

現行の `publishCurrentWithRetry` / `flushOutbox` は、**PUBACK 確認前**のペイロード生成時点で
`deliveryConfirmed: true` を書き込んでいる（`main.cpp:203`）。QoS1 では PUBACK 後に送信済みメッセージを
書き換えられないため、**ブローカーに届く JSON の `deliveryConfirmed` は本質的に送達確認の意味を持てない**。
一晩試験の「全件 `deliveryConfirmed: true`」は送達確認の証拠にならない。→ §2.4 で扱いを変更する。

---

## 2. 設計方針

### 2.1 最優先

> 各プロセス（起床サイクル）のセンサー読み取り結果を、正しくクラウドに届ける。

### 2.2 PoC フェーズ（当面）【確定】

- **全件送信**（毎サイクル publish）を維持し、耐久試験に使う
- 変化時のみ送信のフック（`mustPublish()`）は骨格のみ入れ、フラグは後から有効化
- heartbeat は **PoC では無効**。間隔・永続化フィールドの確定は #25 で行う

### 2.3 リトライ【確定】

| 段階 | 方針 |
|---|---|
| **サイクル内** | 接続・publish をフェーズ別予算で上限付きリトライ（§4.1） |
| **サイクル間** | 失敗時は `prevOutcome` 等を記録し、**次の Deep Sleep 起床（約 5 分後）に必ず再試行**（全件送信では毎サイクル publish するので自動的に満たされる） |
| **禁止** | サイクル内の無限リトライ、**publish リトライ中のフル再接続（`poweroff` 含む）** |

「1 回失敗で終わり」は NG。ただし各サイクルの active 時間は上限で打ち切る。

**poweroff の粒度【確定】**: `modem.poweroff()`（= `disconnectTransport()` の LTE パス）は
**サイクル終了時（スリープ直前）のみ**。publish リトライ中は同一セッションでの再試行を優先し、
セッションが切れていた場合は **MQTT レイヤーの再接続**（GPRS ベアラは維持、モデム電源は落とさない）に限定する。

> **再接続コストの注記**: modem-TLS（`AwsLteSecureClient::connect`）は毎回 `stop()` → `CAOPEN` で
> TLS を張り直すため（`lte_modem_tls.h:31-38`）、「MQTT レイヤーのみ再接続」といっても実コストは
> **TLS 再ハンドシェイク + MQTT connect**（数秒）。ただし**証明書の再アップロード/再 convert は不要**
> （NVS キャッシュ済み `lte_modem_tls.cpp:122-128`）。この数秒を publish フェーズ予算に織り込む（§4.1）。

`PSS_LTE_KEEP_MODEM`（スリープ中もモデム電源維持）は本設計の対象外とし、#31 の実測で要否判断する。

### 2.4 観測可能性【確定】

- 失敗理由・試行回数・前サイクル結果は **MQTT ペイロードの `sync.*` に載せる**（Serial 依存にしない）
- **送達確認の正は「次サイクルの `sync.prevOutcome == confirmed`」と `sync.lastConfirmedBootCount`** とする
- `network.deliveryConfirmed` フィールドは **ブローカー送信 JSON から削除**する（§1.5 の理由により常に false となり形骸化するため）。
  PUBACK 成功/失敗は Serial ログと `sync.prevOutcome` で表現する
- `sync.*` は **診断専用**。Orion エンティティにはマップしない（`data-model.md` に明記、bridge #7 の変換対象外）

---

## 3. SyncLedger（Outbox の後継）

Outbox（JSON FIFO）を廃止し、NVS に **配送台帳** を 1 構造体で保持する。

### 3.1 NVS スキーマ

- namespace: `pss_sync`

| キー | 型 | 初期値 | 意味 |
|---|---|---|---|
| `schemaVersion` | u8 | 1 | スキーマ版数。**存在有無をマイグレーション判定に使う** |
| `lastStatus` | u8 (enum) | unknown | クラウドに届いたと確認した最新 status |
| `lastBoot` | u32 | 0 | 上記観測の bootCount |
| `pendingValid` | u8 (bool) | 0 | 未配送の観測があるか |
| `pendingBoot` | u32 | 0 | 未配送観測の bootCount |
| `pendingStatus` | u8 (enum) | unknown | 未配送観測の status |
| `prevOutcome` | u8 (enum) | none | 前サイクル結果（§4.2） |
| `prevAttempts` | u8 | 0 | 前サイクルの publish 試行回数 |
| `prevMqttError` | i16 | 0 | 前サイクル最後の MQTT lastError |
| `prevActiveMs` | u32 | 0 | 前サイクルの active 時間 |

### 3.2 マイグレーション（初回起動検出）【確定】

「初回」は `bootCount`（RTC 変数、電源断で 0 復帰）では判定できないため、
**`pss_sync` namespace に `schemaVersion` キーが存在するか**で判定する。

```
initSyncLedger():
  if !prefs.isKey("schemaVersion"):     # 未初期化 = SyncLedger 初導入
    旧 namespace "pss_outbox" を全削除（送信は試みない）
    schemaVersion = 1、他フィールドを初期値で書き込む
  else:
    既存 SyncLedger を読み込む
```

SyncLedger 初期化と旧 outbox 削除を **同一処理**にまとめる。
旧 outbox に未送信データが残っていても破棄する（5 分超のスナップショットは価値が低いため許容）。

### 3.3 pending のセマンティクス【確定】

**PoC（全件送信）では pending は診断メタデータ**であり、再送キューではない。

- 送信するペイロードは **常にそのサイクルの最新観測 1 件**
- publish 失敗時は今回観測を pending として記録（`pendingValid=1`）
- 次サイクルは新しい読み取りで publish する（pending の JSON を再送しない）
- 成功時に `pendingValid=0`、`lastStatus` / `lastBoot` を更新
- pending 中に status が変化していた場合も最新を送る。取りこぼした遷移は `sync.*` から読み取れる（時系列復元はしない）

**#25（変化時のみ送信）では** `pendingValid` が `mustPublish()` のトリガーになる（§3.4）。

### 3.4 `mustPublish()`

PoC（全件送信）:

```
mustPublish = true   // 常に送信
```

変化時のみ送信（#25 以降、本 Issue では骨格のみ）:

```
mustPublish =
  (currentStatus != lastConfirmedStatus)   // 状態変化
  OR heartbeatDue                          // 定時（間隔は #25 で確定）
  OR pendingValid                          // 前回未配送
```

`mustPublish == false` のときは **通信スタックを起動せず**（モデム電源オンもしない）、
SyncLedger の `prevOutcome = skipped` を記録してスリープする。

**#50（ブートモード）による例外:** 電源投入（コールドブート、`esp_reset_reason() == ESP_RST_POWERON`）を
検知した場合のみ、`setup()` から `mustPublish()` を一切呼ばない別経路（`runBootMode()`）に入り、
0/1/2/3/4 分の計5回を無条件送信する。Deep Sleep タイマー復帰・ソフトリセット・watchdog リセットでは
発動しない。詳細は [50-boot-mode-design.md](50-boot-mode-design.md)。

---

## 4. サイクルフロー（再設計）

### 4.1 予算とタイムアウト（LTE ビルド）【確定】

実測（[lte-active-investigation.md](lte-active-investigation.md)、boot 51–52）では定常の接続は約 2.5 秒（attach）+
1.7〜6.5 秒（TLS+MQTT）、publish は 1 試行。**定常サイクルは 15 秒以内**に収まる。予算はこれに余裕を持たせつつ、
劣化時でも短時間で打ち切る値にする。

| 項目 | 新値 | 現行 | 根拠 |
|---|---|---|---|
| サイクル全体 `PSS_CYCLE_MAX_ACTIVE_MS` | **75 秒** | 120 秒 | 接続 45 + publish 20 + マージン 10 |
| 接続フェーズ予算（新規 `PSS_CONNECT_PHASE_MS`） | **45 秒** | — | 定常 10 秒。悪条件でも打ち切る |
| 接続 最大試行（LTE `PSS_TRANSPORT_MAX_ATTEMPTS`） | **2** | 3 | フェーズ予算内で 2 回 |
| publish フェーズ予算（新規 `PSS_PUBLISH_PHASE_MS`） | **20 秒** | — | 5 秒 ×3 + 再接続 TLS + 遅延 |
| publish 最大試行 `PSS_PUBLISH_MAX_ATTEMPTS` | **3** | 3 | 据え置き |
| publish 1 回 `PSS_MQTT_PUBLISH_TIMEOUT_MS` | 5 秒 | 5 秒 | 据え置き |
| `waitForNetwork` `PSS_LTE_NETWORK_TIMEOUT_MS` | **45 秒** | 120 秒 | 接続フェーズ予算に整合 |
| MQTT 接続 `PSS_MQTT_CONNECT_TIMEOUT_MS` | **20 秒** | 60 秒 | 定常 TLS 1.7〜6.5 秒。悪条件でも打ち切る |
| 時刻同期 `PSS_TIME_SYNC_TIMEOUT_MS` | 15 秒 | 15 秒 | LTE では実質未使用（§4.3） |

- 数値は `config.h` のマクロで上書き可能。現場の電波状況に応じ `platformio.ini` で調整
- `min(フェーズ残予算, 操作タイムアウト)` を打ち切り可能操作に適用（§1.3）
- Wi-Fi ビルドは現行値ベース。本 Issue の主対象は LTE

#### 初回証明書プロビジョニングの扱い【確定】

初回起動（NVS 未キャッシュ）の証明書アップロードは `convert` 各 30 秒 + FS 書き込みで、**接続フェーズ予算 45 秒を超えうる**
（`lte_modem_tls.cpp:79,91`）。これは **接続フェーズ予算の対象外**（best-effort、打ち切らない別枠）とする。

- 初回サイクル: 証明書アップロード（成功すれば NVS キャッシュ）→ 以降のサイクルはスキップ（数十 ms）
- アップロード失敗時は `connect_failed` として記録し、**次サイクルで再試行**（毎回やり直すが、成功すればキャッシュ）
- 初回サイクルは active が長くなるため、**検証（§5.2）の中央値計算から除外**する

### 4.2 `prevOutcome` の値と期待メトリクス

| 値 | 意味 | `prevAttempts` | `publishMs` |
|---|---|---|---|
| `confirmed` | publish 成功（PUBACK 受領） | 1〜3 | >0 |
| `connect_failed` | 接続フェーズで失敗 | 0 | 0 |
| `publish_failed` | 接続成功・publish 全試行失敗 | =最大試行 | 0 or >0 |
| `budget_exhausted` | サイクル予算切れで打ち切り | 0〜3 | 状況依存 |
| `sensor_error` | センサー初期化/読み取り失敗（通信なし） | 0 | 0 |
| `skipped` | `mustPublish == false`（#25 用） | 0 | 0 |

> `publishMs` は現行ログで 0 のことがある（計測タイミングの問題）。実装時に「publish 呼び出し直前〜PUBACK/タイムアウト」で計測するよう修正する。

### 4.3 メインフローと失敗分岐

```
起床
  → initSyncLedger（未初期化なら旧 pss_outbox 削除 + 初期化）
  → センサー読み取り
      失敗 → ledger: prevOutcome=sensor_error → スリープ
  → mustPublish?（PoC では常に true）
      false → ledger: prevOutcome=skipped → スリープ（通信スタック起動しない）
  → 接続（予算 45 秒、最大 2 試行。初回証明書は別枠 best-effort）
      失敗 → ledger: pending=今回観測, prevOutcome=connect_failed → スリープ
  → ペイロード生成（deliveryConfirmed フィールドなし、sync.* 付き）
  → publish（予算 20 秒、最大 3 試行）
      リトライ: 同一セッション → 切れていれば MQTT レイヤー再接続（TLS 再ハンドシェイク、poweroff しない）
      成功 → ledger: lastStatus/lastBoot 更新, pending クリア, prevOutcome=confirmed
      失敗 → ledger: pending=今回観測, prevOutcome=publish_failed
  → 切断（ここで初めて poweroff）→ Deep Sleep（300 秒）
```

サイクル予算（75 秒）超過はどのフェーズでも `budget_exhausted` として打ち切り、失敗時と同様に ledger を更新してスリープする。

> **時刻同期の位置**: LTE 経路のモデム時刻同期は接続処理内の `ensureLteClock`（NITZ / `+CNTP`）で完了する
> （`transport.cpp` の `connectLte` 内）。`syncClock()` は Wi-Fi 未接続時に即 false を返すため
> （`transport.cpp:616-618`）、**LTE ビルドでは `syncClock()` 呼び出しは実質 no-op**。新フローでは
> LTE の時刻同期を接続処理に委ね、`syncClock()` は Wi-Fi パス専用と位置づける。

**廃止するもの**

- `flushOutbox` → `publishCurrent` の 2 段 publish（publish は 1 サイクル 1 観測のみ）
- 共有 120 秒予算での接続 + 再送 + 直接 publish
- publish 失敗ごとの `disconnectTransport()` + `modem.poweroff()` + フル再接続
- `outbox.h` / `outbox.cpp`（FIFO 実装）
- ペイロードの `network.deliveryConfirmed` フィールド

### 4.4 MQTT ペイロード追加

```json
"sync": {
  "lastConfirmedStatus": "available",
  "lastConfirmedBootCount": 41,
  "pending": false,
  "prevOutcome": "confirmed",
  "prevAttempts": 1,
  "prevMqttError": 0,
  "prevActiveMs": 6200
}
```

- `network.deliveryConfirmed` は削除（§2.4）。送達確認は `sync.prevOutcome` / `sync.lastConfirmedBootCount` で判断
- `sync.*` は診断専用。`data-model.md` に「Orion エンティティにマップしない」と追記する

---

## 5. 検証（完了条件の合格基準）

### 5.1 人為的失敗注入【確定】

debug ビルド（`PSS_DISABLE_DEEP_SLEEP=1`）に失敗注入フック（ビルドフラグ、例: `PSS_FAULT_INJECT`）を入れ、
**publish 失敗**と**接続失敗**の両系統を検証する。

**publish 失敗系**（不正トピック publish / publish スキップ）

- [ ] `prevOutcome=publish_failed` が次サイクルのペイロードに載る
- [ ] 失敗サイクルでも active が **75 秒上限以内**（張り付かない）
- [ ] 注入解除後、次サイクルで `confirmed` に回復し `pending=false` に戻る
- [ ] publish 試行はサイクルあたり最大 3 回、**フル再接続（poweroff）が発生しない**
      （観測: Serial に `poweroff` ログを出し、失敗サイクル中に出ないことを確認）

**接続失敗系**（不正 APN / 接続予算を極小化）

- [ ] `prevOutcome=connect_failed` が次サイクルのペイロードに載る
- [ ] 接続フェーズ 45 秒で打ち切られ、publish に進まない
- [ ] active が 75 秒上限以内

### 5.2 耐久試験（一晩以上、`xiao-s3-aws-lte` + LiPo）

- [ ] `activeMsBeforePublish` の中央値が 30 秒未満（定常は 6 秒台を期待。**初回証明書サイクルは除外**）
- [ ] `kCycleMaxActiveMs`（75 秒）への張り付きが連続しない（boot 43 型の再発なし）
- [ ] 受信間隔が約 5 分強で安定（sleep 300 秒 + active）
- [ ] `sync.prevOutcome` の分布が確認でき、失敗があっても翌サイクルで回復している

### 5.3 実装チェック

- [ ] Outbox 廃止（`outbox.*` 削除、旧 NVS namespace 削除処理あり）
- [ ] SyncLedger 導入（`pss_sync`、`schemaVersion=1`、初回検出でマイグレーション）
- [ ] 1 サイクル 1 publish、フェーズ別予算（§4.1）と新マクロ定義
- [ ] `platformio.ini`（LTE 環境）の予算値を新値に更新
- [ ] `network.deliveryConfirmed` 削除、送達確認は `sync.prevOutcome`
- [ ] `mustPublish()` 骨格（PoC では常に true、false 時は通信スタック非起動）
- [ ] `connect_failed` / `budget_exhausted` / `sensor_error` の outcome 記録
- [ ] `data-model.md` に `sync.*` の扱いを追記

---

## 6. 関連

| Issue / PR | 内容 |
|---|---|
| #25 | 変化時のみ送信（`mustPublish` 本番有効化、heartbeat 間隔の確定） |
| #31 | 消費電力実測（パターン E は本 Issue 後に要否判断。`PSS_LTE_KEEP_MODEM` の要否も #31 で判断） |
| #30, PR #33 | Fix A/C、モデム TLS（済） |
| #7 | bridge 本実装（`sync.*` は変換対象外） |

## ブランチ

`fix/32-sync-delivery`

---

## 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-07-07 | 初版（Outbox 廃止・SyncLedger・送信サイクル再設計） |
| 2026-07-07 | v2: レビュー反映。予算表・失敗分岐・pending セマンティクス・NVS スキーマ・poweroff 粒度・検証基準を確定 |
| 2026-07-07 | v3: 二次レビュー反映。予算数値をコード実測とすり合わせ（サイクル 75s / 接続 45s / publish 20s、個別 TO 短縮、新マクロ）、初回証明書を予算外に、`deliveryConfirmed` 削除、初回検出を `schemaVersion` 基準に、再接続コスト・syncClock 位置・接続失敗検証を明記 |
