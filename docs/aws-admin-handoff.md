# AWS 環境の構築手順（満空灯センサ PoC・組織アカウント）

> **対象読者**: この PoC の AWS 環境を構築・運用する人（開発チーム）と、アカウントと権限を用意するクラウド管理者  
> **関連 Issue**: [#98](https://github.com/makeOurCity/parking-status-sensor/issues/98)（組織アカウントへの移行） / [#27](https://github.com/makeOurCity/parking-status-sensor/issues/27)（管理者への依頼） / [#4](https://github.com/makeOurCity/parking-status-sensor/issues/4)（設計・スクリプト） / [#6](https://github.com/makeOurCity/parking-status-sensor/issues/6) / [#7](https://github.com/makeOurCity/parking-status-sensor/issues/7)

> **現状（2026-10）**: 組織が **この PoC 専用の AWS アカウント**を用意し、**開発チームが `infra/` のスクリプトで構築した**（#98）。管理者は、アカウントと IAM Identity Center（SSO）の権限（ReadOnly / PowerUser / Admin）を払い出した。当初は「管理者が構築して引き渡す」前提でこのドキュメントを書いたが、実際の運用はそうなっていない。**本ドキュメントは、構成の全体像・必要な権限・手動で作る場合の手順の参照用**。専用アカウントなので、命名規則・タグ・リージョンなどの組織のルールの指定はなく、組織内の他の AWS リソースにも影響しない。

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
[AWS Lambda]            ← CloudWatch ログ + Orion upsert（#7）
    │  デバイスマスター（DynamoDB）から name / location を引く
    ▼
[FIWARE Orion]          ← Sandbox 環境（#7・別ドキュメント）
```

### 役割分担（実績）

| 作業 | 担当 |
|---|---|
| PoC 専用の AWS アカウントの用意、SSO 権限（ReadOnly / PowerUser / Admin）の払い出し | **クラウド管理者** |
| IoT Core・ルール・Lambda・Cognito・DynamoDB・LoRaWAN のリソース作成 | 開発チーム（`infra/` のスクリプト） |
| 端末 Thing・証明書の発行 | 開発チーム（`infra/provision-device.sh`） |
| ファームウェアへの証明書・接続先の設定、実機接続 | 開発チーム（#6） |
| Lambda → Orion upsert の実装とデプロイ | 開発チーム（#7）。Orion の接続情報は Orion Sandbox 側から受け取る（§10） |

### 権限の使い分け

SSO で 3 種類の権限を払い出されている。**確認は ReadOnly、通常の作成は PowerUser、IAM ロールの作成と `iam:PassRole` が要る手順だけ Admin** を使う（Admin は必要な手順に限る）。

| 権限 | 使う作業 |
|---|---|
| ReadOnly | `verify*.sh`、ログの確認（`aws logs tail`）など、読み取りだけの作業 |
| PowerUser | IoT Core・Cognito・DynamoDB・LoRaWAN（ゲートウェイ・Wireless Device・プロファイル）の作成、テスト送信、デバイスマスターの登録 |
| Admin | IAM ロールを作る手順: `setup.sh`・`deploy-bridge-stub.sh`（Lambda 実行ロール）、`setup-cognito.sh`（認証済みロール）、`setup-lorawan.sh role` と Destination を作る `setup-lorawan.sh profiles`（`PassRole`） |

スクリプトは `EXPECTED_ACCOUNT_ID` と実際のアカウントが違えば何も作らずに中断する（旧アカウントとの取り違え防止）。端末の接続に使うのは **デバイス証明書**であり、IAM アクセスキーではない。

---

## 2. 作成する AWS リソース一覧

| リソース種別 | 名前（固定） | 備考 |
|---|---|---|
| IoT ポリシー | `parking-status-device` | 全端末共通。Thing 名でスコープ制限 |
| IoT ルール | `parking_status_telemetry` | **ハイフン不可**（アンダースコア） |
| IoT ルール | `parking_status_lorawan` | LoRaWAN の Destination（`lorawan/parking-status/uplink`）を読む（#83） |
| Lambda 関数 | `parking-status-bridge` | Python 3.12。ログ出力 + Orion upsert（#7）。Orion の接続先は環境変数（§10） |
| Lambda 実行ロール | `parking-status-bridge-lambda-role` | CloudWatch Logs 書き込み + `iotwireless:GetWirelessDevice`（LoRaWAN、#83）+ `dynamodb:GetItem`（デバイスマスター、#7） |
| DynamoDB テーブル | `parking-status-device-master` | デバイスマスター（deviceId → name / location、#7, #14）。パーティションキー `deviceId`（文字列）、プロビジョンド 1 RCU / 1 WCU（無料枠内） |
| IoT Thing | `{deviceId}` ごと | 例: `xiao-e83dc1fb05fc`（端末1台＝Thing 1つ） |
| デバイス証明書 | 端末ごとに1枚 | Thing にアタッチ、ポリシーを紐付け |
| Cognito User Pool / App Client / Identity Pool | `parking-status-ios-app` / `parking-status-ios-client` / `parking_status_ios_app` | iOS ログビューア向け（[ios-app-cognito.md](ios-app-cognito.md)）。`setup-cognito.sh` |
| IAM ロール（Cognito 認証済み） | `parking-status-ios-app-authenticated` | CloudWatch Logs とデバイスマスター（DynamoDB）の読み取り専用 |
| LoRaWAN: Service Profile / Device Profile | `parking-status` / `AS923-1-A-OTAA` | [40-lorawan-design.md](40-lorawan-design.md) §1。`setup-lorawan.sh profiles` |
| LoRaWAN: Destination | `Saga_IoT_Core` | MQTT トピック `lorawan/parking-status/uplink` に publish。`setup-lorawan.sh profiles` |
| IAM ロール（LoRaWAN） | `IoTWirelessGatewayCertManagerRole`（パス `/service-role/`） | ゲートウェイ（CUPS）と Destination が使う。`setup-lorawan.sh role` |
| LoRaWAN: ゲートウェイ / Wireless Device | `Saga Gateway`（SenseCAP M2） / `{deviceId}` | `setup-lorawan.sh gateway` / `device`。**ゲートウェイ EUI・DevEui は他のアカウントと重複して登録できない** |

**推奨リージョン**: `ap-northeast-1`（東京）

---

## 3. セットアップ方法（推奨: リポジトリのスクリプト）

リポジトリの自動化スクリプトで作る（何度実行しても同じ結果になる）。詳細は [`infra/README.md`](../infra/README.md)。

### 3.1 前提ツール

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)（SSO のプロファイルを設定済み。`aws configure sso`）
- `jq`, `zip`, `curl`
- 組織アカウントへの権限（[§1 の権限の使い分け](#権限の使い分け)、[§5](#5-必要な-iam-権限)）

### 3.2 手順

```bash
git clone https://github.com/makeOurCity/parking-status-sensor.git
cd parking-status-sensor/infra

cp config.env.example config.org.env     # 組織アカウント用（Git 管理外）
# config.org.env を編集:
#   EXPECTED_ACCOUNT_ID=<12 桁のアカウント ID>   # 必須。違うアカウントなら中断する
#   AWS_REGION=ap-northeast-1
# AWS_PROFILE は書かず、実行時に渡す

export CONFIG_FILE=config.org.env
aws sso login --sso-session <セッション名>

# --- IAM ロールを作る手順は Admin ---
AWS_PROFILE=<Admin> ./setup.sh              # IoT ポリシー・デバイスマスター・Lambda（と実行ロール）・IoT ルール
AWS_PROFILE=<Admin> ./setup-cognito.sh      # Cognito と認証済みロール（初回のパスワードは 1 度だけ表示）
AWS_PROFILE=<Admin> ./setup-lorawan.sh role       # LoRaWAN 用ロール
AWS_PROFILE=<Admin> ./setup-lorawan.sh profiles   # Service / Device Profile と Destination

# --- 確認は ReadOnly ---
AWS_PROFILE=<ReadOnly> ./verify.sh
AWS_PROFILE=<ReadOnly> ./verify-cognito.sh
AWS_PROFILE=<ReadOnly> ./verify-lorawan.sh

# --- 端末（PowerUser）---
AWS_PROFILE=<PowerUser> ./provision-device.sh <deviceId>                # Thing + 証明書（firmware/certs/ に出力）
AWS_PROFILE=<PowerUser> ./device-master.sh put <deviceId> <名称> <緯度> <経度>   # デバイスマスターに登録
AWS_PROFILE=<PowerUser> ./test-publish.sh xiao-test-device              # 疎通確認（テスト用の deviceId で）
```

- **Orion が有効な間（Lambda に `ORION_URL` を設定した後）は、実機の `deviceId` でテスト送信しない**。デバイスマスターに登録済みの ID では、実データのエンティティが上書きされる。未登録の ID は Orion にスキップされるので安全（§10）
- LoRaWAN のゲートウェイと Wireless Device は、旧環境から移す場合は切り替えの手順が要る（EUI の重複登録不可。#98 の Issue のコメント「LoRaWAN と M2 ゲートウェイの切り替え手順」）

### 3.3 疎通確認（管理者側）

```bash
aws logs tail /aws/lambda/parking-status-bridge --follow --region ap-northeast-1
```

`test-publish.sh` 実行後、CloudWatch Logs に次のような行が出れば成功です。

```
parking-status telemetry received: {"deviceId":"xiao-...","status":"open",...}
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
| 実行ロール | `AWSLambdaBasicExecutionRole`（CloudWatch Logs）+ インラインポリシー `parking-status-bridge-iotwireless-read`（`iotwireless:GetWirelessDevice`、リソースは `arn:aws:iotwireless:<region>:<account>:WirelessDevice/*`）+ インラインポリシー `parking-status-bridge-device-master-read`（`dynamodb:GetItem`、リソースは `arn:aws:dynamodb:<region>:<account>:table/parking-status-device-master`）。**ロールを管理者が作る場合（#98）は後者も付ける**（付けないと Orion には書かれず、`orion skipped: device master lookup failed` がログに出る） |
| コード | 上の 2 ファイルに加え [`bridge/ngsi.py`](../bridge/ngsi.py)・[`bridge/orion.py`](../bridge/orion.py)・[`bridge/device_master.py`](../bridge/device_master.py)（#7） |
| 環境変数 | `DEVICE_MASTER_TABLE`、`ORION_URL` ほか（§10） |

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

セットアップ実行者（Admin、または Power User と、ロール作成用の補助権限）に必要な権限の目安です。  
`AdministratorAccess` は不要ですが、以下をカバーするポリシーが必要です。

| サービス | 操作の例 |
|---|---|
| IoT | `CreatePolicy`, `CreateTopicRule`, `CreateThing`, `CreateKeysAndCertificate`, `AttachPolicy`, `AttachThingPrincipal`, `DescribeEndpoint` |
| Lambda | `CreateFunction`, `UpdateFunctionCode`, `AddPermission`, `GetFunction` |
| Cognito | `cognito-idp:*`（User Pool / App Client / ユーザー作成）、`cognito-identity:*`（Identity Pool 作成・ロール割り当て）（iOS ログビューア、[ios-app-cognito.md](ios-app-cognito.md)） |
| DynamoDB | `CreateTable`, `DescribeTable`, `PutItem`, `Scan`, `GetItem`, `DeleteItem`（デバイスマスターのテーブル作成と登録。#7） |
| IoT Wireless | `iotwireless:*`（Service / Device Profile・Destination・ゲートウェイ・Wireless Device の作成。LoRaWAN、[40-lorawan-design.md](40-lorawan-design.md)） |
| IAM | `CreateRole`, `AttachRolePolicy`, `PutRolePolicy`, `GetRole`（Lambda 実行ロール・Cognito 認証済みロール・LoRaWAN 用ロールの作成） |
| CloudWatch Logs | Lambda 実行ロール経由（マネージドポリシーで可） |
| STS | `GetCallerIdentity` |

### Power User 権限で作業する場合（#98）

AWS 管理ポリシー `PowerUserAccess` は IAM をほぼ操作できず、**IAM ロールの作成と `iam:PassRole` ができない**。IoT Core・Lambda・Cognito・IoT Wireless・DynamoDB・CloudWatch Logs は上の表のとおりそのまま使える。IAM ロール（Lambda 実行 / Cognito 認証済み / LoRaWAN 用の 3 つ）が要る手順は、次のいずれかで補う。

- **Admin を使う（実際の運用）**: ロールを作る手順（`setup.sh`・`setup-cognito.sh`・`setup-lorawan.sh role` / `profiles`）だけ `AdminAccess` で実行し、それ以外は PowerUser / ReadOnly を使う
- **管理者が IAM ロール 3 つを作る**: 実行者の権限に **この 3 ロールだけの `iam:PassRole` と `iam:GetRole`** を追加する。スクリプトは `config.org.env` の `LAMBDA_ROLE_ARN` / `COGNITO_AUTH_ROLE_ARN` / `LORAWAN_ROLE_ARN` でロールを指定する（作らない）。Cognito のロールは信頼ポリシーに Identity Pool の ID が要るため、`./setup-cognito.sh --pools-only` で Identity Pool を先に作り、表示された ID とトラストポリシーを管理者に渡す
- **ロール作成の権限を、3 ロール名に限定して付与する**: `iam:CreateRole` などをこの 3 ロール名に限定して追加し、スクリプトにロールを作らせる（Permissions Boundary 付きを想定）

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
        "cognito-idp:*",
        "cognito-identity:*",
        "iotwireless:*",
        "dynamodb:CreateTable",
        "dynamodb:DescribeTable",
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Scan",
        "dynamodb:DeleteItem",
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
  "status": "open",
  "raw": { "red": 150, "green": 820, "blue": 200, "clear": 1200 },
  "threshold": 100,
  "determinedBy": "device",
  "timestamp": "2026-06-17T12:00:00Z"
}
```

`status` の値: `full`（満）/ `open`（空）/ `unknown`（不明）

---

## 7. 端末への接続情報の反映

開発チームが自分で `./provision-device.sh <deviceId>` を実行し、出力された値を `firmware/include/secrets.h` に設定する（#6）。**端末 1 台につき 1 回**（実行のたびに証明書が増える）。

### 環境共通

| 項目 | 例 | 用途 |
|---|---|---|
| MQTT エンドポイント | `<アカウント固有>-ats.iot.ap-northeast-1.amazonaws.com`（`aws iot describe-endpoint --endpoint-type iot:Data-ATS` で確認） | ファーム `PSS_MQTT_HOST` |
| リージョン | `ap-northeast-1` | 記録用 |
| Basic Ingest のルール名 | `parking_status_telemetry` | ファーム `PSS_MQTT_BASIC_INGEST_RULE`（トピックは `$aws/rules/parking_status_telemetry/parking-status/{deviceId}/telemetry` になる） |

### 端末ごと（`deviceId` 1台につき1セット）

| 項目 | ファイル名 | 用途 |
|---|---|---|
| `deviceId` | — | Thing 名と一致 |
| デバイス証明書 | `device.pem.crt` | TLS クライアント証明書 |
| 秘密鍵 | `private.pem.key` | **厳重管理・再発行不可に注意** |
| ルート CA | `AmazonRootCA1.pem` | TLS 検証 |

証明書は `firmware/certs/`（Git 管理外）に出力され、ビルド時にファームに埋め込まれる。**エンドポイントと証明書がファームに埋め込まれるため、AWS アカウントを移すと LTE-M / Wi-Fi の端末は再書き込みが要る**（LoRaWAN 端末は MQTT を話さないので不要）。`secrets.h` の書き方は `firmware/include/secrets.example.h`、AWS 向けの env でビルドするときは TLS・LTE の有効化がビルドフラグで渡されるので、`secrets.h` に `PSS_MQTT_USE_TLS` / `PSS_LTE_ENABLED` / `PSS_LTE_ONLY` を書かない。

### 端末に入れないもの

- IAM アクセスキー / シークレット（端末接続に不要。端末は X.509 証明書で認証する）

---

## 8. 端末台数と deviceId

PoC 初期は **2〜3 現場・数台** を想定しています。

| 項目 | 方針 |
|---|---|
| `deviceId` | `xiao-{WiFi MAC 12桁}` 形式（例: `xiao-e83dc1fb05fc`） |
| Thing 名 | `deviceId` と同一 |
| 証明書 | **端末1台につき1枚**。再プロビジョニング時は旧証明書をデタッチ |

新規端末を追加するときは、`provision-device.sh <deviceId>`（または手動で同等の作業）で Thing と証明書を作り、`device-master.sh put` でデバイスマスターに駐車場名と位置を登録する（登録がないと Orion には書かれない。#7）。

---

## 9. 料金の目安

PoC 規模（3 台・15 分間隔・接続→publish→切断）では **月額 $0.01 未満**（Basic Ingest 使用時）。  
詳細: [iot-core.md §料金](iot-core.md#料金poc-規模の目安)

Lambda・CloudWatch Logs も無料枠内に収まる想定です。

---

## 10. Orion 接続（#7）

Lambda から **FIWARE Orion** へ NGSIv2 upsert する実装は #7（`bridge/`）。Orion 側の接続情報は Orion Sandbox から受け取り、`config.org.env` に書いて `deploy-bridge-stub.sh` で Lambda の環境変数に設定する。Orion の書き込みは、**公開 HTTPS で届く**ことを確認済み（Lambda を VPC に入れていない）。Orion に必要な接続情報と環境は次のとおり。

| 項目 | 内容 |
|---|---|
| Orion 接続 URL | Lambda 環境変数 `ORION_URL` |
| `Fiware-Service` / `Fiware-ServicePath` | 環境変数 `ORION_FIWARE_SERVICE` / `ORION_FIWARE_SERVICEPATH`（環境の既存パターンに合わせる） |
| 認証（Cognito） | トークンは有効期限があるため、Lambda が Orion に送るたびに Cognito User Pool へユーザー名・パスワードでログインしてトークンを取る（SRP。`USER_SRP_AUTH`。リフレッシュはしない）。次を用意して渡す: **User Pool ID・App Client ID**（クライアントシークレットがあればそれも）、**専用ユーザーのユーザー名・パスワード**（確認済み・MFA なし。Orion に書き込める最小権限）、**Orion が受け取るのが ID トークンかアクセストークンか**。App Client では `ALLOW_USER_SRP_AUTH` を有効にする。環境変数 `ORION_COGNITO_*`（`bridge/README.md` 参照）に入る |
| ネットワーク | Lambda から Orion に **公開 HTTPS で届く**前提（Lambda を VPC に入れない）。VPC 内からしか届かない場合は、Orion 用の Lambda を分けて VPC に入れる構成にする（開発チームと相談）。Lambda を VPC に入れると、同じ Lambda が呼ぶ AWS API（DynamoDB・IoT Wireless）にも NAT Gateway か VPC エンドポイントが要る |
| 実行ロールの権限 | §4.2 の `dynamodb:GetItem`（デバイスマスター）。Cognito のログインは認証前の API なので権限は要らない。パスワードを Secrets Manager 等に置く場合は、追加の権限とコード変更が要る（開発チームに連絡） |
| Lambda デプロイ | 開発チーム PR マージ後の `deploy-bridge-stub.sh` 相当 or CI/CD。環境変数は `infra/config.env`（組織用は `config.org.env`）に書いて同スクリプトで設定できる |

環境変数が空（`ORION_URL` 未設定）の間は、Lambda は Orion に送らずログ出力だけを行います。

エンティティ設計は [data-model.md](data-model.md)、実装は [`bridge/README.md`](../bridge/README.md) と #7 を参照。

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

## 12. 構築状況（2026-10-07 時点）

### 組織アカウントに構築済み（#98）

- [x] IoT ポリシー・IoT ルール 2 本・Lambda（Orion upsert 有効）・Lambda の呼び出し許可
- [x] デバイスマスター（DynamoDB）と登録（第 1 駐車場・第 2 駐車場）
- [x] Cognito（iOS ログビューア）と認証済みロール。アプリの接続先を新アカウントに変更済み
- [x] LoRaWAN: プロファイル・Destination・ロール、ゲートウェイ（M2）と Wireless Device の切り替え。LoRaWAN 端末のデータが新アカウント経由で Orion に反映される
- [x] LTE-M 用の Thing・証明書の発行と、`secrets.h` の接続先の変更（ビルド確認まで）

### 残り

- [ ] LTE-M 端末（`xiao-e83dc1fb05fc`）の再書き込みと切り替え（ロードスイッチ基板の到着待ち）
- [ ] 旧アカウント（個人）の AWS リソースの削除（LTE-M の切り替えのあと。削除は不可逆なので、一覧を確認してから）

---

## 13. 問い合わせ先---

## 13. 問い合わせ先

| 内容 | 連絡先 |
|---|---|
| AWS 環境の構築・運用、deviceId・端末台数・Lambda 実装 | 開発チーム |
| AWS アカウント・SSO 権限、Orion の接続情報 | **クラウド管理者**（AWS / Orion 兼務） |

リポジトリ: https://github.com/makeOurCity/parking-status-sensor
