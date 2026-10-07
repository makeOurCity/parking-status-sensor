# CloudWatch ログビューア（Issue #68）

CloudWatch Logs（Lambda `parking-status-bridge`）をサクッと確認できる、開発者本人専用の iOS/iPadOS アプリ。ダッシュボードでデバイスごとの現在の Status・最終受信日時と直近5件のログを一覧し、デバイスを選ぶとそのデバイスの全ログを閲覧できる。

要件・設計の経緯は [Issue #68](https://github.com/makeOurCity/parking-status-sensor/issues/68)、認証設計の詳細は [docs/ios-app-cognito.md](../../docs/ios-app-cognito.md) を参照。

## 構成

| 役割 | 内容 |
|---|---|
| アプリ | SwiftUI / iOS 17+、`tools/log-viewer/LogViewer/` |
| プロジェクト生成 | [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`project.yml` から `.xcodeproj` を生成。生成済みのものをコミット済みなので、通常は再生成不要） |
| 認証 | Cognito User Pool（`USER_PASSWORD_AUTH` で初回サインインのみ、以降は `REFRESH_TOKEN_AUTH` で自動更新）+ Identity Pool。外部 SDK（AWS SDK for Swift / Amplify）には依存せず、`URLSession` と自前の SigV4 署名で実装 |
| データ取得 | CloudWatch Logs Insights（`StartQuery` / `GetQueryResults`）を都度クエリ。Lambda がまだスタブ（#7 未実装）のため、これが唯一のデータソース |
| 駐車場名 | デバイスマスターの DynamoDB テーブル（`parking-status-device-master`）を `Scan` で読み、`deviceId` → 駐車場名の対応表を 5 分キャッシュする（#108）。同じ Cognito 認証情報と SigV4 署名を使う。読めない・未登録のデバイスは、`deviceId` を表示する |
| 配布 | なし。開発者本人が Xcode から直接実行する運用限定 |

## ビルド・実行

1. `LogViewer.xcodeproj` を Xcode で開く（`project.yml` を変更した場合のみ `xcodegen generate` で再生成）。
2. シミュレータまたは実機を選んでビルド・実行（⌘R）。
3. 初回起動時のみ、Cognito ユーザー（`kazuki@code4japan.org`）のパスワードでサインインする。パスワードは `infra/setup-cognito.sh` の初回実行時に一度だけ表示されたもの（パスワードマネージャーに保管）。
4. 2回目以降は Keychain に保存したリフレッシュトークンで自動サインインする。

コマンドラインからのビルド確認:

```bash
xcodebuild -project LogViewer.xcodeproj -scheme LogViewer \
  -destination 'generic/platform=iOS Simulator' build
```

## 画面

- **サインイン**: 初回のみ。ユーザー名は `kazuki@code4japan.org` を初期値として表示。
- **ダッシュボード**: デバイス一覧（駐車場名が主表示で、`deviceId` は小さな補助表示。名称が未登録のデバイスは `deviceId` のみ。Status バッジ・最終受信の相対時刻・オフライン警告アイコン）＋ 直近5件のログ。Pull-to-refresh 対応。ヘッダーの「サインアウト」でセッションを破棄できる。
- **デバイス詳細**: 一覧からデバイスをタップすると、そのデバイスの全ログ（最大200件・直近14日間）を新しい順に表示。

## オフライン判定

ハートビートは1時間間隔の強制送信のため、最終受信から **90分**（[`Config.swift`](LogViewer/Config.swift) の `AWSConfig.offlineThreshold`）経過したデバイスを「オフライン」として警告表示する。実運用での様子を見て調整する。

## 接続先を変更する場合

`infra/setup-cognito.sh` を別アカウント・別リージョンで再実行した場合は、[`LogViewer/Config.swift`](LogViewer/Config.swift) の User Pool ID / App Client ID / Identity Pool ID / ロググループ名を実際の値に置き換える。

## 関連

- [Issue #68](https://github.com/makeOurCity/parking-status-sensor/issues/68)
- [docs/ios-app-cognito.md](../../docs/ios-app-cognito.md)
- [docs/iot-core.md](../../docs/iot-core.md)
- [infra/setup-cognito.sh](../../infra/setup-cognito.sh)
