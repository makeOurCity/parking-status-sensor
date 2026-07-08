# SORACOM CLI（PoC 運用ツール）

LTE-M 経路（SIM7080G + SORACOM IoT SIM）の SIM 状態確認・通信量監視を、
ユーザーコンソールを開かずに行うためのスクリプト群。

関連 Issue: [#35](https://github.com/makeOurCity/parking-status-sensor/issues/35)

## インストール（macOS）

Homebrew 2.10+ では tap の信頼が必要:

```bash
brew tap soracom/soracom-cli
brew trust soracom/soracom-cli
brew install soracom-cli
soracom version
```

Linux / Windows は [GitHub Releases](https://github.com/soracom/soracom-cli/releases) からバイナリを取得。

## 初回設定（各開発者マシンで1回）

```bash
soracom configure
```

| プロンプト | PoC での選択 |
|---|---|
| Coverage | **2 (Japan)** — plan-D / plan-KM1 |
| 認証 | **1 (AuthKey)** 推奨（パスワード変更の影響を受けない） |

AuthKey は [ユーザーコンソール → アカウント → AuthKeys](https://users.soracom.io/) から作成。
設定ファイルは `~/.soracom/default.json` に平文保存される。**リポジトリにコミットしない。**

複数アカウントや SAM ユーザー切り替え:

```bash
soracom configure --profile poc-dev
export SORACOM_PROFILE=poc-dev   # スクリプトは未使用（soracom 本体が参照）
```

## SIM タグ命名規則（PoC）

Orion エンティティ ID マッピング（#14）と揃える。

| タグキー | 例 | 用途 |
|---|---|---|
| `name` | `parking-sensor-lab-01` | コンソール表示名（SORACOM 標準） |
| `site` | `site-inventory-a` | 現場 ID（`docs/site-inventory.md` と一致） |
| `device-id` | `xiao-e83dc1fb05fc` | MQTT client ID / 端末識別子 |
| `firmware-env` | `dev` / `field` | 試作机 vs 現場機 |

タグ付け例:

```bash
soracom sims put-tags --sim-id <SIM_ID> --tags '{"name":"parking-sensor-lab-01","site":"lab","device-id":"xiao-e83dc1fb05fc","firmware-env":"dev"}'
```

## スクリプト

前提: `jq`（`brew install jq`）

### SIM 一覧・セッション状態

```bash
# 全 SIM（CSV: simId, name, site, device-id, status, sessionOnline）
tools/soracom/sim-status.sh

# 1 SIM 詳細（sessionStatus.online 含む）
tools/soracom/sim-status.sh 8942310012345678901
```

### データ使用量

```bash
# 当月（month 集計）
tools/soracom/data-usage.sh 8942310012345678901

# 直近 7 日（day 集計）
tools/soracom/data-usage.sh 8942310012345678901 --days 7
```

### セッション強制切断（LTE デバッグ）

モデム側と SIM 側のセッションが詰まった疑いがあるとき。
**online の SIM のみ**成功する（offline は `SEM0016`）。

```bash
tools/soracom/delete-session.sh 8942310012345678901
```

## LTE トラブルシュート早見表

ファームウェアのシリアルログと SIM 側状態を突き合わせる。

| シリアルログ | 確認する SIM 側 | CLI |
|---|---|---|
| `FAIL: not registered` | SIM が active か、圏内か | `sim-status.sh <sim-id>` → `status`, `sessionOnline` |
| `FAIL: GPRS attach failed` | APN 設定（plan-D は `soracom.io`） | コンソールまたはグループ設定。CLI は `soracom sims get` |
| attach 成功だが MQTT 長時間 | セッション詰まり | `delete-session.sh` → 端末リセット |
| 通信はするが受信間隔が異常 | データ使用量・セッション履歴 | `data-usage.sh`, `soracom sims session-events --sim-id ...` |

詳細な active 時間調査: [docs/lte-active-investigation.md](../../docs/lte-active-investigation.md)

## 参考

- [SORACOM CLI 利用ガイド](https://users.soracom.io/ja-jp/tools/cli/)
- [Soracom CLI Getting Started](https://developers.soracom.io/en/start/soracom/soracom-cli-guide)
- [soracom/soracom-cli](https://github.com/soracom/soracom-cli)
