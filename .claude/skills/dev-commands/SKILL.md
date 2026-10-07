---
name: dev-commands
description: parking-status-sensor リポジトリでよく使う開発コマンドのリファレンス。PlatformIOでのファームウェア ビルド/書き込み/シリアル監視、ローカルMosquittoでのMQTT動作確認、AWS IoT Core/Lambdaブリッジのプロビジョニング・検証、SORACOM SIMの状態確認・データ使用量調査、消費電力ロガーでの計測を行いたいときに使う。「ビルドして」「書き込んで」「モニタして」「SIMの状態確認して」「電力ログ取って」等の依頼で発火する。
---

# 開発コマンド リファレンス

コマンドの一覧のみを持つ。設計・背景は各リンク先のドキュメントを参照すること。

## 1. ファームウェア（PlatformIO）

作業ディレクトリ: `firmware/`。初回のみ `include/secrets.example.h` を `secrets.h` にコピーして編集（git管理外）。

詳細: [firmware/README.md](../../../firmware/README.md)、配線: [docs/wiring.md](../../../docs/wiring.md)

```bash
cd firmware
pio run -e <env> -t upload
pio device monitor -e <env>
```

| env | 用途 |
|---|---|
| `xiao-s3` | 本番相当。Wi-Fi + Deep Sleep（ローカルMosquitto向け） |
| `xiao-s3-debug` | 開発用。Deep Sleepなし、短間隔で連続送信 |
| `xiao-s3-lte-test` | LTE-Mモジュール単体の疎通確認（センサー/MQTT不使用） |
| `xiao-s3-lte-poweroff-test` | モデム poweroff/復帰のみ検証（#25 Phase 0） |
| `xiao-s3-lorawan` | #40 Grove Wio-E5 の LoRaWAN 版（状態変化時のみ送信 + heartbeat） |
| `xiao-s3-lorawan-pot` | 上記 + ポテンショメーター（#60） |
| `xiao-s3-lorawan-debug` | LoRaWAN版 + Deep Sleepなし |
| `xiao-s3-lorawan-test` | Grove Wio-E5 の AT 疎通確認・Join・1パケット送信（`~p`/`~c`/`~j`/`~s`、#40） |
| `xiao-s3-aws` | AWS IoT Core向け（Wi-Fi、TLS） |
| `xiao-s3-aws-debug` | 上記 + Deep Sleepなし |
| `xiao-s3-aws-lte` | AWS IoT Core + LTE-M・リレーなし（毎サイクル送信）。ベンチ・通信パイプライン検証用 |
| `xiao-s3-aws-lte-debug` | 上記 + Deep Sleepなし（開発） |
| `xiao-s3-aws-lte-relay` | #46 Grove 2-Coilラッチングリレーで LTE-M 電源を物理遮断する版（ポテンショメーターなし） |
| `xiao-s3-aws-lte-relay-debug` | 上記のベンチ検証用。Deep Sleep無効化 |
| `xiao-s3-aws-lte-relay-pot` | **LTE-M 版の本番機**（リレー・状態変化時のみ送信・ポテンショメーター。`firmware/README.md` と同じ位置づけ） |

poweroff-test はログを power-logger のログディレクトリへ保存する運用:

```bash
pio device monitor -e xiao-s3-lte-poweroff-test | tee ../tools/power-logger/phase0-poweroff-test.log
```

## 2. ローカル Mosquitto 検証（#6）

作業ディレクトリ: リポジトリルート。`secrets.h` の `PSS_MQTT_HOST` は Mosquitto を動かす Mac の LAN IP。

