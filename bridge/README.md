# Lambda ブリッジ（Issue #7）

AWS IoT Core からルールでトリガーされ、MQTT ペイロードを FIWARE Orion へ NGSIv2 upsert する。

## 現状（Issue #4, #83, #7）

`handler.py` は、受信ペイロードを `parking-status telemetry received: <JSON>` で CloudWatch Logs に記録し（iOS ログビューアがこの行を読む）、続けて Orion に upsert する。Orion への送信は環境変数 `ORION_URL` を設定したときだけ有効（未設定なら `orion disabled` をログに出して何もしない）。  
デプロイは `infra/deploy-bridge-stub.sh`（`infra/setup.sh` から呼ばれる。名前は #4 のスタブ時代のまま）。zip には `handler.py` ほか `BRIDGE_MODULES` に並べたモジュールが入る（モジュールを足したら同スクリプトの `BRIDGE_MODULES` に追記）。Lambda の環境変数は `infra/config.env` から作る。

| モジュール | 内容 |
|---|---|
| `handler.py` | 入口。ログ出力 → Orion への upsert。Orion 側の失敗は例外にしない |
| `lorawan.py` | LoRaWAN の正規化（下記） |
| `ngsi.py` | テレメトリ → NGSIv2 エンティティの変換（純粋関数） |
| `cognito_auth.py` | Orion 用のトークンを Cognito User Pool から取得する（送るたびにログイン） |
| `orion.py` | Orion への `POST /v2/entities?options=upsert`（urllib。タイムアウト 5 秒、ネットワーク障害・5xx は即時リトライ 1 回、4xx は再試行しない） |
| `device_master.py` | デバイスマスター（DynamoDB）の参照とキャッシュ |

入口は 2 つ。

| 入口 | トリガー | 処理 |
|---|---|---|
| LTE-M / Wi-Fi | IoT ルール `parking_status_telemetry` | 端末の JSON をそのままログに出す |
| LoRaWAN（#40, #83） | IoT ルール `parking_status_lorawan`（トピック `lorawan/parking-status/uplink`） | `WirelessMetadata.LoRaWAN` を見て判別し、`lorawan.py` でデコード → LTE-M 版と同じ形の JSON にしてログに出す |

### `lorawan.py`

LoRaWAN の正規化。ログ出力から切り離した関数にしてあり、Orion upsert（#7）でもそのまま使う。

| 関数 | 内容 |
|---|---|
| `is_lorawan_message(event)` | Destination のメッセージか |
| `decode_uplink(message)` | `PayloadData` をデコード（fPort 1 / ver 1 / 18 バイト以外は `ValueError`） |
| `build_telemetry(message, decoded, device_id)` | LTE-M 版と同じ形の dict にする |
| `resolve_device_id(wireless_device_id)` | `iotwireless:GetWirelessDevice` で Wireless Device の `Name`（= deviceId）を引く。コンテナ内でキャッシュ |

- デコーダは [tools/lorawan/decode.py](../tools/lorawan/decode.py) の複製（Lambda の zip に `tools/` を入れないため）。`test_lorawan.py` が両者の出力を `tools/lorawan/test_vectors.json` で突き合わせる
- 生のメッセージは `lorawan uplink raw: ...` で別に出す（`telemetry received` を含めない）
- デコード失敗・Wireless Device 不明は `lorawan uplink rejected: ...` をエラーログに残して正常終了する。権限不足などの AWS エラーは例外のまま上げ、Lambda の非同期再試行に任せる
- 実行ロールには `iotwireless:GetWirelessDevice`（`WirelessDevice/*` のみ）が必要。`infra/deploy-bridge-stub.sh` が付ける

## テスト

初回だけ venv を作る（`.venv` は Git 管理外）。

```bash
cd bridge
python3 -m venv .venv
./.venv/bin/pip install pytest
./.venv/bin/python -m pytest
```

AWS と Orion には接続しない（`GetWirelessDevice`・DynamoDB・`urlopen` はモック）。

## Orion への upsert（Issue #7）

