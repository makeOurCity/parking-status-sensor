# iOS ログビューアアプリ向け Cognito 認証設計（Issue #68）

> CloudWatch Logs をサクッと確認できる iOS アプリ（開発者本人専用、Xcode から直接実行）向けの認証基盤。
> 要件の経緯は [Issue #68](https://github.com/makeOurCity/parking-status-sensor/issues/68) を参照。

## 方針

「AWS login 相当の処理を毎回やるのは面倒」を解消するため、**初回サインインのみ**行い、以降は SDK がトークンを裏で自動更新し続ける構成にする。

```
[iOS アプリ]
    │ 1. 初回のみ Cognito User Pool にサインイン（SRP 認証）
    ▼
[Cognito User Pool]  ── ID/アクセストークン + リフレッシュトークン（有効 3650 日）
    │ 2. Identity Pool にトークンを渡して一時クレデンシャルを取得
    ▼
[Cognito Identity Pool] ── IAM 一時クレデンシャルを払い出し
    │ 3. スコープを絞った IAM ロールで CloudWatch Logs を読む
    ▼
[IAM ロール（authenticated）] ── logs:* の read 系のみ、対象ロググループに限定
    │
    ▼
[CloudWatch Logs] /aws/lambda/parking-status-bridge
```

- 端末は AWS アクセスキーを一切持たない（IoT Core 側のデバイス証明書認証と同じ思想）
- リフレッシュトークンは iOS Keychain に保存し、SDK（Amplify or AWS SDK for Swift）が期限切れ前に自動更新する
- 無認証（unauthenticated）Identity Pool は採用しない。ログにデバイスの稼働状況が含まれるため、サインイン済みユーザーのみアクセス可能にする

## 作成した AWS リソース（`parking-private` アカウント）

| リソース種別 | 名前 | 備考 |
|---|---|---|
| Cognito User Pool | `parking-status-ios-app` | `AllowAdminCreateUserOnly=true`（セルフサインアップ不可） |
| App Client | `parking-status-ios-client` | シークレットなし（ネイティブアプリ用）。リフレッシュトークン有効期間 **3650 日**（Cognito の上限） |
| Cognito ユーザー | `kazuki@code4japan.org` | `admin-create-user` + `admin-set-user-password --permanent` で作成（開発者本人のみ） |
| Identity Pool | `parking_status_ios_app` | 無認証アクセス無効。認証プロバイダは上記 User Pool のみ |
| IAM ロール | `parking-status-ios-app-authenticated` | Identity Pool の authenticated ロールとして割当 |

セットアップ・再実行（冪等）は [`infra/setup-cognito.sh`](../infra/setup-cognito.sh)、確認は [`infra/verify-cognito.sh`](../infra/verify-cognito.sh) を使う。

## IAM ロールの権限（CloudWatch Logs 読み取り専用）

対象ロググループを `/aws/lambda/parking-status-bridge` に限定し、書き込み・削除系アクションは一切許可しない。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LogsReadTargetGroup",
      "Effect": "Allow",
      "Action": [
        "logs:FilterLogEvents",
        "logs:GetLogEvents",
        "logs:DescribeLogStreams",
        "logs:StartQuery"
      ],
      "Resource": "arn:aws:logs:ap-northeast-1:<account-id>:log-group:/aws/lambda/parking-status-bridge:*"
    },
    {
      "Sid": "LogsQuerySupport",
      "Effect": "Allow",
      "Action": [
        "logs:GetQueryResults",
        "logs:StopQuery",
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
    }
  ]
}
```

`logs:GetQueryResults` / `logs:StopQuery` / `logs:DescribeLogGroups` はクエリ ID・アカウント単位の API でリソースレベル制限が効かないため `Resource: "*"` としているが、`Action` はいずれも read 系のみ。

IAM ロールの信頼ポリシーは、この Identity Pool の `aud` かつ `amr=authenticated` の場合のみ `AssumeRoleWithWebIdentity` を許可する（テンプレート: [`infra/cognito-authenticated-trust-policy.json.tmpl`](../infra/cognito-authenticated-trust-policy.json.tmpl)）。

## iOS アプリ側で必要な接続情報

`infra/setup-cognito.sh` の実行結果、または `infra/verify-cognito.sh` で取得できる。

| 項目 | 用途 |
|---|---|
| Region | `ap-northeast-1` |
| User Pool ID | Cognito SDK の初期化 |
| App Client ID | Cognito SDK の初期化（クライアントシークレットなし） |
| Identity Pool ID | 一時クレデンシャル取得 |
| ログイン用ユーザー名 | `kazuki@code4japan.org`（メールをユーザー名として使用） |
| 対象ロググループ | `/aws/lambda/parking-status-bridge` |

パスワードは `setup-cognito.sh` 初回実行時に一度だけ表示される。アプリ実装時は、初回サインイン後にリフレッシュトークンを Keychain に保存し、以降はそれを使ったサイレント更新のみで運用する。

## 今後の検討事項

- 組織 AWS アカウントへ移行する場合、[`aws-admin-handoff.md`](aws-admin-handoff.md) と同様に本ドキュメントの手順を踏襲する
- Lambda 本実装（#7）で Orion 連携後、Status の取得元を Orion に切り替える場合は、IAM ロールに Orion 側の読み取り権限を追加検討する
- 複数ユーザーでの利用が必要になった場合、Cognito グループや追加ユーザー作成を検討する（現状は開発者本人のみ）

## 関連

- [docs/iot-core.md](iot-core.md)
- [docs/aws-admin-handoff.md](aws-admin-handoff.md)
- [infra/setup-cognito.sh](../infra/setup-cognito.sh)
- [infra/verify-cognito.sh](../infra/verify-cognito.sh)
- [Issue #68](https://github.com/makeOurCity/parking-status-sensor/issues/68)
