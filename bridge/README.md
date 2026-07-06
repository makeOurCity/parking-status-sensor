# Lambda ブリッジ（Issue #7）

AWS IoT Core からルールでトリガーされ、MQTT ペイロードを FIWARE Orion へ NGSIv2 upsert する。

## 現状（Issue #4）

`handler.py` は **疎通確認用スタブ**。受信ペイロードを CloudWatch Logs に記録するだけ。  
デプロイは `infra/deploy-bridge-stub.sh`（`infra/setup.sh` から呼ばれる）。

## 本実装（Issue #7）

- `raw` → `rawSensor`、`timestamp` → `dateObserved` 等の変換
- `POST /v2/entities?options=upsert` で Orion 更新
- エンティティ ID は PoC 段階でファーム側ハードコード前提（#14）

設計: [docs/data-model.md](../docs/data-model.md)、[docs/iot-core.md](../docs/iot-core.md)

## ログ確認

```bash
aws logs tail /aws/lambda/parking-status-bridge --follow --region ap-northeast-1
```
