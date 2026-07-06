# AWS IoT Core プロビジョニング（Issue #4）

[docs/iot-core.md](../docs/iot-core.md) の設計に沿って、IoT Core・Lambda スタブをセットアップするスクリプト群。

**組織 AWS への移行時**: 開発チームが直接作業しない場合は、管理者へ [docs/aws-admin-handoff.md](../docs/aws-admin-handoff.md) を渡してください。

## 前提

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- `jq`（`setup.sh` / `provision-device.sh` で使用）
- `zip`（`deploy-bridge-stub.sh` で使用）
- IAM 権限: IoT Core（Thing / Policy / Rule）、Lambda、IAM ロール作成、CloudWatch Logs

**検証アカウント**: 2026-07 時点では開発者のプライベート AWS で先行検証する（Issue #4 コメント参照）。Orion 連携は #7 で組織 Sandbox を対象とする。

## 手順

```bash
cd infra
cp config.env.example config.env   # 必要ならリージョン・プロファイルを編集
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
| `setup.sh` | 一括セットアップ（ポリシー・ルール・Lambda） |
| `verify.sh` | セットアップ後のリソース存在確認 |
| `provision-device.sh` | Thing + 証明書を端末1台分登録 |
| `test-publish.sh` | AWS CLI からサンプルペイロードを publish |
| `deploy-bridge-stub.sh` | Lambda スタブのみデプロイ |

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
