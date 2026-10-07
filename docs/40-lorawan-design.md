# LoRaWAN（Grove Wio-E5）設計メモ（#40）

> **作業記録・WIP**: #40 の PR ごとに更新する。現時点は PR3（ファームの通常サイクルへの統合）まで。消費電力の評価（PR4）はまだ。

## 1. 経路

```
Wio-E5 ──LoRaWAN(JP920/AS923-1)──▶ SenseCAP M2 (M2-AS923, Basics Station)
  ──▶ AWS IoT Core for LoRaWAN ──Destination "Saga_IoT_Core"──▶ MQTT lorawan/parking-status/uplink
```

| 項目 | 値 |
|---|---|
| ゲートウェイ | SenseCAP M2（`M2-AS923`、Gateway EUI `2CF7F1138030000C`）。AWS 上の名前は `Saga Gateway`（RfRegion AS923-1） |
| Device Profile | `AS923-1-A-OTAA`（LoRaWAN 1.0.3、RP002-1.0.1、Class A、RX2 は DR2 / 923.2MHz、MaxEirp 5） |
| Wireless Device | 名前は deviceId（例: `xiao-e83dc1fc1aec`）、OTAA v1.0.x |
| Destination | `Saga_IoT_Core` → MQTT トピック `lorawan/parking-status/uplink`（Wi-Fi / LTE-M の `parking-status/<deviceId>/telemetry` とは別の名前空間） |

クラウド側のうち、IoT ルールと bridge の LoRaWAN デコーダ（iOS ログビューアへの表示）は #83、経路の説明は [iot-core.md](iot-core.md) にある。Orion 連携は #7（実装済み）。

**アカウント（#98）**: 2026-10-07 に、個人の AWS アカウントから**組織の AWS アカウント**に切り替えた。クラウド側のリソースは `infra/setup-lorawan.sh`（`role` / `profiles` / `gateway` / `device`）で作る。**ゲートウェイ EUI と DevEui は、他のアカウントに登録されていると登録できない**ため、アカウントを移すときは、旧アカウントの Wireless Device とゲートウェイを削除してから新アカウントに作る（並行稼働できず、その間はアップリンクが途切れる）。M2 の設定は、ローカルコンソールの LoRa > LoRa Network で、Mode: Basics Station、Server: CUPS（443）、Authentication: TLS Server and Client Authentication、URI と CA（trust）・certificate・key を新アカウントの値に差し替える。端末（Wio-E5）は MQTT を話さず鍵も変わらないので**再書き込みは不要**で、電源を入れ直して Join し直す（古いセッションが残っていると再 Join されないため）。

## 2. Wio-E5 の設定

工場出荷時は **EU868 / LWABP** になっている。**日本ではこのまま送信しない**（868MHz 帯は使えない）。

プロビジョニング（`wioE5ProvisionOtaa()`）で次のように設定する。

**設定コマンドは Join セッションを消す**（実機で確認: Join 済みでもプロビジョニング後の `AT+JOIN` は `Network joined` になり、Join し直す）。そのため、毎サイクルではなく **Deep Sleep のタイマー以外で起動した後の最初の接続で1回だけ**実行する（§6）。

| コマンド | 理由 |
|---|---|
| `AT+DR=JP920` | AS923 互換の日本向けプラン（AT Command Specification §1.1 脚注）。既定チャネル 923.2 / 923.4MHz は AS923-1 と同じ |
| `AT+MODE=LWOTAA` | OTAA で Join する |
| `AT+CLASS=A` / `AT+ADR=ON` | Device Profile に合わせる |
| `AT+RETRY=1` | 再送しない（2 未満なら1回だけ送る。このファームでは `0` は ERROR になる）。再送はファーム側のリトライだけにする |
| `AT+PORT=1` | コアペイロードの fPort |
| `AT+ID=AppEui,"…"` / `AT+KEY=APPKEY,"…"` | `secrets.h` の `PSS_LORAWAN_APP_EUI` / `PSS_LORAWAN_APP_KEY` が空でなければ書き込む。ログでは `AT+KEY` / `+KEY:` を伏せ字にする |

設定はモジュールの不揮発メモリに保存される。

### 実機で確認した値（ファーム 4.0.11）

| 項目 | 値 |
|---|---|
| `AT+LW=VER` | `V103`（Device Profile の 1.0.3 と一致） |
| `AT+LW=THLD`（LBT しきい値） | -85 dBm（工場出荷値） |
| `AT+LW=TPS`（UplinkDwellTime, DownlinkDwellTime, MaxEIRP） | `OFF, OFF, 3` |
| Join 直後の DR | DR2（SF10/125kHz） |

