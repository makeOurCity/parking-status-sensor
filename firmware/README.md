# ファームウェア

XIAO ESP32S3 向けファームウェア（PlatformIO）。Grove - I2C Color Sensor V3.0（VEML6040）で満空灯の色を読み取り、満／空／不明を判定して AWS IoT Core へ MQTT 送信する。

- ロードマップ: [Issue #22](https://github.com/makeOurCity/parking-status-sensor/issues/22)
- 配線の正: [docs/wiring.md](../docs/wiring.md)（[devkit-bench.md](devkit-bench.md) は DevKit 検証時のアーカイブ）
- 電源・消費電力: [README.md](../README.md) §6、[docs/hardware.md](../docs/hardware.md)

## 構成

| 項目 | 内容 |
|---|---|
| ボード | Seeed XIAO ESP32S3 + Grove Shield for XIAO |
| センサー | Grove - I2C Color Sensor V3.0（VEML6040、I2C `0x10`、D4=SDA / D5=SCL） |
| LTE-M 版 | M5Stack SIM7080G CAT-M Unit（Grove UART、D6=TX / D7=RX）+ Grove 2-Coil Latching Relay（D0）で LTE-M の電源を送信時だけ入れる（#46） |
| LoRaWAN 版（評価中・#40） | Grove Wio-E5（Grove UART、D6=TX / D7=RX、9600bps）。LTE-M とは排他 |
| 閾値調整 | Grove - Rotary Angle Sensor（D1、#60） |
| 電源 | LiPo → Shield の BAT パッド（JST）。ESP32-S3 と Grove の各ポートは Shield の 3.3V を共有する |

ピン定義は `include/board_xiao.h`。

### ソース

| ファイル | 責務 | Issue |
|---|---|---|
| `main.cpp` | 起床〜判定〜送信〜Deep Sleep のサイクル、ブートモード | #6, #50 |
| `sensor.cpp` | VEML6040 の初期化・R/G/B/W 読み取り | #5 |
| `classify.cpp` | R−G 差による満／空／不明の判定 | #6 |
| `transport.cpp` | Wi-Fi / LTE-M / LoRaWAN の接続・送信・LTE-M の電源断 | #6, #76, #40 |
| `wio_e5.cpp` | Grove Wio-E5 の AT コマンド送受信・プロビジョニング・Join・confirmed 送信・疎通確認 | #40 |
| `lorawan_payload.cpp` | LoRaWAN の 18 バイトのコアペイロードのエンコード | #40 |
| `lte_modem_tls.cpp` | SIM7080G 内蔵 TLS 用の証明書の投入 | #30 |
| `sync_ledger.cpp` | 送信確認の記録（NVS）。送信するかどうかの判定の元 | #32 |
| `history_log.cpp` | 毎サイクルの判定結果の履歴（NVS） | #47 |
| `relay.cpp` | ラッチングリレーの SET / RESET | #46 |
| `potentiometer.cpp` | ポテンショメーターによる判定閾値の調整（NVS に保存） | #60 |
| `device_id.cpp` | デバイス ID（`PSS_DEVICE_ID` が空なら MAC から `xiao-xxxxxxxxxxxx`） | #14 |

## 動作

### 通常のサイクル

```
起床 → センサー読み取り・判定 → 履歴ログに記録 → 送信するか判定
  ├ 送信しない → Deep Sleep
  └ 送信する → リレー ON → LTE-M 接続 → MQTT 送信（QoS1）→ 切断（AT+CPOWD=1）→ リレー OFF → Deep Sleep
```

- 起床間隔は `PSS_SLEEP_SECONDS`（300 秒）。送信した場合、実際の間隔はこれに起床していた時間（約 17 秒）が加わる
- LTE-M 版（`PSS_CHANGE_ONLY_SEND=1`）は、**状態が変わったとき、前回の送信が確認できなかったとき、12 回続けて送信しなかったとき**（`PSS_HEARTBEAT_CYCLES=12`、約 66 分ごとの定期送信）だけ送信する。判定の元は NVS の sync ledger（[docs/sync-delivery-design.md](../docs/sync-delivery-design.md)）
- 接続は `PSS_CONNECT_PHASE_MS`（45 秒）を目安に打ち切る。リレー／ロードスイッチの機体では、モデムが AT に一度も応答しなければ約 30 秒で諦めて Deep Sleep する（#87）
- 1 サイクルが上限（`PSS_CYCLE_MAX_ACTIVE_MS`）を超えたらウォッチドッグで再起動する（#41）。`task_wdt` で起動した最初のサイクルは送信せず、`budget_exhausted` を記録して Deep Sleep する（#87）
- 起動時は、理由を問わず最初にリレーを RESET（LTE-M OFF）する

### ブートモード（#50）

電源投入時（`resetReason=power_on`）だけ、1 分間隔で 5 回、無条件に送信する（約 4 分）。ポテンショメーターが有効な env では、この間に読んだ閾値を NVS に保存する（#60）。Deep Sleep からの起床やブラウンアウトからの再起動では動かない。

### テレメトリの `power.resetReason`

| 値 | 意味 |
|---|---|
| `deep_sleep` | 通常の起床 |
| `power_on` | 電池の抜き差しなど、電源投入 |
| `brownout` | ESP32-S3 の電源電圧がブラウンアウト検出のしきい値を下回った（ハードウェアが検知したときだけ記録される） |
| `task_wdt` / `int_wdt` / `wdt` / `panic` / `software` / `other` | ウォッチドッグ、例外、ソフトウェアリセットなど |

**`brownout`（#74）:** 電池の電圧が下がると、LTE-M の送信時に起きる（ESP32-S3 と LTE-M が Shield の 3.3V を共有しているため）。1 回だけなら実害はほぼない（sync ledger で判定し直し、直後に送信する）。**1 回目のブラウンアウトを「すぐ充電」の合図として扱う**。詳細: [docs/74-brownout-conclusions.md](../docs/74-brownout-conclusions.md)

### 消費電力（LTE-M 版、#76 修正後の実測）

| 項目 | 実測値 |
|---|---|
| Deep Sleep 中 | 0.43 mA |
| 送信する起床 1 回 | 16.8 秒・0.446 mAh |
| 送信しない起床 1 回 | 4.8 秒・0.0475 mAh |

稼働日数の目安は [README.md](../README.md) §6.2。

## ビルド・書き込み

端末ごとの Wi-Fi / MQTT / LTE-M 設定は `include/secrets.example.h` を `include/secrets.h` にコピーして編集する。`secrets.h` は git 管理しない。

### env

| env | 用途 |
|---|---|
| **`xiao-s3-aws-lte-relay-pot`** | **LTE-M 版の本番機**（リレー・状態変化時のみ送信・ポテンショメーター） |
| `xiao-s3-aws-lte-relay` | LTE-M 版（ポテンショメーターなし） |
| `xiao-s3-aws-lte-relay-debug` | 上の Deep Sleep なし版（USB シリアルでログを見る） |
| `xiao-s3-aws-lte` / `xiao-s3-aws-lte-debug` | LTE-M・リレーなし（毎サイクル送信） |
| `xiao-s3-aws` / `xiao-s3-aws-debug` | Wi-Fi + AWS IoT Core（TLS） |
| `xiao-s3` / `xiao-s3-debug` | Wi-Fi + ローカル MQTT（Mosquitto） |
| `xiao-s3-lorawan` | LoRaWAN 版（Grove Wio-E5、状態変化時のみ送信、#40） |
| `xiao-s3-lorawan-pot` | LoRaWAN 版 + ポテンショメーター（#60） |
| `xiao-s3-lorawan-debug` | LoRaWAN 版の Deep Sleep なし版 |
| `xiao-s3-lte-test` | LTE-M モジュール単体の接続確認（センサー・MQTT なし） |
| `xiao-s3-lte-poweroff-test` | LTE-M の電源断・復帰の検証（#25） |
| `xiao-s3-lorawan-test` | Grove Wio-E5 単体の AT 疎通確認・Join・1パケット送信（手動コマンド、Deep Sleep なし、#40） |

リレーやポテンショメーターを配線していない機体に、それらが有効な env を書き込まないこと。

```bash
cd firmware
pio run -e xiao-s3-aws-lte-relay-pot -t upload
pio device monitor -e xiao-s3-aws-lte-relay-pot
```

Deep Sleep に入ると XIAO の USB シリアルは切れる。書き込めないときは、BOOT を押したまま RESET を押して書き込みモードにし、書き込み後に RESET を押す。

### AWS IoT Core

証明書を `firmware/certs/`（`AmazonRootCA1.pem`、`device.pem.crt`、`private.pem.key`）に置き、`secrets.h` を AWS IoT Core 向けにする。

```cpp
#define PSS_MQTT_HOST "xxxxxxxxxxxxxx-ats.iot.ap-northeast-1.amazonaws.com"
#define PSS_MQTT_PORT 8883
#define PSS_MQTT_USE_TLS 1
#define PSS_MQTT_BASIC_INGEST_RULE "parking_status_telemetry"
#define PSS_MQTT_TOPIC ""
```

LTE-M 版は Wi-Fi を使わない。

```cpp
#define PSS_WIFI_SSID ""
#define PSS_WIFI_PASSWORD ""
#define PSS_LTE_ENABLED 1
#define PSS_LTE_ONLY 1
```

- TLS は **SIM7080G 内蔵 TLS**（mTLS）。証明書は初回にモデムの FS へ投入し、以降は NVS のフラグでスキップする（`PSS_LTE_FORCE_CERT_UPLOAD=1` で再投入）
- 時刻はモデムの `AT+CCLK`（NITZ）、取れなければ `+CNTP` で合わせる（#30）
- APN は SORACOM（`soracom.io` / `sora` / `sora`）。SIM の状態は [tools/soracom](../tools/soracom/README.md) で確認できる

### LTE-M の単体確認

```bash
pio run -e xiao-s3-lte-test -t upload
pio device monitor -e xiao-s3-lte-test
```

`RESULT: PASS` なら UART・SIM・電波・APN まで通っている。

- `FAIL: no AT response` … Grove UART ケーブル、モジュール電源、TX/RX
- `FAIL: not registered` … SIM、アンテナ、電波
- `FAIL: GPRS attach failed` … APN

### LoRaWAN 版（#40）

```bash
pio run -e xiao-s3-lorawan -t upload
```

- `secrets.h` に `PSS_LORAWAN_APP_EUI` / `PSS_LORAWAN_APP_KEY` を書く（AWS IoT Core for LoRaWAN の Wireless Device の値。名前は deviceId に揃える）。LTE-M 版の `secrets.h` を流用する場合は、`PSS_LTE_ENABLED` を外す（LoRaWAN env と排他で、ビルドエラーになる）
- 送信するかの判定（状態変化時、pending の再送、heartbeat）とブートモードは LTE-M 版と同じ。送るのは JSON ではなく 18 バイトのコアペイロード（status、RGBW、threshold、bootCount、resetReason など。`lorawan/parking-status/uplink` に届く）
- Deep Sleep のタイマー以外で起動した後の最初の接続で、Wio-E5 を JP920 / OTAA に設定してから Join する。Join 済みなら毎回の `AT+JOIN` はすぐ返る
- threshold と RGBW はペイロードでクラウドにも届く。ポテンショメーターの生の値（`potRaw`）はシリアルのサンプル行（`boot-mode slot=… sample r=… g=… b=… w=… status=… threshold=… potRaw=…`）と JSON ログで確認する。現場では、PC につないだ状態で電源を入れ、ブートモード中のシリアルを記録する（モニタを先に起動しておく）
- 詳細（ペイロード、時間予算、エラーコード）は [docs/40-lorawan-design.md](../docs/40-lorawan-design.md)

### LoRaWAN（Wio-E5）の単体確認（#40）

```bash
pio run -e xiao-s3-lorawan-test -t upload
pio device monitor -e xiao-s3-lorawan-test --echo
```

起動すると AT 応答・`AT+VER`・DevEUI・現在の設定（MODE / DR / ADR / CLASS / RETRY / PORT）を読み、`AT+LOWPOWER` から復帰できるかを試す。AT 応答・VER・DevEUI・スリープと復帰がすべて OK なら `RESULT: PASS`。

- `FAIL no AT response` … Wio-E5 の接続（ケーブルが抜けていると文字化けが出ることがある）、TX/RX、ボーレート（9600）

probe の後は USB シリアルと Wio-E5 の素通しになり、AT コマンドを手で打てる。`~` に続けて1文字送ると、テスト用のコマンドを実行する。

| コマンド | 内容 |
|---|---|
| `~p` | probe をやり直す |
| `~c` | プロビジョニング（JP920 / LWOTAA / RETRY 1 / PORT 1、`secrets.h` の AppEUI / AppKey を書き込む）。**送信する前に必ず1回実行する**（工場出荷時は EU868） |
| `~j` | `AT+JOIN`（Join 済みなら `Joined already`） |
| `~s` | センサー値を 18 バイトのコアペイロードにして confirmed 送信 |

`secrets.h` に `PSS_LORAWAN_APP_EUI` / `PSS_LORAWAN_APP_KEY` を設定する（AWS IoT Core for LoRaWAN の Wireless Device の値。名前は deviceId に揃える）。LTE-M 版の `secrets.h` を流用する場合は、`PSS_LTE_ENABLED` を `secrets.h` から外す（LoRaWAN env と排他で、ビルドエラーになる）。設定値、ペイロード、届くメッセージの形式は [docs/40-lorawan-design.md](../docs/40-lorawan-design.md)、デコードは [tools/lorawan](../tools/lorawan/README.md)。

- **AppKey を手で入力するときは、ログを保存しない**（`tee` 等でファイルに残さない）。Wio-E5 の応答にもキーが含まれることがある
- ファームが出す AT ログでは `AT+KEY` と `+KEY:` を伏せ字にしている

### ローカル Mosquitto（Wi-Fi）

```bash
tools/mosquitto/start.sh                  # ブローカー起動
tools/mosquitto/subscribe.sh 192.168.0.42 # 受信ログ
```

`PSS_MQTT_HOST` は Mosquitto を動かす Mac の LAN IP。`PSS_WIFI_SSID` が空でなければ Wi-Fi を優先し、Wi-Fi が未設定または失敗して `PSS_LTE_ENABLED=1` の場合だけ LTE-M にフォールバックする。

### 履歴ログの取り出し（#47）

USB でつないだ状態で起動（Deep Sleep 以外からの起床）するか、起動直後のシリアル待ちの間に `h` を送ると、NVS の履歴ログをシリアルに出力する。

## MQTT ペイロード

[docs/data-model.md](../docs/data-model.md) を参照。電流値そのものは送らず、`power.activeMsBeforePublish` や `network.*Ms` などの所要時間を送る。消費電力は電源ロガー（[tools/power-logger](../tools/power-logger/README.md)）の実測と突き合わせて評価する。

## 関連 Issue

| Issue | 内容 |
|---|---|
| #5 / #6 | センサー読み取り / 判定・MQTT・Deep Sleep |
| #25 / #46 | 低消費電力運用 / リレーによる LTE-M の電源遮断 |
| #30 | LTE-M の時刻同期・モデム内蔵 TLS |
| #32 | 送信確認（sync ledger） |
| #41 | ウォッチドッグ |
| #47 / #50 / #60 | 履歴ログ / ブートモード / 閾値調整用ポテンショメーター |
| #74 / #76 | ブラウンアウトの調査 / LTE-M 切断処理の修正 |
| #40 | LoRaWAN 版（実装中） |