- `raw` → `rawSensor`、`timestamp` → `dateObserved` 等の変換（`ngsi.py`）。`timestamp` が無い（LoRaWAN でゲートウェイの時刻が無いなど）ときは Lambda の受信時刻
- `POST /v2/entities?options=upsert` で Orion 更新（`orion.py`）
- エンティティ ID は `deviceId` から生成する（`urn:ngsi:ParkingStatusSensor:<deviceId>`）。`name` / `location` は下記の **デバイスマスター** から引いて埋め込む（#14）
- 端末が送る値は旧値 `available` を `open` に正規化してから書く（下記「`status` の旧値」）
- Orion に送るのは [docs/data-model.md](../docs/data-model.md) のエンティティ項目だけ。診断項目（`sync.*` / `network.*` / `bootMode.*` / `pot.*`）は送らない。CloudWatch Logs には従来どおり全項目を出す
- 処理の順序は **ログ出力 → Orion への upsert**。ログを先に出し、Orion 側の失敗でログが欠けないようにする
- Orion への書き込みに失敗しても例外は投げず、エラーログ（`orion upsert failed: ...`）を残して正常終了する（例外にすると IoT ルールが Lambda を再実行し、`telemetry received` の行が重複して iOS ログビューアに二重に出る）。満空状態は最新値の上書きなので、取りこぼしても次の送信で追いつく

### Lambda の環境変数（`infra/config.env` → `deploy-bridge-stub.sh`）

| 変数 | 内容 |
|---|---|
| `ORION_URL` | Orion のベース URL。**未設定なら Orion には送らない**（ログ出力のみ） |
| `ORION_FIWARE_SERVICE` / `ORION_FIWARE_SERVICEPATH` | あれば `Fiware-Service` / `Fiware-ServicePath` ヘッダに付ける |
| `ORION_COGNITO_USER_POOL_ID` / `_CLIENT_ID` / `_USERNAME` / `_PASSWORD` | Orion のトークンは有効期限があるため、**Orion に送るたびに** Cognito User Pool にユーザー名・パスワードでログイン（SRP）してトークンを取り、`Authorization: Bearer <token>` に付ける（リフレッシュはしない）。4 つそろえて設定する（一部だけなら設定ミスとして `orion upsert failed` にする）。リージョンは User Pool ID（`ap-northeast-1_xxxxxxxxx`）の先頭から決まる。すべて空なら認証ヘッダなしで送る |
| `ORION_COGNITO_CLIENT_SECRET` / `_TOKEN_TYPE` | 省略可。クライアントシークレット付き App Client のとき（`SECRET_HASH` を付ける）／Orion が受け取るトークン（`id` か `access`。既定 `id`） |
| `DEVICE_MASTER_TABLE` | デバイスマスターの DynamoDB テーブル名（既定 `parking-status-device-master`） |

`deploy-bridge-stub.sh` は環境変数を `config.env` の内容で作り直す（空の項目は設定しない）。

### Cognito ログイン（`cognito_auth.py`）

- ログインするのは、デバイスマスターに登録済みで有効な端末を実際に Orion へ送るときだけ（スキップする端末のためにはログインしない）。1 回の送信ごとに `InitiateAuth` を 1 回呼ぶ。Orion への即時リトライはそのトークンを使い回す
- ログインは SRP（`USER_SRP_AUTH`）で、`InitiateAuth` → `RespondToAuthChallenge(PASSWORD_VERIFIER)` の 2 往復。パスワードそのものは送らない。SRP の計算は標準ライブラリだけで実装している（3072 ビットの冪剰余を使うので、Lambda 上で 1 回のログインに 0.1〜1 秒ほどかかる）。どちらも認証前に呼ぶ API なので、AWS の署名も IAM 権限も要らない
- ログインに失敗したら Orion には送らず、`orion upsert failed: cognito login failed: HTTP 400 NotAuthorizedException ...` を残して正常終了する（ユーザー名・パスワード違いは再試行しない。ネットワーク障害・5xx は即時リトライ 1 回）
- パスワードとトークンはログ・例外メッセージに出さない
- 前提（Orion 側の Cognito。管理者に確認）: App Client で `ALLOW_USER_SRP_AUTH` が有効／確認済みの専用ユーザーで MFA なし（`NEW_PASSWORD_REQUIRED` などのチャレンジには対応しない）／Orion が受け取るのが ID トークンかアクセストークンか

### デバイスマスター（#7, #14）

`name` と `location` は端末が持たず、`deviceId` をキーにした対応表（デバイスマスター）で管理する。Lambda が Orion に書く直前に引いて、エンティティへ埋め込む。端末のファームは駐車場の情報を持たない。

