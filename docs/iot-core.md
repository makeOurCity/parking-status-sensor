# AWS IoT Core 設計（Issue #4）

> PoC 端末（#6）とブリッジ（#7）をつなぐ受信基盤。  
> 方針の確定経緯は [Issue #4](https://github.com/makeOurCity/parking-status-sensor/issues/4) を参照。

## アーキテクチャ

```
ESP32 --Wi-Fi/LTE-M/MQTT/TLS--> AWS IoT Core --ルール--> Lambda（#7）--> FIWARE Orion
Wio-E5 --LoRaWAN--> SenseCAP M2 --> IoT Core for LoRaWAN --Destination--> IoT Core --ルール--> Lambda
```

LoRaWAN の経路は「LoRaWAN の経路（#40, #83）」を参照。

| コンポーネント | 役割 |
|---|---|
| AWS IoT Core | 端末の MQTT 受け口（薄いパイプ） |
| IoT ルール | テレメトリ到着時に Lambda を起動 |
| Lambda | ペイロード変換・NGSIv2 upsert（#7） |
| Mosquitto（ローカル） | 開発・机上検証のみ（`tools/mosquitto/`） |

## 命名規則

| リソース | 名前 | 例 |
|---|---|---|
| Thing | `deviceId` と同一 | `xiao-e83dc1fb05fc` |
| IoT ポリシー | `parking-status-device`（全端末共通） | — |
| IoT ルール | `parking_status_telemetry` | — |
| IoT ルール（LoRaWAN） | `parking_status_lorawan` | #83 |
| Lambda | `parking-status-bridge` | #7 で本実装、#4 ではスタブ |

`deviceId` はファームウェアの `PSS_DEVICE_ID`（空なら Wi-Fi MAC から `xiao-{mac}`）に合わせる（#14）。

## MQTT トピック

### 通常 publish（ローカル Mosquitto / 検証用）

```
parking-status/{deviceId}/telemetry
```

ファームウェアのデフォルト（`PSS_MQTT_TOPIC` 未指定時）と一致する。

### Basic Ingest（PoC 本番パス・推奨）

端末は次のトピックへ publish する。メッセージング課金を回避し、ルールエンジン課金のみとなる。

```
$aws/rules/parking_status_telemetry/parking-status/{deviceId}/telemetry
```

| 方式 | メリット | デメリット |
|---|---|---|
| 通常トピック | 実装が単純、Mosquitto と同じパス | メッセージング課金が発生 |
| **Basic Ingest（採用）** | PoC 規模でメッセージング $0 | トピック名が長い、他サブスクライバー不可 |

PoC では他サブスクライバーが不要なため **Basic Ingest を採用**する。

## IoT ポリシー

全端末で共通ポリシー `parking-status-device` を使い、Thing 名でスコープを絞る。

| アクション | リソース |
|---|---|
| `iot:Connect` | `client/${iot:Connection.Thing.ThingName}` |
| `iot:Publish` | `topic/$aws/rules/parking_status_telemetry/parking-status/${iot:Connection.Thing.ThingName}/telemetry` |
| `iot:Publish`（検証用） | `topic/parking-status/${iot:Connection.Thing.ThingName}/telemetry` |

検証用の通常トピック publish 権限は、Mosquitto 相当の AWS 疎通確認が終わったら削除してよい。

## IoT ルール

ルール名: `parking_status_telemetry`

```sql
SELECT *
FROM '$aws/rules/parking_status_telemetry/parking-status/+/telemetry'
```

アクション: Lambda `parking-status-bridge` を起動。

## LoRaWAN の経路（#40, #83）

LoRaWAN 端末（Grove Wio-E5）は MQTT を話さない。ゲートウェイ（SenseCAP M2）から AWS IoT Core for LoRaWAN に届いたアップリンクを、Destination `Saga_IoT_Core` が MQTT トピックに publish する。端末側の仕様は [40-lorawan-design.md](40-lorawan-design.md)。

```
Destination "Saga_IoT_Core" ─▶ lorawan/parking-status/uplink
  ─▶ IoT ルール parking_status_lorawan ─▶ Lambda parking-status-bridge
  ─▶ CloudWatch Logs（iOS ログビューア）
```

| 項目 | 値 |
|---|---|
| トピック | `lorawan/parking-status/uplink`（`parking-status/<deviceId>/telemetry` とは別の名前空間） |
| IoT ルール | `parking_status_lorawan`、SQL は `SELECT * FROM 'lorawan/parking-status/uplink'`、アクションは Lambda `parking-status-bridge` |
| Lambda 呼び出し許可 | ステートメント ID `iot-rule-parking_status_lorawan`（`infra/setup.sh` が追加） |

Lambda は `WirelessMetadata.LoRaWAN` があるメッセージを LoRaWAN と判断し、次の処理をする（実装は [bridge/lorawan.py](../bridge/lorawan.py)）。

1. 生のメッセージを `lorawan uplink raw: ...` でログに出す（iOS アプリの検索 `telemetry received` には掛からない）
2. `PayloadData`（base64）を、fPort 1 / ver 1 / 18 バイトのコアペイロードとしてデコードする
3. `WirelessDeviceId` から `iotwireless:GetWirelessDevice` で Wireless Device の `Name` を引き、deviceId にする（コンテナ内でキャッシュ。Wireless Device 名は deviceId にそろえておく）
4. LTE-M 版と同じ形の JSON にして、`parking-status telemetry received: <JSON>` で出す

デコードに失敗したメッセージ（fPort・長さ・version の不一致）や、Wireless Device が見つからないメッセージは、`lorawan uplink rejected: ...` をエラーログに残して正常終了する。`telemetry received` の行は出さない。

LoRaWAN 版のテレメトリ JSON は、LTE-M 版（下記）の項目に加えて次を持つ。

```json
{
  "deviceId": "xiao-e83dc1fc1aec",
  "status": "available",
  "raw": { "red": 12, "green": 18, "blue": 3, "clear": 64 },
  "threshold": 100,
  "determinedBy": "device",
  "timestamp": "2026-10-01T07:47:49Z",
  "power": { "bootCount": 1, "resetReason": "power_on", "wakeCause": "power_on" },
  "network": { "transport": "lorawan", "rssi": -46, "snr": 13.25, "dataRate": 5, "fCnt": 3, "frequency": 922600000 },
  "sync": { "prevOutcome": "none", "prevAttempts": 0, "prevActiveMs": 13000 },
  "lorawan": { "reason": "state_change", "coldBoot": true, "bootSlot": 1,
               "wirelessDeviceId": "73742d6b-b4bd-426a-af5b-83412752b8a6", "devEui": "2cf7f1207380e5f9" }
}
```

- `timestamp` は Destination のメッセージの `WirelessMetadata.LoRaWAN.Timestamp`（ネットワークサーバーの受信時刻）
- `network.rssi` / `snr` は `Gateways[0]`。`dataRate` / `frequency`（Hz）は数値にして出す
- `network` には LTE-M 版のような接続時間（`networkConnectMs` 等）はない
- `lorawan` は LoRaWAN 固有の項目（送信理由、コールドブート、ブートモードの何回目か、識別子）

## 端末接続情報（ファームウェア向け）

AWS IoT Core へ接続する際、端末ごとに以下が必要。

| 項目 | 設定先 | 例 |
|---|---|---|
| MQTT ホスト | `PSS_MQTT_HOST` | `a1b2c3d4e5f6g7-ats.iot.ap-northeast-1.amazonaws.com` |
| MQTT ポート | `PSS_MQTT_PORT` | `8883`（TLS） |
| MQTT トピック | `PSS_MQTT_TOPIC` | `$aws/rules/parking_status_telemetry/parking-status/xiao-e83dc1fb05fc/telemetry` |
| デバイス証明書 | `firmware/certs/device.pem.crt` | `infra/provision-device.sh` で生成 |
| 秘密鍵 | `firmware/certs/private.pem.key` | 同上 |
| ルート CA | `firmware/certs/AmazonRootCA1.pem` | `infra/provision-device.sh` で取得 |

ユーザー名・パスワードは不要（証明書認証）。  
ローカル Mosquitto 検証時は `PSS_MQTT_PORT=1883`、証明書なし。

### ペイロード形式

[docs/data-model.md](data-model.md) および Issue #6 参照。

```json
{
  "deviceId": "xiao-e83dc1fb05fc",
  "status": "available",
  "raw": { "red": 150, "green": 820, "blue": 200, "clear": 1200 },
  "threshold": 100,
  "determinedBy": "device",
  "timestamp": "2026-06-17T12:00:00Z"
}
```

## セットアップ手順

前提: AWS CLI v2、適切な IAM 権限（IoT Core・Lambda）、リージョン `ap-northeast-1`（変更可）。

```bash
cd infra
cp config.env.example config.env   # リージョン等を編集
./setup.sh                         # ポリシー・ルール・Lambda スタブを一括作成
./provision-device.sh xiao-e83dc1fb05fc   # Thing + 証明書を端末1台分
```

疎通確認（AWS CLI から publish）:

```bash
./test-publish.sh xiao-e83dc1fb05fc
# CloudWatch Logs で Lambda スタブのログを確認
```

端末からの疎通は #6 で TLS 対応後に `secrets.h` を AWS 向けに切り替えて実施する。

## 検証環境（2026-07 方針）

| フェーズ | 環境 | 到達点 |
|---|---|---|
| **#4（現在）** | 開発者のプライベート AWS アカウント | IoT Core → Lambda スタブ → CloudWatch Logs |
| **#6** | 同上 + 実機（TLS） | 端末から IoT Core へ publish |
| **#7** | 組織 Sandbox Orion | Lambda 本実装（NGSIv2 upsert） |

Orion 連携は #7 に委ねる。#4 では Lambda スタブが受信ペイロードを CloudWatch に記録するだけで完了とする。

### 認証の区切り

| 区間 | 認証 |
|---|---|
| 端末 → IoT Core | X.509 デバイス証明書（TLS 8883） |
| IoT Core → Lambda | IAM（IoT ルールから `lambda:InvokeFunction`） |
| Lambda → Orion | #7 で定義（組織 Sandbox の接続仕様に合わせる） |

`infra/config.env` の `AWS_PROFILE` で対象アカウントを指定する。組織アカウントへの移行時は、管理者が [aws-admin-handoff.md](aws-admin-handoff.md) に沿ってセットアップし、接続情報・証明書を開発チームに引き渡す（Thing / 証明書は再プロビジョニング）。

## 料金（PoC 規模の目安）

3 台・15 分間隔・接続→publish→切断の場合、IoT Core 合計 **≒ $0.005/月未満**（Basic Ingest 使用時）。  
詳細は Issue #4 本文を参照。

## 関連

| Issue | 内容 |
|---|---|
| [#4](https://github.com/makeOurCity/parking-status-sensor/issues/4) | 本ドキュメントの親 Issue |
| [#6](https://github.com/makeOurCity/parking-status-sensor/issues/6) | ファームウェア MQTT 送信（TLS 対応） |
| [#7](https://github.com/makeOurCity/parking-status-sensor/issues/7) | Lambda ブリッジ本実装 |
| [#14](https://github.com/makeOurCity/parking-status-sensor/issues/14) | デバイス ID とエンティティ ID マッピング |
