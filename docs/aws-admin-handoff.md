# AWS 管理者向けセットアップ手順（満空灯センサ PoC）

> **対象読者**: 組織クラウド管理者（AWS・Orion Sandbox 兼務）  
> **依頼元**: 満空灯カラーセンサ読み取り PoC 開発チーム  
> **関連 Issue**: [#27](https://github.com/makeOurCity/parking-status-sensor/issues/27)（本手順の依頼・追跡） / [#4](https://github.com/makeOurCity/parking-status-sensor/issues/4)（設計・スクリプト・完了） / [#6](https://github.com/makeOurCity/parking-status-sensor/issues/6) / [#7](https://github.com/makeOurCity/parking-status-sensor/issues/7)

開発チームは AWS / Orion リソースの作成・運用を直接行わず、**本ドキュメントに沿ったセットアップと、後述「開発チームへの引き渡し項目」の提供**をお願いします。

設計の詳細: [iot-core.md](iot-core.md)  
リポジトリ内スクリプト: [`infra/README.md`](../infra/README.md)

---

## 1. 何を構築するか

駐車場満空灯の色を ESP32 センサで読み取り、MQTT でクラウドに送る PoC です。

```
[ESP32 センサ端末]
    │  Wi-Fi / MQTT over TLS（証明書認証・ポート 8883）
    ▼
[AWS IoT Core]          ← 端末の MQTT 受け口（薄いパイプ）
    │  IoT ルール
    ▼
[AWS Lambda]            ← 現状はスタブ（CloudWatch ログのみ）
    │  #7 で Orion 連携を追加予定
    ▼
[FIWARE Orion]          ← Sandbox 環境（#7・別ドキュメント）
```

### 開発チームが触る / 触らない

| 作業 | 担当 |
|---|---|
| IoT Core・ルール・Lambda の作成 | **クラウド管理者**（本手順 Phase 1） |
| 端末 Thing・証明書の発行 | **クラウド管理者**（本手順 Phase 1） |
| Orion Sandbox 接続前提（VPC・URL 等） | **クラウド管理者**（本手順 Phase 2） |
| 証明書・接続情報の開発チームへの受け渡し | **クラウド管理者** |
| ファームウェアへの証明書設定・実機接続 | 開発チーム（#6） |
| Lambda → Orion upsert のコード実装 | 開発チーム（#7） |
| Lambda コードの組織環境へのデプロイ | **クラウド管理者**（または CI/CD） |

**開発チームに AWS アクセスキー（Administrator 等）の発行は不要**です。  
端末接続に使うのは **デバイス証明書**（後述）であり、IAM アクセスキーではありません。

---

## 2. 作成する AWS リソース一覧

| リソース種別 | 名前（固定） | 備考 |
|---|---|---|
| IoT ポリシー | `parking-status-device` | 全端末共通。Thing 名でスコープ制限 |
| IoT ルール | `parking_status_telemetry` | **ハイフン不可**（アンダースコア） |
| IoT ルール | `parking_status_lorawan` | LoRaWAN の Destination（`lorawan/parking-status/uplink`）を読む（#83） |
| Lambda 関数 | `parking-status-bridge` | Python 3.12 スタブ（後で #7 で更新） |
| Lambda 実行ロール | `parking-status-bridge-lambda-role` | CloudWatch Logs 書き込み + `iotwireless:GetWirelessDevice`（LoRaWAN、#83） |
| IoT Thing | `{deviceId}` ごと | 例: `xiao-e83dc1fb05fc`（端末1台＝Thing 1つ） |
| デバイス証明書 | 端末ごとに1枚 | Thing にアタッチ、ポリシーを紐付け |

**推奨リージョン**: `ap-northeast-1`（東京）

---

## 3. セットアップ方法（推奨: リポジトリのスクリプト）

リポジトリに自動化スクリプトがあります。**管理者がリポジトリを clone し、組織アカウント向けに実行する**のが最も手戻りが少ないです。

### 3.1 前提ツール

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- `jq`, `zip`, `curl`
- 組織アカウントへデプロイできる IAM 権限（[§5](#5-必要な-iam-権限) 参照）

### 3.2 手順

```bash
git clone https://github.com/makeOurCity/parking-status-sensor.git
cd parking-status-sensor/infra

cp config.env.example config.env
# config.env を編集:
#   AWS_REGION=ap-northeast-1
#   AWS_PROFILE=<組織アカウント用プロファイル>

chmod +x *.sh lib.sh

./setup.sh          # ポリシー + Lambda スタブ + IoT ルールを一括作成
./verify.sh         # リソース存在確認

# 端末1台分（deviceId は開発チームから指定を受ける）
./provision-device.sh xiao-e83dc1fb05fc

./test-publish.sh xiao-e83dc1fb05fc   # 疎通確認
```

### 3.3 疎通確認（管理者側）

```bash
aws logs tail /aws/lambda/parking-status-bridge --follow --region ap-northeast-1
```

`test-publish.sh` 実行後、CloudWatch Logs に次のような行が出れば成功です。

```
parking-status telemetry received: {"deviceId":"xiao-...","status":"available",...}
```

---

## 4. 手動セットアップ（コンソール派の場合）

スクリプトを使わない場合は、以下をコンソールで同等に作成してください。

### 4.1 IoT ポリシー `parking-status-device`

[`infra/iot-policy.json`](../infra/iot-policy.json) の内容をそのまま使用。

- `iot:Connect` … `client/${iot:Connection.Thing.ThingName}`
- `iot:Publish` … Basic Ingest トピック + 検証用通常トピック

### 4.2 Lambda `parking-status-bridge`

| 項目 | 値 |
|---|---|
| ランタイム | Python 3.12 |
| ハンドラ | `handler.handler` |
| コード | [`bridge/handler.py`](../bridge/handler.py) と [`bridge/lorawan.py`](../bridge/lorawan.py) を zip でデプロイ |
| タイムアウト | 30 秒（#83: LoRaWAN のコールドスタート対策。10 秒だと余裕が小さかった） |
| メモリ | 256 MB |
| 実行ロール | `AWSLambdaBasicExecutionRole`（CloudWatch Logs）+ インラインポリシー `parking-status-bridge-iotwireless-read`（`iotwireless:GetWirelessDevice`、リソースは `arn:aws:iotwireless:<region>:<account>:WirelessDevice/*`） |

### 4.3 IoT ルール `parking_status_telemetry`

**SQL**（Basic Ingest）:

```sql
SELECT * FROM '$aws/rules/parking_status_telemetry/parking-status/+/telemetry'
```

**アクション**: Lambda `parking-status-bridge` を起動

**Lambda 側のリソースポリシー**: プリンシパル `iot.amazonaws.com` からの `lambda:InvokeFunction` を許可（ソース: 当該 IoT ルール ARN）

### 4.3b IoT ルール `parking_status_lorawan`（LoRaWAN、#83）

**SQL**:

```sql
SELECT * FROM 'lorawan/parking-status/uplink'
```

**アクション**: Lambda `parking-status-bridge` を起動。Lambda のリソースポリシーに、このルール ARN からの `lambda:InvokeFunction` も追加する（ステートメント ID は `iot-rule-parking_status_lorawan`）。

### 4.4 端末（Thing + 証明書）

各 `deviceId` について:

1. Thing を作成（名前 = `deviceId`）
2. X.509 証明書を発行（アクティブ）
3. 証明書を Thing にアタッチ
4. ポリシー `parking-status-device` を証明書にアタッチ
5. Amazon Root CA 1 を取得（[公式](https://www.amazontrust.com/repository/AmazonRootCA1.pem)）

---

## 5. 必要な IAM 権限

セットアップ実行者（管理者またはデプロイ用ロール）に必要な権限の目安です。  
`AdministratorAccess` は不要ですが、以下をカバーするポリシーが必要です。

| サービス | 操作の例 |
|---|---|
| IoT | `CreatePolicy`, `CreateTopicRule`, `CreateThing`, `CreateKeysAndCertificate`, `AttachPolicy`, `AttachThingPrincipal`, `DescribeEndpoint` |
| Lambda | `CreateFunction`, `UpdateFunctionCode`, `AddPermission`, `GetFunction` |
| IAM | `CreateRole`, `AttachRolePolicy`, `PutRolePolicy`, `GetRole`（Lambda 実行ロール作成と、LoRaWAN 用インラインポリシー） |
| CloudWatch Logs | Lambda 実行ロール経由（マネージドポリシーで可） |
| STS | `GetCallerIdentity` |

### デプロイ用ポリシー例（最小構成の参考）

アカウント ID・リージョンは環境に合わせて置換してください。  
厳密な最小権限は組織のセキュリティ基準に合わせて調整してください。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ParkingStatusDeploy",
      "Effect": "Allow",
      "Action": [
        "iot:*",
        "lambda:CreateFunction",
        "lambda:UpdateFunctionCode",
        "lambda:GetFunction",
        "lambda:AddPermission",
        "lambda:GetPolicy",
        "iam:CreateRole",
        "iam:GetRole",
        "iam:AttachRolePolicy",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:PassRole",
        "logs:*",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

**推奨**: 長期アクセスキーではなく、**IAM Identity Center（SSO）** または **AssumeRole** でデプロイ用ロールを引き受ける運用。

---

## 6. MQTT・トピック設計

### Basic Ingest（採用）

端末は次のトピックへ publish します（メッセージング課金 $0）。

```
$aws/rules/parking_status_telemetry/parking-status/{deviceId}/telemetry
```

例（`deviceId = xiao-e83dc1fb05fc`）:

```
$aws/rules/parking_status_telemetry/parking-status/xiao-e83dc1fb05fc/telemetry
```

### 接続パラメータ

| 項目 | 値 |
|---|---|
| プロトコル | MQTT over TLS |
| ポート | **8883** |
| 認証 | X.509 デバイス証明書（ユーザー名・パスワード不要） |
| MQTT エンドポイント | `xxxx-ats.iot.ap-northeast-1.amazonaws.com`（アカウント固有） |

エンドポイントの確認:

```bash
aws iot describe-endpoint --endpoint-type iot:Data-ATS --region ap-northeast-1
```

### ペイロード形式（JSON）

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

`status` の値: `full`（満）/ `available`（空）/ `unknown`（不明）

---

## 7. 開発チームへの引き渡し項目

セットアップ完了後、**開発チームに以下を安全な経路**（組織の秘密情報管理ルールに従い）で渡してください。

### 必須（環境共通）

| 項目 | 例 | 用途 |
|---|---|---|
| MQTT エンドポイント | `a2v6drntd09tsc-ats.iot.ap-northeast-1.amazonaws.com` | ファーム `PSS_MQTT_HOST` |
| リージョン | `ap-northeast-1` | 記録用 |
| Basic Ingest トピックのパターン | `$aws/rules/parking_status_telemetry/parking-status/{deviceId}/telemetry` | ファーム `PSS_MQTT_TOPIC` |

### 端末ごと（`deviceId` 1台につき1セット）

| 項目 | ファイル名 | 用途 |
|---|---|---|
| `deviceId` | — | Thing 名と一致 |
| デバイス証明書 | `device.pem.crt` | TLS クライアント証明書 |
| 秘密鍵 | `private.pem.key` | **厳重管理・再発行不可に注意** |
| ルート CA | `AmazonRootCA1.pem` | TLS 検証 |

開発チームはこれらを `firmware/certs/` に配置し、`firmware/include/secrets.h` に接続先を設定します（#6）。

### 引き渡しテンプレート（コピー用）

```
【満空灯センサ PoC — AWS IoT Core 接続情報】

環境: <本番 / Sandbox / PoC>
リージョン: ap-northeast-1
MQTT エンドポイント: <xxxx-ats.iot.ap-northeast-1.amazonaws.com>
MQTT ポート: 8883
MQTT トピック: $aws/rules/parking_status_telemetry/parking-status/<deviceId>/telemetry

端末: <deviceId>
  - device.pem.crt  （添付）
  - private.pem.key （添付・秘密）
  - AmazonRootCA1.pem （添付）

疎通確認日: YYYY-MM-DD
確認方法: test-publish.sh → CloudWatch Logs 確認済み
```

### 開発チームに渡さないもの

- IAM アクセスキー / シークレット（端末接続に不要）
- AWS コンソールのルートユーザー認証情報

---

## 8. 端末台数と deviceId

PoC 初期は **2〜3 現場・数台** を想定しています。

| 項目 | 方針 |
|---|---|
| `deviceId` | `xiao-{WiFi MAC 12桁}` 形式（例: `xiao-e83dc1fb05fc`） |
| Thing 名 | `deviceId` と同一 |
| 証明書 | **端末1台につき1枚**。再プロビジョニング時は旧証明書をデタッチ |

新規端末追加時は、開発チームから `deviceId` の連絡を受け、`provision-device.sh <deviceId>` または手動で同等の作業を実施してください。

---

## 9. 料金の目安

PoC 規模（3 台・15 分間隔・接続→publish→切断）では **月額 $0.01 未満**（Basic Ingest 使用時）。  
詳細: [iot-core.md §料金](iot-core.md#料金poc-規模の目安)

Lambda・CloudWatch Logs も無料枠内に収まる想定です。

---

## 10. Phase 2: Orion Sandbox 接続前提（#7 向け）

Phase 1 完了後、Lambda から **FIWARE Orion（Sandbox）** へ NGSIv2 upsert する実装を開発チームが追加します（#7）。  
その前に、クラウド管理者が以下を整備してください。

| 項目 | 内容 |
|---|---|
| Orion 接続 URL | Lambda 環境変数 `ORION_URL` 等 |
| ネットワーク | Orion が VPC 内の場合、Lambda の VPC 設定・セキュリティグループ |
| 認証 | Fiware-Service ヘッダ等（環境の既存パターンに合わせる） |
| Lambda デプロイ | 開発チーム PR マージ後の `deploy-bridge-stub.sh` 相当 or CI/CD |

Phase 2 完了後、開発チームへ Orion 接続情報（URL・必要なヘッダ名）を引き渡してください。  
エンティティ設計は [data-model.md](data-model.md)、実装は #7 を参照。

---

## 11. トラブルシューティング

| 症状 | 確認事項 |
|---|---|
| ルール作成失敗 | ルール名にハイフンが含まれていないか（`parking_status_telemetry` を使用） |
| Lambda が起動しない | IoT ルールの SQL とトピック名が一致しているか |
| 端末が接続できない | 証明書が Thing にアタッチされているか、ポリシーが証明書に紐付いているか |
| CLI publish 失敗 | AWS CLI v2 では `--cli-binary-format raw-in-base64-out` が必要（`test-publish.sh` 参照） |
| 証明書が複数 | `provision-device.sh` の再実行で増える。不要な証明書はデタッチ・非アクティブ化 |

---

## 12. チェックリスト（クラウド管理者用）

### Phase 1: IoT Core + Lambda スタブ

```
[ ] 組織アカウント・リージョン（ap-northeast-1）を確定
[ ] setup.sh または手動で IoT ポリシー・ルール・Lambda を作成
[ ] verify.sh または同等の存在確認
[ ] test-publish.sh で IoT Core → Lambda → CloudWatch 疎通確認
[ ] 各 deviceId について Thing + 証明書を発行
[ ] §7 の引き渡し項目を開発チームに安全に渡した
```

### Phase 2: Orion Sandbox（#7 の前提）

```
[ ] Orion Sandbox の接続 URL・認証方式を確定
[ ] Lambda の VPC / セキュリティグループ設定（必要な場合）
[ ] Lambda 環境変数（ORION_URL 等）を設定
[ ] 接続情報を開発チームに引き渡し
[ ] #7 実装デプロイ後、IoT Core → Lambda → Orion E2E を確認
```

---

## 13. 問い合わせ先

| 内容 | 連絡先 |
|---|---|
| deviceId の指定・端末台数・Lambda 実装 | 開発チーム |
| AWS IoT Core・証明書・Orion 接続・Lambda デプロイ | **クラウド管理者**（本ドキュメント担当・AWS / Orion 兼務） |

リポジトリ: https://github.com/makeOurCity/parking-status-sensor