LBT（送信前のキャリアセンス）は Wio-E5 に内蔵されていて、しきい値は `AT+LW=THLD` で変えられる。JP920 プランで具体的にどう動くか（キャリアセンスの時間など）は、仕様書に記載がない。

## 3. コアペイロード（fPort 1、ver 1、固定 18 バイト）

JSON（数百バイト）は LoRaWAN では送れない。そのため、必要な項目だけを固定長のバイナリにして送る。

### サイズを決めた根拠（dwell time）

AS923 では、1回の送信を 400ms 以内に抑える UplinkDwellTime という設定がある。

- **有効な場合**: DR2（SF10）の上限は 11 バイト（仕様書 Table 3-20）。13 バイトで約 412ms、18 バイトで約 452ms になり、400ms を超える
- **無効な場合**: DR2 の上限は 51 バイト

この設定は、ネットワークが TxParamSetupReq で指定する。実機で確認した結果は次のとおり。

| タイミング | `AT+LW=TPS`（Uplink dwell, Downlink dwell, MaxEIRP） |
|---|---|
| プロビジョニング直後 | `OFF, OFF, 3` |
| Join と送信3回の後 | `OFF, OFF, 0` |

AWS IoT Core for LoRaWAN（AS923-1）は、MaxEIRP を書き換えたうえで **dwell time を OFF と明示的に指定**してくる。そのため、threshold と、iOS ログビューアが使う `power.bootCount` / `resetReason` / `wakeCause` を載せた 18 バイトにした（`static_assert` で DR2 の 51 バイト以内を担保）。

dwell time が有効なネットワークに移した場合、DR2 での送信は Wio-E5 が `Length error` で拒否する。ファームはこれをエラー（-105）として扱う。

**法令（ARIB STD-T108）について、未確認**:

- 日本の 920MHz 帯では、キャリアセンスの時間によって1回の送信時間の上限が変わる（5ms 以上なら 4 秒、128µs なら 400ms と理解している）
- Wio-E5 の JP920 のキャリアセンスの時間は、仕様書に記載がない
- DR2 で 400ms を超えるのは、11 バイトを超えたときだけではない。11 バイトでも、MAC コマンドの応答（FOpts）が相乗りすると超える。実測で `FOptLen: 2` のときに約 412ms になっていた
- 技適はモジュールの送信制御も含めて認証されているので、モジュールが許す範囲は適合していると考えられるが、Seeed に確認する
- ゲートウェイの近くでは ADR が DR5（SF7）に上げるため、18 バイトでも送信時間は約 72ms

| byte | bit | 内容 |
|---|---|---|
| 0 | 7:6 | version（=1） |
| 0 | 5:4 | status（0 full / 1 open / 2 unknown。`ParkingStatus` の順。#99 で `available` から改名したが、無線上の値は変わらない） |
| 0 | 3:2 | 送信理由（0 状態変化 / 1 heartbeat / 2 pending の再送 / 3 ブートモード） |
| 0 | 1 | coldBoot（`esp_reset_reason() == ESP_RST_POWERON`） |
| 0 | 0 | 予備（0） |
| 1 | 7:5 | 前サイクルの結果（`CycleOutcome` 0–6） |
| 1 | 4:3 | 前サイクルの試行回数（3 で頭打ち） |
| 1 | 2:0 | ブートモードの何回目か（0 は通常サイクル、7 で頭打ち） |
| 2–9 | | raw R / G / B / W（VEML6040、各 uint16 ビッグエンディアン） |
| 10 | | 前サイクルの起床時間（250ms 単位、255 = 63.75s で頭打ち） |
| 11–12 | | 判定閾値 threshold（uint16 ビッグエンディアン、0–65535 に収める）。ポテンショメーター有効時は算出値（30–15000） |
| 13–16 | | bootCount（uint32 ビッグエンディアン。RTC の起床回数で、LTE-M 版 JSON の `power.bootCount` と同じ。電源投入で 1 から） |
| 17 | 7:4 | wakeCause（0 other / 1 timer / 2 power_on。`wakeCauseToString` と同じ文字列） |
| 17 | 3:0 | resetReason（0 other / 1 power_on / 2 brownout / 3 deep_sleep / 4 software / 5 panic / 6 task_wdt / 7 int_wdt / 8 wdt。`resetReasonToString` と同じ文字列） |

