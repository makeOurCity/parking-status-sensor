# CloudWatch ログビューア（Issue #68）

CloudWatch Logs（Lambda `parking-status-bridge`）をサクッと確認できる iOS/iPadOS アプリ（開発者の確認用に作り、TestFlight での配布は #129）。ダッシュボードでデバイスごとの現在の Status・最終受信日時と直近5件のログを一覧し、デバイスを選ぶとそのデバイスの全ログを閲覧できる。

要件・設計の経緯は [Issue #68](https://github.com/makeOurCity/parking-status-sensor/issues/68)、認証設計の詳細は [docs/ios-app-cognito.md](../../docs/ios-app-cognito.md) を参照。

## 構成

| 役割 | 内容 |
|---|---|
| アプリ | SwiftUI / iOS 17+、`tools/log-viewer/LogViewer/` |
| プロジェクト生成 | [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`project.yml` から `.xcodeproj` を生成。生成済みのものをコミット済みなので、通常は再生成不要） |
| 認証 | Cognito User Pool（`USER_PASSWORD_AUTH` で初回サインインのみ、以降は `REFRESH_TOKEN_AUTH` で自動更新）+ Identity Pool。外部 SDK（AWS SDK for Swift / Amplify）には依存せず、`URLSession` と自前の SigV4 署名で実装 |
| データ取得 | CloudWatch Logs Insights（`StartQuery` / `GetQueryResults`）を都度クエリ。Lambda がまだスタブ（#7 未実装）のため、これが唯一のデータソース |
| 駐車場名 | デバイスマスターの DynamoDB テーブル（`parking-status-device-master`）を `Scan` で読み、`deviceId` → 駐車場名の対応表を 5 分キャッシュする（#108）。同じ Cognito 認証情報と SigV4 署名を使う。読めない・未登録のデバイスは、`deviceId` を表示する |
| 配布 | 開発者本人は Xcode から直接実行。佐賀市職員への配布は TestFlight（#129）。`main` へのマージで GitHub Actions が自動アップロードする（下記「TestFlight への自動配布」） |
| テスト | XCTest（`LogViewerTests/`）。集計の純粋関数など、画面から切り離したロジックを試験する（#132）。実行は下記「ビルド・実行」のコマンド |

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

テストの実行（同名のシミュレータが複数あるときは、名前でなく UDID（`xcrun simctl list devices`）で指定する）:

```bash
xcodebuild test -project LogViewer.xcodeproj -scheme LogViewer \
  -destination 'platform=iOS Simulator,id=<UDID>'
```

## 画面

- **サインイン**: 初回のみ。ユーザー名は `kazuki@code4japan.org` を初期値として表示。
- **ダッシュボード**: デバイス一覧（駐車場名が主表示で、`deviceId` は小さな補助表示。名称が未登録のデバイスは `deviceId` のみ。Status バッジ・最終受信の相対時刻・オフライン警告アイコン）＋ 直近5件のログ。Pull-to-refresh 対応。ヘッダーの「サインアウト」でセッションを破棄できる。
- **デバイス詳細**: 一覧からデバイスをタップすると、そのデバイスの全ログ（最大200件・直近14日間）を新しい順に表示。
- **満空タイムライン**（#132）: ダッシュボードのカードから開く。縦が日付（JST、古い日が上）、横が 0〜24 時で、デバイスごとの**満・空・不明・データなし**を 10 分マスの連続区間で表示する。期間は 14 / 30 / 60 日。マスをタップ（iPad はポインタを重ねる）すると、その区間の開始〜終了・長さ・状態を表示する。**欠落率**（データなし ÷ 全マス。設置前は除く）を、デバイスごとに見出しへ、日ごとに列の右に小さな棒で出す。
  - 駐車場名はデバイスマスターの**現在の対応**で、センサーを付け替えた機体の過去分も現在の名前で表示する。名前が未登録なら `deviceId` のみ。
  - 表示するデバイスは「デバイスマスターの全 ID ∪ ダッシュボードの機体（直近 3 日に受信）」のうち、期間内に受信が 1 件以上あるもの。**期間内に 1 件も受信が無い機体は出ない**（設置前と区別できないため）。
  - 幅が足りないとき（iPhone で 3 台以上など）は、デバイスを 1 台ずつ切り替える。
  - **自動更新はしない**（スキャン量 #77）。画面を開いたとき（前回から 60 秒以内は再取得しない）と手動更新（引っ張る／更新ボタン）だけで読む。取得は常に 60 日分で、期間の切り替えは取得済みデータの切り出し。再読み込みは前回の最終受信付近からの差分だけを取る。
  - 設置前の判定は、取得範囲（60 日）内の最初の受信による。60 日表示の冒頭に稼働中の機体が停止していると、その部分は設置前として描かれない（既知の限界）。
  - 認証なしで見た目を確認するには、DEBUG ビルドのシミュレータに起動引数 `-timelineDemo`（任意で `-timelineDemoDevices 4`、`-timelineDemoSelect 1`）を付ける。合成データを表示し、通信はしない。

### タイムラインの集計ルール

端末は「状態が変わったとき」と「約 65 分ごとの heartbeat」にしか送らないので、受信の点を面に直す（実装は `Timeline/TimelineAggregator.swift`）。

1. 時刻は Lambda の受信時刻（Logs Insights の `@timestamp`、UTC）を JST にして使う。端末の `timestamp` は未同期のことがあるので使わない。
2. 時間軸を 10 分のマスに切り、各マスの中央時点で「直近に受信した状態」をそのマスの状態にする（中央ちょうどの受信を含む）。
3. 最後の受信から 90 分（`offlineThreshold`）を**超えたら**データなし（ちょうど 90 分は有効）。
4. `available` は `open` に読み替える。
5. 同じ秒の重複は 1 件にする（ms の遅い方を残す）。
6. 欠落率 = データなしのマス ÷ 数えるマス。そのデバイスの最初の受信より前は数えず、描かない。
7. 現在時刻より先のマス（中央 > 現在）は数えず、描かない。

## TestFlight への自動配布

`main` にマージされ、`tools/log-viewer/` 配下（この README を除く）が変わると、GitHub Actions（[`.github/workflows/testflight-log-viewer.yml`](../../.github/workflows/testflight-log-viewer.yml)）が **テスト → アーカイブ → TestFlight へアップロード** を行う。手動実行（Actions タブ → Run workflow）では、アップロードする／しない（IPA の書き出しまで）を選べる。

- ビルド番号（`CFBundleVersion`）は実行時の UTC 日時（`yyMMddHHmm`、例 `2611251300`）。TestFlight は同じ番号を再アップロードできないため、実行のたびに増える値にしている。バージョン（`CFBundleShortVersionString`）は `project.yml` の `MARKETING_VERSION`。
- 署名は **App Store Connect API キーによるクラウド署名**（`xcodebuild -allowProvisioningUpdates`）。証明書とプロファイルは Apple 側で作成・更新されるので、リポジトリにも Secrets にも置かない。
- 起動は `main` への push と手動実行だけ。リポジトリが public なので、Secrets を使うこのワークフローは `pull_request` では動かさない。
- アップロード後、TestFlight 側でビルドが処理されるまで数分〜数十分かかる。外部テスターに配るには、App Store Connect の外部テストグループで「ビルドの自動配布」をオンにするか、ビルドを手動でグループに追加する。

### 準備（初回のみ）

Apple Developer / App Store Connect のアカウント管理者（CIVICTECH.TV, LLC）が用意する。**値は Secrets にだけ置き、リポジトリやチャットには書かない。**

| 種別 | 名前 | 内容 |
|---|---|---|
| Variable | `APPLE_TEAM_ID` | Apple Developer のチーム ID（10 桁。Membership 画面で確認できる） |
| Secret | `ASC_KEY_ID` | App Store Connect API キーのキー ID |
| Secret | `ASC_ISSUER_ID` | 同じく Issuer ID |
| Secret | `ASC_KEY_BASE64` | API キーの `.p8` ファイルを base64 にしたもの |

1. **API キー**: App Store Connect の「ユーザーとアクセス → 統合 → App Store Connect API」でキーを作り、`.p8` をダウンロードする（ダウンロードは一度だけ）。クラウド署名には証明書の作成権限が要るので、**アクセス権は Admin**（管理者）で作る。キー ID と Issuer ID は同じ画面に出る。
2. **登録**（`.p8` は base64 にして、パイプで直接登録する。クリップボードにも残らない）:

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_KEY_BASE64 --repo makeOurCity/parking-status-sensor
```

```bash
gh secret set ASC_KEY_ID --repo makeOurCity/parking-status-sensor
```

```bash
gh secret set ASC_ISSUER_ID --repo makeOurCity/parking-status-sensor
```

```bash
gh variable set APPLE_TEAM_ID --repo makeOurCity/parking-status-sensor
```

   `gh secret set` / `gh variable set` は値を対話入力する（コマンドラインに値を書かない）。

### 初回の確かめ方

1. Actions タブから「TestFlight (log-viewer)」を **アップロードをオフ**で手動実行する。クラウド署名とアーカイブ、IPA の書き出しまで通れば、API キーとチーム ID は正しい。
2. 次に **アップロードをオン**で手動実行し、App Store Connect の TestFlight にビルドが現れることを確かめる。
3. 以降は `main` へのマージで自動で走る。

### よくある失敗

- `未設定の Secrets / Variables: ...`: 上の表のうち、不足しているものを登録する。
- 署名の失敗（`Cloud signing permission error`、`No signing certificate`、`No profiles for ... were found` など）: API キーのアクセス権が Admin か確認する。クラウド署名は、Apple 側に管理用の配布証明書（Cloud Managed）を作る。証明書の発行数には上限があり、既にいっぱいだと新しく作れない。Apple Developer の Certificates で、不要な配布証明書を失効させてから再実行する。
- 開発用プロファイルの作成で失敗する（`no devices` など）: 自動署名がアーカイブ時に開発用プロファイルを作ろうとするため、チームに登録済みのデバイスが 1 台も無いと失敗する。Apple Developer の Devices に、確認用の iPhone / iPad を登録する。
- アップロードの失敗（重複したビルド番号など）: 同じ分にもう一度実行すると番号が被る。1 分以上あけて再実行する。
- クラウド署名がどうしても通らないときは、配布証明書（`.p12`）とプロファイルを Secrets に置く手動署名の方式に切り替えられる（その版はブランチの履歴 `a8274f4` にある）。

## オフライン判定

ハートビートは1時間間隔の強制送信のため、最終受信から **90分**（[`Config.swift`](LogViewer/Config.swift) の `AWSConfig.offlineThreshold`）経過したデバイスを「オフライン」として警告表示する。実運用での様子を見て調整する。

## 接続先を変更する場合

`infra/setup-cognito.sh` を別アカウント・別リージョンで再実行した場合は、[`LogViewer/Config.swift`](LogViewer/Config.swift) の User Pool ID / App Client ID / Identity Pool ID / ロググループ名を実際の値に置き換える。

## 関連

- [Issue #68](https://github.com/makeOurCity/parking-status-sensor/issues/68)
- [docs/ios-app-cognito.md](../../docs/ios-app-cognito.md)
- [docs/iot-core.md](../../docs/iot-core.md)
- [infra/setup-cognito.sh](../../infra/setup-cognito.sh)
