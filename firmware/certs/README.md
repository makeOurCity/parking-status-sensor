# デバイス証明書（git 管理しない）

AWS IoT Core 接続用の X.509 証明書を置くディレクトリ。  
`infra/provision-device.sh` が端末ごとに生成する。

| ファイル | 内容 |
|---|---|
| `device.pem.crt` | デバイス証明書 |
| `private.pem.key` | 秘密鍵（**漏洩注意**） |
| `public.pem.key` | 公開鍵（ファームでは通常不要） |
| `AmazonRootCA1.pem` | AWS IoT ルート CA |

ローカル Mosquitto 検証時は証明書不要（`PSS_MQTT_PORT=1883`）。

AWS IoT Core 接続時は `secrets.h` でエンドポイント・トピックを設定し、  
ファームウェアの TLS 対応（#6）後にこれらの PEM を参照する。

セットアップ手順: [infra/README.md](../../infra/README.md)、[docs/iot-core.md](../../docs/iot-core.md)