デコーダは bootCount / resetReason / wakeCause を、LTE-M 版 JSON と同じ `power` オブジェクトの形（`{"bootCount", "resetReason", "wakeCause"}`）で出す。クラウド側では、これを LTE-M 版と同じ形の JSON に揃えやすくするため（iOS ログビューアはブート回数とリセット検知にこれを使う）。

載せないもの:

- `deviceId`: Wireless Device 名で分かる
- `timestamp`: Destination のメッセージの受信時刻を使う
- ポテンショメーターの生の ADC 値（`potRaw`）と診断用の詳細: シリアルのログで確認する

連番は LoRaWAN の FCnt で取れる。

- エンコーダ: `firmware/src/lorawan_payload.cpp`
- デコーダ: `tools/lorawan/decode.py`
- テストベクタ: `tools/lorawan/test_vectors.json`。hex はエンコーダの出力で、1件は手計算と照合済み

## 4. Join と送信の動き（実機での実測）

| 操作 | 応答 | 所要時間 |
|---|---|---|
| `AT+JOIN`（未 Join） | `+JOIN: Network joined` → `NetID` / `DevAddr` → `Done` | 約 6.0s |
| `AT+JOIN`（Join 済み） | `+JOIN: Joined already`（無線を使わない） | 約 85ms |
| `AT+CMSGHEX`（confirmed、11B（18B 化の前）、DR2） | `Wait ACK` → `ACK Received` → `RXWIN1, RSSI -24, SNR 7.0` → `Done` | 約 1.9s |
| `AT+LOWPOWER` → 任意の入力 | `+LOWPOWER: SLEEP` → `+LOWPOWER: WAKEUP`（最初の `AT` は捨てられる） | — |

- Join 済みなら `AT+JOIN` は無線を使わずに返る。そのため Join 済みかを RTC に覚えず、**送信するサイクルで毎回 `AT+JOIN` を送る**
- `+CMSGHEX: FPENDING` は、ネットワーク側に未送のダウンリンク（MAC コマンド等）があることを示す。次のアップリンクの RX ウィンドウで届く

## 5. Destination に届くメッセージ

```json
{
  "WirelessDeviceId": "73742d6b-…",
  "PayloadData": "YAAAAAAAAAAAAAA=",
  "WirelessMetadata": {
    "LoRaWAN": {
      "DevEui": "2cf7f1207380e5f9", "FPort": 1, "FCnt": 1, "DataRate": "2",
      "Frequency": "922600000", "SpreadingFactor": 10, "MType": "ConfirmedDataUp",
      "Gateways": [{"GatewayEui": "2cf7f1138030000c", "Rssi": -33, "Snr": 13.5}],
      "Timestamp": "2026-10-01T06:58:33Z"
    }
  }
}
```

- `PayloadData` は base64 で、`tools/lorawan/decode.py --message` でデコードできる
- Frequency 922.6MHz は既定の2チャネル以外で、Join のときにネットワークから渡されたチャネルとみられる

## 6. ファームへの統合（PR3）

env は `xiao-s3-lorawan`（本番）、`xiao-s3-lorawan-pot`（+ ポテンショメーター）、`xiao-s3-lorawan-debug`（Deep Sleep なし）。ラッチングリレー（#46）は使わない（Wio-E5 は 3.3V から常時給電し `AT+LOWPOWER` で寝かせる。要否は PR4 の消費電力の結果で判断する）。閾値はペイロードに載せてクラウドに送る（§3）。ポテンショメーターの生の値は、ブートモード中のシリアル（サンプル行と JSON）で確認する。LoRaWAN 版は LoRaWAN だけを使う（README §4.3 の LoRaWAN > LTE > Wi-Fi のフォールバックは将来）。

### サイクル

```
起床 → センサー読み取り・判定 → 履歴ログ → 送信するか判定（mustPublish、LTE-M 版と同じ）
  ├ 送信しない → Wio-E5 に AT+LOWPOWER → Deep Sleep
  └ 送信する → [未プロビジョニングなら設定] → AT+JOIN → AT+CMSGHEX（confirmed）
              → Wio-E5 に AT+LOWPOWER → Deep Sleep
```

- **プロビジョニング**
  - RTC のフラグ `loRaWanProvisioned` を持つ。Deep Sleep のタイマー以外で起動したとき（電源投入、USB からのリセット、watchdog など）に戻す
  - 戻した後の最初の接続で、Join の前に実行する。成功するまで Join も送信もしない（工場出荷時の EU868 のまま電波を出さないため）
  - 計画では `ESP_RST_POWERON` 時だけにする予定だったが、USB からの書き込み直後なども対象にするためこの形にした
