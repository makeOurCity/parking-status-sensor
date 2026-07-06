# AWS IoT Core 設計（Issue #4）

> PoC 端末（#6）とブリッジ（#7）をつなぐ受信基盤。  
> 方針の確定経緯は [Issue #4](https://github.com/makeOurCity/parking-status-sensor/issues/4) を参照。

## アーキテクチャ

```
ESP32 --Wi-Fi/MQTT/TLS--> AWS IoT Core --ルール--> Lambda（#7）--> FIWARE Orion
```

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
