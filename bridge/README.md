# Lambda ブリッジ（Issue #7）

AWS IoT Core からルールでトリガーされ、MQTT ペイロードを FIWARE Orion へ NGSIv2 upsert する。

## 現状（Issue #4, #83）

`handler.py` は **疎通確認用スタブ**。受信ペイロードを `parking-status telemetry received: <JSON>` で CloudWatch Logs に記録するだけ（iOS ログビューアがこの行を読む）。  
デプロイは `infra/deploy-bridge-stub.sh`（`infra/setup.sh` から呼ばれる）。zip には `handler.py` と `lorawan.py` が入る（モジュールを足したら同スクリプトの `BRIDGE_MODULES` に追記）。

入口は 2 つ。

| 入口 | トリガー | 処理 |
|---|---|---|
| LTE-M / Wi-Fi | IoT ルール `parking_status_telemetry` | 端末の JSON をそのままログに出す |
| LoRaWAN（#40, #83） | IoT ルール `parking_status_lorawan`（トピック `lorawan/parking-status/uplink`） | `WirelessMetadata.LoRaWAN` を見て判別し、`lorawan.py` でデコード → LTE-M 版と同じ形の JSON にしてログに出す |

### `lorawan.py`

LoRaWAN の正規化。ログ出力から切り離した関数にしてあり、#7（Orion upsert）でもそのまま使う。

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

AWS には接続しない（`GetWirelessDevice` はモック）。

## 本実装（Issue #7）

- `raw` → `rawSensor`、`timestamp` → `dateObserved` 等の変換
- `POST /v2/entities?options=upsert` で Orion 更新
- エンティティ ID は `deviceId` から生成する（`urn:ngsi:ParkingStatusSensor:<deviceId>`）。`name` / `location` は下記の **デバイスマスター** から引いて埋め込む（#14）
- 端末が送る値は旧値 `available` を `open` に正規化してから書く（下記「`status` の旧値」）
- Orion に送るのは [docs/data-model.md](../docs/data-model.md) のエンティティ項目だけ。診断項目（`sync.*` / `network.*` / `bootMode.*` / `pot.*`）は送らない。CloudWatch Logs には従来どおり全項目を出す
- Orion への書き込みに失敗しても例外は投げず、エラーログ（`orion upsert failed: ...`）を残して正常終了する（例外にすると IoT ルールが Lambda を再実行し、`telemetry received` の行が重複して iOS ログビューアに二重に出る）。満空状態は最新値の上書きなので、取りこぼしても次の送信で追いつく

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
- マスターは数分キャッシュする。取得に失敗したら古いキャッシュを使い、キャッシュも無ければ Orion への書き込みだけ諦める（CloudWatch Logs への出力には影響させない）
- マスターを更新しても、Orion に反映されるのはその端末の次の送信（状態変化、または 1 時間ごとのハートビート）
- 保管先は暫定で DynamoDB（テーブル `parking-status-device-master`、`deviceId` がパーティションキー）。Lambda は読み取りのみ、編集は開発者がコンソールか CLI で行う。保管先は #7 で確定する
- 連絡先は持たない。必要になったら、Orion に出さない内部専用の項目として足す。`address`・`description` も必要になった時点で足す

### `status` の旧値

値は `full` / `open` / `unknown`（#99 で `available` を `open` に改名）。再書き込み前の LTE-M 端末は `available` を送り続け、CloudWatch Logs の過去ログにも残る。Orion に書くときは `open` に正規化する。LoRaWAN は無線上の値（0/1/2 の番号）が変わらないので、`lorawan.py` の変換表が `open` を返す。

設計: [docs/data-model.md](../docs/data-model.md)、[docs/iot-core.md](../docs/iot-core.md)

## ログ確認

```bash
aws logs tail /aws/lambda/parking-status-bridge --follow --region ap-northeast-1
```
