# AI エージェント向けガイド

本リポジトリ（満空灯カラーセンサ読み取り PoC）の開発運用を定義する。

## 開発フロー: GitHub Flow

- **`main`** が常に安定した基準ブランチ
- タスク管理は **GitHub Issues**（README §10 参照）
- 作業は `main` から **feature ブランチ** を切る
- 変更の取り込みは **Pull Request** 経由
- PR と Issue を関連付ける（`Closes #N` 等）

### ブランチ命名例

- `feature/11-wiring-diagram`
- `docs/update-hardware-bom`

## リポジトリ構成

| パス | 内容 |
|---|---|
| `README.md` | PoC 全体設計書 |
| `docs/hardware.md` | BOM・部品選定 |
| `docs/data-model.md` | NGSIv2 エンティティ設計 |
| `firmware/` | ESP32 ファームウェア（未作成） |
| `bridge/` | MQTT → NGSIv2 ブリッジ（未作成） |

## 作業時の注意

- 実装前に README・`docs/`・関連 Issue の内容を確認し、設計と矛盾しないこと
- 1 PR = 1 目的（無関係な変更を混ぜない）
- コミット・プッシュはユーザーが明示的に依頼したときのみ行う
- GitHub 操作は `gh` CLI を使う
- 応答言語は日本語

## Cursor 固有

Cursor 利用時は `.cursor/rules/` のルールも参照すること。