- **Join**: 毎回 `AT+JOIN` を送る（Join 済みなら 85ms）
- **送信**
  - `mustPublish()` の判定（変化時、pending の再送、heartbeat）は変えていない
  - 送信理由は `sendReasonFor()` で同じ順に判定して、ペイロードに載せる
  - JSON は今までどおりシリアルログに出す（`network.transport = "lorawan"`、`loraAlreadyJoined`）
- **送信履歴（sync ledger）**
  - ACK 受信を confirmed として扱う
  - `prevMqttError` には、`-100 - WioE5Result` のコードを入れる

| コード | 意味 |
|---|---|
| -101 | ACK なし |
| -102 | 未 Join |
| -103 | Join 失敗 |
| -104 | busy、またはチャネルが空いていない |
| -105 | ERROR（プロビジョニングの失敗を含む） |
| -106 | タイムアウト |

- **ブートモード（#50）**
  - LoRaWAN でもそのまま使う
  - 2回目以降のスロットでは、`activeMqttState()` が Join 済みなら 0 を返すので、Join をし直さずに送る
- **Wio-E5 を寝かせる**
  - 毎サイクル `disconnectTransport()` で `AT+LOWPOWER` を送る。送信しなかったサイクルも含む
  - あわせて `esp_deep_sleep_disable_rom_logging()` で、Deep Sleep 復帰時の ROM ログ（GPIO43 → Wio-E5 RX）を止める
  - 電源投入時の ROM ログは止まらない

### 時間予算（`xiao-s3-lorawan`）

| フラグ | 値 | 根拠 |
|---|---|---|
| `PSS_LORAWAN_JOIN_TIMEOUT_MS` | 12000 | Join の実測 約6s |
| `PSS_LORAWAN_UPLINK_TIMEOUT_MS` | 8000 | ACK 付き送信の実測 約2s。ACK なしでも RX2 まで約3s |
| `PSS_TRANSPORT_MAX_ATTEMPTS` / `PSS_CONNECT_PHASE_MS` | 3 / 30000 | Join 12s × 3 回 |
| `PSS_PUBLISH_MAX_ATTEMPTS` / `PSS_PUBLISH_PHASE_MS` | 3 / 25000 | 送信 8s × 3 回 |
| `PSS_CYCLE_MAX_ACTIVE_MS` | 60000 | watchdog は 80s（+20s） |

最悪の場合でも、サイクル 60s に1コマンド分（最大 12s）を足した値は watchdog の 80s に収まる。

### 実機での確認（`xiao-s3-lorawan-debug`）

| サイクル | 結果 |
|---|---|
| 初回の送信 | プロビジョニング → `Network joined`（6.0s）→ ACK 付き送信（1.9s）。サイクル全体 11.2s |
| 次の heartbeat | `Joined already`（85ms）→ ACK 付き送信（2.0s）。サイクル全体 4.1s |
| 送信しないサイクル | 毎回 `AT+LOWPOWER` → `+LOWPOWER: SLEEP` |
| ブートモード（USB 挿し直しで電源投入） | 1分間隔で5回届いた。1回目は約 10.8s（プロビジョニングと Join し直しを含む）。2回目以降は Join し直さず（FCnt が連続）、2.75〜3.5s。全スロットで送信理由 `boot_mode`、coldBoot true、スロット番号 2〜5 を確認（1回目は購読前で、受信統計だけで確認） |
| ADR | Join 直後は DR2、その後 DR5（SF7）に上がった |

AWS の Destination に届いたメッセージをデコードすると、status・送信理由（heartbeat）・前回の結果（skipped）・raw の値がファームのログと一致した。

## 7. 未確認・今後の課題

- PR4: U200 で待機電流（送信しないサイクルの後 / 送信サイクルの後）、Join 1回、送信1回を計測する。ROM ログの抑止と `AT+LOWPOWER` の効果もここで見る
- 本番 env（Deep Sleep あり）での長時間の連続運用
- `xiao-s3-lorawan-pot` の実機確認（ポテンショメーターを配線した機体）
- Deep Sleep 中の GPIO43（TX）の状態で Wio-E5 が起きないか（必要なら `gpio_hold_en`）
- Device Profile の MaxEirp が 5 と小さい。AWS は TxParamSetupReq で MaxEIRP を index 0（8 dBm）に下げてくる（JP920 の初期値は index 3 = 13 dBm）。ベンチでは問題ないが、現場で距離が出ないときはまずここを見直す
- Seeed に、Wio-E5 の JP920 での LBT（キャリアセンスの時間）と送信時間の上限を確認する（§3）
