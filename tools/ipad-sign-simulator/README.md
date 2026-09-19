# iPad満空表示灯シミュレーター（Issue #54）

現地の実表示灯にアクセスできない環境（オフィス、デモ、センサーパッチ単体チェック）でも、カラーセンサ＋ファームウェアの一連動作を確認できるよう、iPad画面に満（赤）／空（緑）の発光面を模擬表示するアプリ。ドットパターンは実機の写真から機械的に抽出しており（下記「ドットパターンの再生成」参照）、実機と同じ16×16ドットマトリクスで「満」「空」を表示する。

対象は [README.md](../../README.md) §2.1 の「色切替型」満空表示灯。実機の物理仕様は [docs/hardware.md](../../docs/hardware.md) を参照。

## 構成

| 役割 | 内容 |
|---|---|
| アプリ | SwiftUI / iPadOS、`tools/ipad-sign-simulator/SignSimulator/` |
| プロジェクト生成 | [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`project.yml` から `.xcodeproj` を生成。生成済みのものをコミット済みなので、通常は再生成不要） |
| 配布 | なし。USB接続でXcodeから実機iPadへ直接ビルド・転送する開発用途限定 |

## ビルド・実機転送

1. `SignSimulator.xcodeproj` をXcodeで開く（`project.yml` を変更した場合のみ `xcodegen generate` で再生成）。
2. iPadをUSB接続し、Xcode左上のスキーム選択で実機を指定。
3. **Signing & Capabilities** タブで **Team** に自分のApple ID（無料アカウントで可）を設定。
4. ビルド・実行（⌘R）。初回は iPad 側で「デベロッパAppのTrust」設定が必要（設定アプリ → 一般 → VPNとデバイス管理）。
5. 無料Apple Developerアカウントは**7日間でプロビジョニングが失効**する。切れたら同じ手順で再ビルドする運用でよい（配布は行わないため許容）。

シミュレータ確認のみの場合:

```bash
xcodebuild -project SignSimulator.xcodeproj -scheme SignSimulator \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

## 操作

- **画面タップ**: 満⇔空をトグル切替（アニメーションなし・即時切替）。
- **右上の歯車アイコン**: 設定シートを開く。満／空それぞれの表示色を `ColorPicker` で変更でき、アプリ再起動後も保持される（`UserDefaults`）。「初期値に戻す」で赤／緑に戻せる。
- 画面の向きは横向き固定（`Info.plist` の `UISupportedInterfaceOrientations`）。

## ドットパターンの再生成

`SignSimulator/SignPattern.swift` の「満」「空」のビットマップは、実機を撮影した写真から `scripts/extract_pattern.py` で機械的に抽出したもの（Issue #54 案A）。より良い写真が撮れた場合の再生成手順:

1. 実機を正対して撮影し、パネルの外周でトリミングした写真を `reference/full.jpg`（満・赤）・`reference/empty.jpg`（空・緑）として保存する。
2. 依存関係をインストール（初回のみ、`scripts/.venv` は Git 管理外）:

   ```bash
   cd tools/ipad-sign-simulator/scripts
   python3 -m venv .venv
   ./.venv/bin/pip install Pillow numpy scipy
   ```

3. まずオーバーレイ画像で目視確認する（グリッドが実際のLED位置に乗っているか、緑=点灯／マゼンタ=消灯の判定が写真と一致しているか）:

   ```bash
   ./.venv/bin/python extract_pattern.py ../reference/full.png  --grid 16 --channel r --overlay /tmp/full_check.png
   ./.venv/bin/python extract_pattern.py ../reference/empty.png --grid 16 --channel g --overlay /tmp/empty_check.png
   ```

   写真の解像度や機種が変わってLED数が異なる場合は `--grid` を16以外に変えて試す。

4. 問題なければ `--dump` でSwift用のBool配列を出力し、`SignPattern.swift` の該当箇所を置き換える:

   ```bash
   ./.venv/bin/python extract_pattern.py ../reference/full.png  --grid 16 --channel r --dump
   ./.venv/bin/python extract_pattern.py ../reference/empty.png --grid 16 --channel g --dump
   ```

`--channel` は発光色に合わせて選ぶ（赤発光なら `r`、黄緑〜緑発光なら `g`）。抽出アルゴリズムの詳細はスクリプト冒頭のコメントを参照。

## 未確認事項

- 物理iPadへのUSB転送・実機での横向き固定表示は、この開発環境に物理iPadが無いため未確認。上記手順に従って実機で確認すること。
