# AWS IoT Core プロビジョニング（Issue #4）

[docs/iot-core.md](../docs/iot-core.md) の設計に沿って、IoT Core・Lambda スタブ・Cognito・LoRaWAN をセットアップするスクリプト群。

**組織 AWS への移行時**: 開発チームが直接作業しない場合は、管理者へ [docs/aws-admin-handoff.md](../docs/aws-admin-handoff.md) を渡してください。

## 前提

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- `jq`（`setup.sh` / `provision-device.sh` で使用）
- `zip`（`deploy-bridge-stub.sh` で使用）
- IAM 権限: IoT Core（Thing / Policy / Rule）、Lambda、IAM ロール作成、CloudWatch Logs

**検証アカウント**: 2026-07 時点では開発者のプライベート AWS で先行検証する（Issue #4 コメント参照）。Orion 連携は #7 で組織 Sandbox を対象とする。

## 設定（`config.env`）

- **`EXPECTED_ACCOUNT_ID`（必須）**: 実行先の AWS アカウント ID（12 桁）。クレデンシャルが指すアカウントと違えば、すべてのスクリプトが何も作らずに中断する（旧アカウントと組織アカウントの取り違え防止、#98）
- **`AWS_PROFILE`（省略可）**: 未設定なら環境変数のクレデンシャルを使う。書き込み用（Power User）と確認用（ReadOnly）を使い分けるときは、`config.env` には書かず `AWS_PROFILE=<profile> ./verify.sh` のように実行時に渡す
- **`CONFIG_FILE`（環境変数）**: 設定ファイルを切り替える（相対パスは `infra/` から）。旧アカウントと組織アカウントを並べるとき: `CONFIG_FILE=config.org.env ./setup.sh`（`config.*.env` も Git 管理外）
- **`LAMBDA_ROLE_ARN` / `COGNITO_AUTH_ROLE_ARN` / `LORAWAN_ROLE_ARN`（省略可）**: IAM ロールを管理者が用意した場合の ARN。指定するとスクリプトはロールを作らず、そのロールを使う。Power User 権限では IAM ロールの作成も PassRole もできないため（#98）。ロールの定義は [docs/aws-admin-handoff.md](../docs/aws-admin-handoff.md)

## 手順

```bash
cd infra
cp config.env.example config.env   # EXPECTED_ACCOUNT_ID・リージョン等を編集
chmod +x *.sh lib.sh

./setup.sh                         # ポリシー + Lambda スタブ + IoT ルール
./verify.sh                        # リソース確認
./provision-device.sh xiao-e83dc1fb05fc   # 端末1台分の Thing + 証明書
./test-publish.sh xiao-e83dc1fb05fc       # CLI から疎通確認
```

`provision-device.sh` は証明書を `firmware/certs/` に書き出し、`secrets.h` 用の設定値を表示する。

## スクリプト一覧

| スクリプト | 内容 |
|---|---|
| `setup.sh` | 一括セットアップ（ポリシー・ルール 2 本（端末テレメトリ / LoRaWAN）・Lambda）。何度実行しても同じ結果になる |
| `verify.sh` | セットアップ後のリソース存在確認 |
| `provision-device.sh` | Thing + 証明書を端末1台分登録 |
| `test-publish.sh` | AWS CLI からサンプルペイロードを publish |
| `deploy-bridge-stub.sh` | Lambda スタブのみデプロイ（`bridge/` のモジュールを zip 化。実行ロールの LoRaWAN 用権限 `iotwireless:GetWirelessDevice` も付与。`LAMBDA_ROLE_ARN` 指定時はロールを作らない） |
| `setup-cognito.sh` | iOS ログビューアアプリ向け Cognito User Pool / Identity Pool / IAM ロールを一括作成（[docs/ios-app-cognito.md](../docs/ios-app-cognito.md)）。`--pools-only` で Identity Pool までで止め、管理者に渡すトラストポリシーを表示する。`COGNITO_AUTH_ROLE_ARN` 指定時はロールを作らず割り当てのみ |
| `verify-cognito.sh` | Cognito セットアップ後のリソース存在確認 |
| `setup-lorawan.sh` | IoT Core for LoRaWAN の `profiles`（Service / Device Profile・Destination）、`gateway`（ゲートウェイ登録と CUPS 証明書。`--rotate` で再発行）、`device <deviceId>`（Wireless Device）。#98 |
| `verify-lorawan.sh` | LoRaWAN リソースの存在確認とゲートウェイの接続状態（読み取りのみ） |

`verify*.sh` は読み取り系の呼び出しだけなので、ReadOnly 権限のプロファイルで実行できる。

## LoRaWAN（Issue #40, #98）

[docs/40-lorawan-design.md](../docs/40-lorawan-design.md) の構成を、スクリプトで再現する。

```bash
./setup-lorawan.sh profiles                  # Service Profile / Device Profile / Destination
./setup-lorawan.sh gateway                   # ゲートウェイ登録 + cups.{uri,trust,crt,key} を gateway-certs/ に出力
LORAWAN_DEV_EUI=<16桁> LORAWAN_APP_EUI=<16桁> \
  ./setup-lorawan.sh device <deviceId>       # AppKey は対話入力（履歴に残らない）
./verify-lorawan.sh <deviceId>
```

- Destination は IAM ロール（既定 `IoTWirelessGatewayCertManagerRole`）を使う。管理者が用意すること
- **ゲートウェイ EUI は他の AWS アカウントに登録済みだと作れない**。アカウント移行では、旧アカウントでゲートウェイを削除してから `gateway` を実行する
- `gateway-certs/` は Git 管理外。`cups.key` は秘密鍵で、再ダウンロードできない（紛失したら `gateway --rotate`）
- SenseCAP M2 側の設定（ローカルコンソール > LoRa > LoRa Network）は `gateway` の実行後に表示される手順に従う

## iOS ログビューアアプリ向け Cognito（Issue #68）

```bash
cd infra
./setup-cognito.sh     # User Pool + App Client + Identity Pool + IAM ロールを作成
./verify-cognito.sh    # リソース確認
```

`config.env` の `IOS_APP_USER_EMAIL` で指定したメールアドレスを Cognito ユーザー名として、ログイン用ユーザーを1名作成する（開発者本人のみ想定）。IAM ロールは `CLOUDWATCH_LOG_GROUP_NAME` で指定したロググループの読み取り専用に限定される。詳細設計は [docs/ios-app-cognito.md](../docs/ios-app-cognito.md) を参照。

## Basic Ingest

`config.env` の `USE_BASIC_INGEST=1`（デフォルト）で、端末は次のトピックへ publish する。

```
$aws/rules/parking_status_telemetry/parking-status/{deviceId}/telemetry
```

メッセージング課金を回避できる。詳細は [docs/iot-core.md](../docs/iot-core.md)。

## 関連 Issue

- [#4](https://github.com/makeOurCity/parking-status-sensor/issues/4) 接続基盤
- [#6](https://github.com/makeOurCity/parking-status-sensor/issues/6) ファームウェア TLS 対応
- [#7](https://github.com/makeOurCity/parking-status-sensor/issues/7) Lambda 本実装