詳細: [firmware/README.md #ローカルMosquitto検証](../../../firmware/README.md)

```bash
# ターミナル1: ブローカー起動
tools/mosquitto/start.sh

# ターミナル2: 受信ログ（JSONL蓄積）
tools/mosquitto/subscribe.sh <Macの LAN IP>

# 受信そのものをその場で見る場合
tools/mosquitto/watch.sh <Macの LAN IP>

# もしくは直接
mosquitto_sub -h <LAN IP> -t 'parking-status/#' -F '%I %t %p'
```

欠番検出・整形は `tools/mosquitto/detect_gaps.py`、`tools/mosquitto/format_telemetry.py` を使う。

## 3. AWS IoT Core / Lambda ブリッジ / LoRaWAN（#4, #7, #98）

作業ディレクトリ: `infra/`。前提: AWS CLI v2（SSO のプロファイルを設定済み）、`jq`、`zip`。

詳細: [infra/README.md](../../../infra/README.md)、[docs/aws-admin-handoff.md](../../../docs/aws-admin-handoff.md)、[bridge/README.md](../../../bridge/README.md)

環境は **組織の AWS アカウント（現在）** と、個人アカウント（移行元。LTE-M 端末の切り替えまで残る）の 2 つ。設定ファイルを `CONFIG_FILE` で切り替え（組織: `config.org.env`、個人: `config.env`。どちらも Git 管理外）、`EXPECTED_ACCOUNT_ID` が実際のアカウントと違えばスクリプトは何も作らずに中断する。`AWS_PROFILE` は設定ファイルに書かず、実行時に渡す。**確認は ReadOnly、通常の作成は PowerUser、IAM ロールを作る手順だけ Admin**。

```bash
cd infra
cp config.env.example config.org.env   # 初回のみ。EXPECTED_ACCOUNT_ID などを設定
chmod +x *.sh lib.sh                   # 初回のみ
export CONFIG_FILE=config.org.env
aws sso login --sso-session <セッション名>

# IAM ロールを作る手順は Admin
AWS_PROFILE=<Admin> ./setup.sh                      # IoT ポリシー + デバイスマスター + Lambda（と実行ロール）+ IoT ルール
AWS_PROFILE=<Admin> ./setup-cognito.sh              # iOS ログビューア用の Cognito と認証済みロール
AWS_PROFILE=<Admin> ./setup-lorawan.sh role         # LoRaWAN 用 IAM ロール
AWS_PROFILE=<Admin> ./deploy-bridge-stub.sh         # Lambda の再デプロイ（Orion の設定を反映。パスワードは端末で入力）

# 確認は ReadOnly
AWS_PROFILE=<ReadOnly> ./verify.sh                  # IoT Core / Lambda / デバイスマスター / Orion 設定の確認
AWS_PROFILE=<ReadOnly> ./verify-cognito.sh
AWS_PROFILE=<ReadOnly> ./verify-lorawan.sh [deviceId ...]   # ゲートウェイの接続状態も表示

# 作成・登録は PowerUser
AWS_PROFILE=<PowerUser> ./provision-device.sh <deviceId>    # 端末1台分の Thing + 証明書（firmware/certs/ に出力）
AWS_PROFILE=<PowerUser> ./device-master.sh put <deviceId> <名称> <緯度> <経度>   # デバイスマスターに登録（list / get / delete もある）
AWS_PROFILE=<PowerUser> ./setup-lorawan.sh profiles         # Service / Device Profile と Destination（Destination は Admin）
AWS_PROFILE=<PowerUser> ./setup-lorawan.sh gateway          # ゲートウェイ登録と CUPS 証明書
AWS_PROFILE=<PowerUser> ./test-publish.sh xiao-test-device  # 疎通確認（テスト用の deviceId で）
```

- **Orion が有効な間は、実機の `deviceId` で `test-publish.sh` を実行しない**（デバイスマスターに登録済みの ID は実データのエンティティを上書きする。未登録の ID は Orion にスキップされる）
- LoRaWAN のゲートウェイ EUI と DevEui は、他のアカウントに登録されていると作れない（アカウントを移すときは旧アカウント側を先に削除する。手順は #98 の Issue コメント）
- iOS ログビューアの接続先は `tools/log-viewer/LogViewer/Config.swift`

Lambdaのログ確認:

```bash
AWS_PROFILE=<ReadOnly> aws logs tail /aws/lambda/parking-status-bridge --follow --region ap-northeast-1
```

## 4. SORACOM SIM 運用（#35）

作業ディレクトリ: リポジトリルート。前提: `soracom-cli`（`brew install soracom-cli`）、`jq`。初回のみ `soracom configure`。

詳細: [tools/soracom/README.md](../../../tools/soracom/README.md)

```bash
# 全SIM一覧（CSV: simId, name, site, device-id, status, sessionOnline）
tools/soracom/sim-status.sh

# 1 SIM詳細（sessionStatus.online含む）
tools/soracom/sim-status.sh <sim-id>

# データ使用量（当月）
tools/soracom/data-usage.sh <sim-id>

# データ使用量（直近N日）
tools/soracom/data-usage.sh <sim-id> --days 7

# セッション強制切断（LTEデバッグ時。onlineのSIMのみ成功）
tools/soracom/delete-session.sh <sim-id>
```

## 5. 消費電力ロガー（#31）

作業ディレクトリ: `tools/power-logger/`。ロガー側（ESP32 DevKit + U200-1A + OLED）のPlatformIO操作。

詳細: [tools/power-logger/README.md](../../../tools/power-logger/README.md)、[docs/power-measurement.md](../../../docs/power-measurement.md)

```bash
cd tools/power-logger
pio run -e logger-devkit
pio run -e logger-devkit -t upload --upload-port /dev/cu.usbserial-XXXX

# 計測（シリアル出力をCSVへ）
pio device monitor -e logger-devkit --port /dev/cu.usbserial-XXXX > capture.csv

# mAh積算（ホスト側）
python3 integrate_mah.py capture.csv
```
