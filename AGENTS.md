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
| `docs/site-inventory.md` | 現場棚卸し（Issue 作業記録・暫定） |
| `firmware/` | ESP32 ファームウェア（PlatformIO）。**XIAO ESP32S3 = PoC 試作機**。配線は `docs/wiring.md`、概要は `firmware/README.md` |
| `hardware/flame-sensor-case/` | 印刷に使っている Grove センサ用ケースの 3mf。**第三者作品（CC BY 4.0、作者 Fyrby Additive）**。変更時は帰属表示を維持（#3） |
| `bridge/` | AWS Lambda ブリッジ（IoT Core → NGSIv2 → Orion）。#4 スタブあり、#7 で本実装 |

## 作業時の注意

- 実装前に README・`docs/`・関連 Issue の内容を確認し、設計と矛盾しないこと
- 1 PR = 1 目的（無関係な変更を混ぜない）
- コミット・プッシュはユーザーが明示的に依頼したときのみ行う
- GitHub 操作は `gh` CLI を使う
- 応答言語は日本語

## ドキュメント運用（調査・棚卸しメモ）

`README.md` や `docs/hardware.md` などの**設計の正**と、Issue に紐づく**作業中の調査メモ**（例: `docs/site-inventory.md`）は扱いを分ける。

### 種類

| 種類 | 例 | 性質 |
|---|---|---|
| 設計ドキュメント | `README.md`, `hardware.md`, `wiring.md` | 確定した設計・手順。変更は慎重に |
| 作業記録ドキュメント | `site-inventory.md` 等 | Issue の進捗をリポジトリに固定するスナップショット。未完でも可 |

### 更新の流れ

1. **細かい更新**（現地確認のメモ、仮判断の変更）→ まず **Issue コメント** に書く
2. **共有したい区切り**ができたら `docs/` に反映し **PR で main に取り込む**
3. 作業記録は **Issue 単位で同じブランチ**（例: `feature/2-site-inventory`）にコミットを積み、区切りごとに PR する

### PR の頻度

- **更新のたびに PR は不要**。Issue のマイルストーン（例: 初回一覧の共有、通信確認完了、Issue クローズ前）ごとに PR を出す
- 1 PR = 1 目的（無関係な Issue の変更を混ぜない）は維持する
- `docs/` のみの作業記録更新は、コード変更よりレビュー粒度を軽くしてよい（セルフマージ可とチームで合意している場合）

### 未完成のまま main に入れてよいか

**よい**。作業記録ドキュメントは冒頭に **暫定・WIP** と明記し、未確認項目を残した状態でマージしてよい。  
「全部チェック完了」を待たず、**現時点で共有したい事実**を早めに main に載せる。

### Issue のクローズ条件

棚卸し・調査系 Issue は、全チェック項目が OK でなくてもよい。  
**各候補の PoC 対象可否が判断できる状態**（または対象外と理由が確定した状態）でクローズする。

## Cursor 固有

Cursor 利用時は `.cursor/rules/` のルールも参照すること。
