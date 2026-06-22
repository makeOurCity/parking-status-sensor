# ハードウェア設計・部品選定

Issue #1 での検討結果をまとめたドキュメント。

**試作1台（Wi-Fi 第1弾・Issue #11）**: [bom.md](bom.md) / [schematic.md](schematic.md) / [wiring.md](wiring.md)

### 開発ベンチと PoC 実証機

| 用途 | ボード | ドキュメント |
|---|---|---|
| 開発ベンチ（センサ・MQTT の先行検証） | ESP32 DevKit | [firmware/devkit-bench.md](../firmware/devkit-bench.md) |
| PoC 実証機（現場設置） | Seeed XIAO ESP32S3 + Grove Shield | 本ドキュメント・bom / wiring / schematic |

ファームウェアは PlatformIO のマルチ環境（`devkit` / `xiao-s3`）で 1 ツリー管理する。BOM・配線図の**正**は XIAO 実証機向けのままとし、DevKit 用の詳細配線は firmware README に限定する。

---

## 確定BOM（試作1台分）

| 部品 | 型番 | 入手先 | 価格 |
|---|---|---|---|
| マイコン | Seeed XIAO ESP32S3（無印） | [秋月電子](https://akizukidenshi.com/catalog/g/gM-18078/) | ¥1,480 |
| Grove Shield | Grove Shield for XIAO（103020312） | [Seeed JP](https://jp.seeedstudio.com/Grove-Shield-for-Seeeduino-XIAO-p-4621.html) 等 | 約¥700 |
| カラーセンサ | TCS34725 モジュール | [ストロベリーリナックス](https://strawberry-linux.com/catalog/items?code=13472) | ¥924 |
| Grove L字コネクタ | 2mm ピッチ 4ピン | Seeed / Amazon 等 | 約¥100〜200 |
| Grove 4芯ケーブル | 50〜100cm（現場ごとに選択） | Seeed / Amazon 等 | 約¥200〜400 |
| LTE-Mモジュール | M5Stack SIM7080G CAT-M Unit（M5STACK-U128） | [スイッチサイエンス](https://www.switch-science.com/products/11052) | ¥6,908 |
| SIM | SORACOM IoT SIM plan-D / plan-KM1 | [SORACOMストア](https://soracom.jp/store/13380/) | ¥990初期 + ¥192/月〜 |
| バッテリー | LiPo 3.7V 4,400mAh 保護回路内蔵 JST-PH | [ストロベリーリナックス](https://strawberry-linux.com/catalog/items?code=15095) | ¥550 |
| 電解コンデンサ | 470μF 16V（16WXA470MEFC8X9） | [秋月電子](https://akizukidenshi.com/catalog/g/g108426/) | ¥10〜 |
| 防水ケース | IP65以上の樹脂ケース | Amazon / モノタロウ | ¥500〜1,500 |
| 固定材料 | 透明テープ・黒カッティングシート・結束バンド | ホームセンター / 100均 | ¥300〜500 |
| ケーブルグランド | M12またはM16（2〜3個） | Amazon / モノタロウ | ¥100〜300 |

**試作1台 合計: 約¥14,000〜15,000**（SIM初期費用込み・LTE-M モジュール含む全体設計見積。Wi-Fi 第1弾のみの調達は [bom.md](bom.md) 参照）

---

## 部品選定の経緯

### カラーセンサ：TCS34725 を採用

**検討した代替品：**

| センサ | 価格 | 秋月在庫 | 評価 |
|---|---|---|---|
| TCS34725 | ¥924 | 販売終了 | 採用 |
| APDS-9960 | ¥600 | 669個 | 不採用 |
| S13683-03DT | ¥350 | 1,345個 | 不採用（チップ単品） |
| AS7341 | ¥3,350 | 94個 | オーバースペック |

**TCS34725を選んだ理由：**
PoCの核心は「赤と緑を現場の光条件で安定して判別できるか」の検証。センサ起因の不確実性をPoC前に排除するため、汎用センサではなく色センシング専用設計の TCS34725 を採用する。

- **IRカットフィルタ内蔵**: LED満空灯が発するIR成分を除去し、RGBチャンネルの測定精度を確保
- **色判別に最適化された分光特性**: APDS-9960（ジェスチャー/近接センサが主機能）より赤緑の分離が良い
- **自発光対象への適合**: 白色LEDは消灯、表示灯の光をそのまま読む運用が設計どおり

**APDS-9960を採用しなかった理由：**
入手性（秋月在庫669個）とライブラリ成熟度は優れるが、ジェスチャー/近接センサが主機能の複合チップであり、RGBチャンネルは画面輝度調整向けに設計されている。RとGの応答が重複しやすく、判別できなかった場合に「センサの問題か現場光条件の問題か」が切り分けられなくなるリスクがある。

**調達先について：**
秋月電子では販売終了。ストロベリーリナックスでのみ即納確認済み（¥924、2026年6月17日時点）。

---

### 接続方式：Grove 統一接続

ジャンパ線・デュポン延長ケーブルではなく、**Grove 規格でセンサ〜本体を接続**する。

**構成**

1. TCS34725 基板に **Grove L字コネクタ**（2mm ピッチ 4ピン）をはんだ付け
2. **Grove 4芯ケーブル**（50〜100cm、現場ごとに長さ選択）の TCS34725 側コネクタのみ **ピン入替**
3. **Grove Shield for XIAO** の I2C ポートにそのまま挿す（Shield 側は変更不要）

**TCS34725 側のピン入替**（コネクタハウジングからピンを抜いて差し替え。工具不要・ハンダ不要）:

| Grove ケーブル標準 | 信号 | TCS34725 基板ピン |
|---|---|---|
| ピン1: 黄 | SCL | 3: SCL |
| ピン2: 白 | SDA | 2: SDA |
| ピン3: 赤 | VCC | 4: VDD |
| ピン4: 黒 | GND | 1: GND |

詳細手順は [wiring.md](wiring.md) を参照。

---

### バッテリー：LiPo電池（4,400mAh）を採用

**当初案（不採用）：cheero Canvas IoT機器対応モバイルバッテリー**

モバイルバッテリーには2つの根本的な問題がある：

1. **オートパワーオフ**: IP5306チップ搭載品は45mA以下の負荷が32秒継続すると自動オフ。ESP32のDeep Sleep電流（数十μA）で給電が切れる。
   - 出典: [DONE.LAND「IP5306」](https://done.land/components/power/powersupplies/battery/chargers/charge-discharge/ip5306/)（完全一致）

2. **パススルー時の瞬断**: 外部電源（充電）からバッテリー給電への切替時に出力が瞬断する。「IoT機器向け」を謳う製品でも解消されていない。Philips DLP6712Nでの実測値は約30ms。
   - 出典: [おばかさんよね。](https://obakasanyo.net/off-grid-usb-iot/)（部分一致）
   - 出典: [じわじわ進む](https://jiwashin.blogspot.com/2019/09/pass-through-mobile-battery-for-iot.html)（完全一致・30ms実測）

ESP32のBrownout検出電圧しきい値は2.43〜2.80V。瞬断がこのしきい値を超えるとリセットが発生し、RTCメモリが消失する。
- 出典: [Espressif公式FAQ](https://docs.espressif.com/projects/esp-faq/en/latest/software-framework/system.html)（完全一致）

**LiPoを採用した理由：**
- Grove Shield for XIAO に BAT パッドと充電管理があり、LiPo を JST で抜き差し可能
- オートパワーオフが構造的に発生しない
- パススルー瞬断が発生しない（LiPoから直接給電）
- USB-C 経由（XIAO 経由）でそのまま充電可能

**接続先（確定）**

- XIAO ESP32-S3 本体には **JST コネクタは非搭載**（BAT パッドのみ）
- **Grove Shield の BAT パッド**に JST PH 2.0mm メスコネクタ付きケーブルをはんだ付け
- 手元の LiPo 4,400mAh（JST PH 2.0mm）を抜き差し
- **はんだ付け前にテスターで極性（＋−）を必ず確認**

**注意点（要確認）：**
LiPo単体運用時（USB非接続）に5V系統が有効かどうか要確認。LTE-Mモジュール（M5STACK-U128）が5V入力を必要とする場合、昇圧回路（3.7V→5V）の追加が必要になる可能性がある。

**稼働日数の試算（LiPo 4,400mAh・実効率90%・実効3,960mAh）：**

| 条件 | 稼働日数 |
|---|---|
| 5分間隔・Wi-Fi | 約74日 |
| 15分間隔・Wi-Fi | 約220日 |
| 5分間隔・LTE-M | 約37日 |
| **15分間隔・LTE-M（推奨）** | **約100日** |

LTE-M本命運用では15分間隔を推奨。満空情報は秒単位の即時性が不要なためPoC要件（約1ヶ月）を十分に満たす。

---

### 通信：LTE-M（型番確定）・Wi-Fi 第1弾

**PoC 第1弾は Wi-Fi のみ。** LTE-M は型番を確定したうえで、Wi-Fi が使えない現場が出た時点で追加購入する。

**LTE-Mモジュール：M5Stack SIM7080G CAT-M Unit（M5STACK-U128）**

- SIM7080G（SIMCom）搭載。LTE Cat-M1 / NB-IoTデュアルモード
- **Grove 互換コネクタ（UART）付き** … Grove Shield for XIAO の UART ポートにケーブル1本
- SMAアンテナ付属
- 技適取得済み（TELEC / JATE / ドコモ / ソフトバンク / KDDI）
- `TinyGSM` + `PubSubClient` で MQTT 送信まで実績多数
- 在庫56個・¥6,908（2026年6月17日・スイッチサイエンス確認済み）

**接続（LTE-M 導入時）**

```
Grove Shield UART  ← Grove 4芯ケーブル →  M5STACK-U128
（Shield 側は標準ピン配置のまま）
```

**SIM：SORACOM IoT SIM**

- **plan-D**（NTTドコモ回線・LTE Cat-M1）… 動作確認済み
- **plan-KM1**（KDDI回線）… 動作確認済み
- 初期費用: ¥990 / 月額: ¥192〜
- 送信量はペイロード数百バイト×15分間隔で月間数MB以下。500MBバンドルで十分
- APN: `soracom.io` / User: `sora` / Pass: `sora`

---

## 物理部品の詳細

### 防水ケース
- **用途**: XIAO + Grove Shield・LiPo・（将来）LTE-Mモジュールを収納・屋外保護
- **スペック**: IP65以上
- **サイズ**: LiPo 4,400mAhの実寸を確認してから選定（部品届いたら実測すること）
- **候補**: タカチ電機工業 SW型 / Amazon汎用IP65ジャンクションボックス

### センサパッチの固定（黒シート積層方式）

- **対象満空灯**: 385×391mm・透明アクリルカバー・額縁で縁を覆う構造
- **固定**: 透明テープで発光面全体を固定（落下リスクゼロが安全上最重要）
- **遮光**: 黒カッティングシートをテープとセンサの間に積層。受光窓を切り抜く
- **受光位置**: 画像分析により **下から2行目・左から2列目** 付近を推奨
- **脱着**: テープを剥がすだけ（仮設 PoC 向け）
- **不採用**: 縁クリップ（構造上不可）、吸盤（落下リスク）、塩ビパイプ遮光フード＋マジックテープ（旧案）

### ケーブルグランド
- **用途**: 防水ケースへの配線貫通部の防水処理
- **仕様**: M12またはM16サイズ（配線径に合わせて選択）
