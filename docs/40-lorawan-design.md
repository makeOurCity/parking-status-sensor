# LoRaWAN（Grove Wio-E5）設計メモ（#40）

> **作業記録・WIP**: #40 の PR ごとに更新する。現時点は PR2（Join と1パケット送信）まで。ファームの通常サイクルへの統合（PR3）と消費電力の評価（PR4）はまだ。

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

クラウド側（IoT ルール、bridge の LoRaWAN デコーダ、Orion 連携）は別 Issue で扱う。

## 2. Wio-E5 の設定

工場出荷時は **EU868 / LWABP** になっている。**日本ではこのまま送信しない**（868MHz 帯は使えない）。

電源投入時のプロビジョニング（`wioE5ProvisionOtaa()`）で次のように設定する。設定コマンドは Join セッションを消す可能性があるため、電源投入時だけ実行する（PR3 で `ESP_RST_POWERON` 時に限定する）。

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

## 3. コアペイロード（fPort 1、ver 1、固定 11 バイト）

JSON（数百バイト）は LoRaWAN では送れない。AS923 で UplinkDwellTime=1 の場合、DR2 の上限は 11 バイト（仕様書 Table 3-20）。今の TPS は `OFF` だが、ネットワークから TxParamSetupReq で有効にされることもあるため、常に 11 バイトに収める（`static_assert` で担保）。

| byte | bit | 内容 |
|---|---|---|
| 0 | 7:6 | version（=1） |
| 0 | 5:4 | status（0 full / 1 available / 2 unknown。`ParkingStatus` の順） |
| 0 | 3:2 | 送信理由（0 状態変化 / 1 heartbeat / 2 pending の再送 / 3 ブートモード） |
| 0 | 1 | coldBoot（`esp_reset_reason() == ESP_RST_POWERON`） |
| 0 | 0 | 予備（0） |
| 1 | 7:5 | 前サイクルの結果（`CycleOutcome` 0–6） |
| 1 | 4:3 | 前サイクルの試行回数（3 で頭打ち） |
| 1 | 2:0 | ブートモードの何回目か（0 は通常サイクル、7 で頭打ち） |
| 2–9 | | raw R / G / B / W（VEML6040、各 uint16 ビッグエンディアン） |
| 10 | | 前サイクルの起床時間（250ms 単位、255 = 63.75s で頭打ち） |

載せないもの:

- `deviceId`: Wireless Device 名で分かる
- `timestamp`: Destination のメッセージの受信時刻を使う
- `threshold` と診断用の詳細: 必要になれば fPort 2 に拡張形式を作る

連番は LoRaWAN の FCnt で取れる。

- エンコーダ: `firmware/src/lorawan_payload.cpp`
- デコーダ: `tools/lorawan/decode.py`
- テストベクタ: `tools/lorawan/test_vectors.json`。hex はエンコーダの出力で、1件は手計算と照合済み

## 4. Join と送信の動き（実機での実測）

| 操作 | 応答 | 所要時間 |
|---|---|---|
| `AT+JOIN`（未 Join） | `+JOIN: Network joined` → `NetID` / `DevAddr` → `Done` | 約 6.0s |
| `AT+JOIN`（Join 済み） | `+JOIN: Joined already`（無線を使わない） | 約 85ms |
| `AT+CMSGHEX`（confirmed、11B、DR2） | `Wait ACK` → `ACK Received` → `RXWIN1, RSSI -24, SNR 7.0` → `Done` | 約 1.9s |
| `AT+LOWPOWER` → 任意の入力 | `+LOWPOWER: SLEEP` → `+LOWPOWER: WAKEUP`（最初の `AT` は捨てられる） | — |

- Join 済みなら `AT+JOIN` は無線を使わずに返る。そのため PR3 では Join 済みかを RTC に覚えず、**送信するサイクルで毎回 `AT+JOIN` を送る**
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

## 6. 未確認・今後の課題

- PR3: `transport` への統合、プロビジョニングを電源投入時だけに限る、スキップサイクルで Wio-E5 が起こされたままにならない対策（起動ログの抑止 + 毎サイクル `AT+LOWPOWER`）、時間予算
- PR4: U200 で待機電流（スキップサイクル後 / 送信サイクル後）、Join 1回、送信1回を計測
- Device Profile の MaxEirp が 5 と小さい。ベンチでは問題ないが、現場で距離が出ないときの見直し候補