| 項目 | 内容 |
|---|---|
| `deviceId`（キー） | 端末の識別子。Thing 名・MQTT の `deviceId`・LoRaWAN の Wireless Device 名と同じ |
| `name` | → エンティティの `name` |
| `lat` / `lon` | → エンティティの `location`。数値で持ち、Lambda が GeoJSON（`[lon, lat]`）に組み立てる（経度・緯度の順の取り違えを防ぐ） |
| `enabled` | `false` なら Orion に書かない（一時停止・撤去済みの端末など） |

Lambda の動作:

- **未登録の `deviceId` と `enabled=false` は Orion に書かない**。警告ログ（`orion skipped: ...`）を残す。`infra/test-publish.sh` などのテスト送信が Orion にエンティティを作らないようにするため
- マスターは 5 分間キャッシュする（未登録の結果もキャッシュする）。取得に失敗したら古いキャッシュを使い、キャッシュも無ければ Orion への書き込みだけ諦める（`orion skipped: device master lookup failed: ...`。CloudWatch Logs への出力には影響させない）
- 登録内容が不正（`name` が空、`lat` / `lon` が数値でない・範囲外）のときも、同じく Orion には書かず `orion skipped` をエラーログに残す
- マスターを更新しても、Orion に反映されるのはその端末の次の送信（状態変化、または 1 時間ごとのハートビート）
- 保管先は DynamoDB（テーブル `parking-status-device-master`、`deviceId`（文字列）がパーティションキー）。テーブルは `infra/setup-device-master.sh` で作る（プロビジョンド 1 RCU / 1 WCU。DynamoDB の無料枠に収まる）。Lambda は読み取り（`dynamodb:GetItem`）のみ。編集は開発者が `infra/device-master.sh`（`put` / `list` / `get` / `delete`）かコンソールで行う
- 連絡先は持たない。必要になったら、Orion に出さない内部専用の項目として足す。`address`・`description` も必要になった時点で足す

### `status` の旧値

値は `full` / `open` / `unknown`（#99 で `available` を `open` に改名）。再書き込み前の LTE-M 端末は `available` を送り続け、CloudWatch Logs の過去ログにも残る。Orion に書くときは `open` に正規化する。LoRaWAN は無線上の値（0/1/2 の番号）が変わらないので、`lorawan.py` の変換表が `open` を返す。

### MQTT ペイロードの診断項目（`sync.*` / `network.*` / `bootMode.*`）

ファームは満空状態のほかに、送信サイクルの診断情報を MQTT ペイロードに含める（[sync-delivery-design.md](../docs/sync-delivery-design.md)）。

- `network.*`（`transport`、接続時間、`publishAttempts` 等）と `sync.*`（`prevOutcome`、`pending`、`lastConfirmedStatus` 等）は **端末の運用診断専用**
- `bootMode.*`（`active`・`slot`・`totalSlots`。#50「電源投入直後のブートモード」）も同様に **端末の運用診断専用**。電源投入(コールドブート)直後の無条件連続送信中かどうか、その何回目の送信かを示す。通常サイクルでは常に `active=false`・`slot=0`・`totalSlots=0`（詳細: [50-boot-mode-design.md](../docs/50-boot-mode-design.md)）
- `pot.*`（`enabled`・`adcRaw`。#60「現地調整用ポテンショメーター」）も同様に **端末の運用診断専用**。`enabled` はポット機能のビルド時有効/無効、`adcRaw` は平均済みの生ADC値（0〜4095）。ポット無効機体では常に `enabled=false`・`adcRaw=0` で、`threshold` は従来通りの固定値のまま（詳細: [60-potentiometer-threshold-design.md](../docs/60-potentiometer-threshold-design.md)）
- これらは **Orion（NGSIv2）エンティティにはマップしない**。bridge（#7）の変換対象外。CloudWatch Logs には従来どおり出す
- 送達確認は `network.deliveryConfirmed`（廃止済み）ではなく、**次サイクルの `sync.prevOutcome == confirmed`** と `sync.lastConfirmedBootCount` で判断する

設計: [docs/data-model.md](../docs/data-model.md)、[docs/iot-core.md](../docs/iot-core.md)

## ログ確認

```bash
aws logs tail /aws/lambda/parking-status-bridge --follow --region ap-northeast-1
```
