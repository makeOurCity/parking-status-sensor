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
- エンティティ ID は PoC 段階でファーム側ハードコード前提（#14）

設計: [docs/data-model.md](../docs/data-model.md)、[docs/iot-core.md](../docs/iot-core.md)

## ログ確認

```bash
aws logs tail /aws/lambda/parking-status-bridge --follow --region ap-northeast-1
```
