# ハードウェア設計・部品選定

Issue #1 での検討結果をまとめたドキュメント。

**試作1台（Wi-Fi 第1弾・Issue #11）**: [bom.md](bom.md) / [schematic.md](schematic.md) / [wiring.md](wiring.md)

### 開発ベンチと PoC 実証機

| 用途 | ボード | ドキュメント |
|---|---|---|
| **PoC 試作機（現場設置）** | Seeed XIAO ESP32S3 + Grove Shield | 本ドキュメント・bom / wiring / schematic |
| 開発ベンチ（完了・アーカイブ） | ESP32 DevKit | [firmware/devkit-bench.md](../firmware/devkit-bench.md) |

ファームウェアは PlatformIO の `xiao-s3` 環境で開発する。ロードマップは [Issue #22](https://github.com/makeOurCity/parking-status-sensor/issues/22)。

---

## 確定BOM（試作1台分）

| 部品 | 型番 | 入手先 | 価格 |
|---|---|---|---|
| マイコン | Seeed XIAO ESP32S3（無印） | [秋月電子](https://akizukidenshi.com/catalog/g/gM-18078/) | ¥1,480 |
| Grove Shield | Grove Shield for XIAO（103020312） | [Seeed JP](https://jp.seeedstudio.com/Grove-Shield-for-Seeeduino-XIAO-p-4621.html) 等 | 約¥700 |
| カラーセンサ | Grove - I2C Color Sensor V3.0（101021133） | [Seeed Studio](https://www.seeedstudio.com/Grove-Color-Sensor-V3-0-p-5993.html) 等 | 約¥600 |
| Grove 4芯ケーブル | 50〜100cm（現場ごとに選択） | Seeed / Amazon 等 | 約¥200〜400 |
| LTE-Mモジュール | M5Stack SIM7080G CAT-M Unit（M5STACK-U128） | [スイッチサイエンス](https://www.switch-science.com/products/11052) | ¥6,908 |
| LTE-M 電源スイッチ基板（LTE-M 版のみ） | 自作小基板 rev A（TI TPS22918、[hardware/lte-power-switch/](../hardware/lte-power-switch/)、#88） | JLCPCB（基板 + 実装） | $20.14（5 枚、送料込み。2026-10-05 発注。**rev A はコネクタのピン番号が鏡像。rev B（作成済み・未発注）で直した**） |
| LoRaWANモジュール（評価中・#40） | Seeed Grove - Wio-E5（STM32WLE5JC、技適付き。LTE-M とは排他） | [スイッチサイエンス](https://www.switch-science.com/products/9671) | 調達済み（2026-07-10） |
| SIM | SORACOM IoT SIM plan-D / plan-KM1 | [SORACOMストア](https://soracom.jp/store/13380/) | ¥990初期 + ¥192/月〜 |
| バッテリー | LiPo 3.7V 4,400mAh 保護回路内蔵 JST-PH | [ストロベリーリナックス](https://strawberry-linux.com/catalog/items?code=15095) | ¥550 |
| 電解コンデンサ | 470μF 16V（16WXA470MEFC8X9） | [秋月電子](https://akizukidenshi.com/catalog/g/g108426/) | ¥10〜 |
| 防水ケース | IP65以上の樹脂ケース | Amazon / モノタロウ | ¥500〜1,500 |
| 固定材料 | 透明テープ・黒カッティングシート・結束バンド | ホームセンター / 100均 | ¥300〜500 |
| ケーブルグランド | M12またはM16（2〜3個） | Amazon / モノタロウ | ¥100〜300 |

**試作1台 合計: 約¥14,000〜15,000**（SIM初期費用込み・LTE-M モジュール含む全体設計見積。Wi-Fi 第1弾のみの調達は [bom.md](bom.md) 参照）

---

## 部品選定の経緯

### カラーセンサ：Grove - I2C Color Sensor V3.0 を採用

**採用品：**

| 項目 | 内容 |
|---|---|
| 製品名 | Grove - I2C Color Sensor V3.0 |
| SKU | 101021133 |
| 搭載 IC | Vishay VEML6040（RGBW） |
| I2C アドレス | `0x10`（7-bit） |
| 入手先 | [Seeed Studio](https://www.seeedstudio.com/Grove-Color-Sensor-V3-0-p-5993.html) 等 |

**採用理由：**

- **Grove 統一接続**: XIAO + Grove Shield と Grove Color Sensor V3.0 をケーブル1本で接続
- **組み立て簡素化**: Grove コネクタ内蔵のため、基板への L字コネクタはんだ付けやケーブルピン入替が不要
- **PoC の検証目的に適合**: R/G/B/W の4チャンネル出力で、赤緑の相対強度比較による満空判定が可能
- **エコシステム整合**: XIAO・Grove Shield・将来の LTE-M（Grove UART）と同一規格で拡張しやすい

**初期検討からの変更：**

当初はストロベリーリナックス製 TCS34725 基板＋Grove L字コネクタ＋ピン入替を想定していた。試作機全体を Grove 接続に統一する方針に合わせ、Seeed 製 Grove モジュールへ変更した。搭載 IC は TCS34725 から **VEML6040** に変わるため、ファームウェアのセンサドライバ移行を実施した（Issue #5）。

**過去に検討した代替品（参考）：**

| センサ | 評価 |
|---|---|
| TCS34725 基板（#13472） | 初期案。色判別性能は高いが Grove 化に追加作業が必要 |
| APDS-9960 | 不採用。ジェスチャー/近接が主機能で赤緑分離に不向き |
| Grove I2C Color Sensor V2.0（TCS3472） | V3.0 の前身。V3.0（VEML6040）を採用 |

---

### 接続方式：Grove 統一接続

ジャンパ線・デュポン延長ケーブルではなく、**Grove 規格でセンサ〜本体を接続**する。

**構成（XIAO 実証機）**

1. **Grove - I2C Color Sensor V3.0** をセンサパッチに固定
2. **Grove 4芯ケーブル**（50〜100cm）で Grove Shield の I2C ポートへ接続（**ピン入替不要**）

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

**LiPo 単体運用時（USB 非接続）の給電経路（2026-09-27 確定、Issue #74）：**
5V 系統は**無効**。XIAO の 5V ピンは充電 IC ETA6003 の入力（IN）につながっているだけなので、電池で動かしているときは電気が来ない。XIAO 自身の 3.3V レギュレーターも使われず、**ESP32-S3 と Grove の各ポート（LTE-M を含む）は、Shield 上の降圧コンバーター ETA3410 の 3.3V 出力を共有している**（[Shield 回路図](datasheets/grove-shield-xiao-v1.0-sch.pdf)、[U128 回路図](https://docs.m5stack.com/en/unit/cat_m)）。

```
LiPo（BAT パッド / J9）→ SW1 → ETA6003（BATT → SYS）＝ VSYS
  → ETA3410（降圧、FB 分圧 100kΩ/22kΩ で ≈3.33V）＝ Shield の「3V3」
      ├ XIAO の 3V3 ピン → ESP32-S3
      ├ Grove の各ポートの VCC（カラーセンサーなど）
      └ Grove UART ポートの VCC → ロードスイッチ基板（#88）→ U128 の「+5V」入力
          → SY8003A（降圧、入力 2.7〜5.5V、FB 分圧 68kΩ/15kΩ で ≈3.32V）→ SIM7080G の VBAT
```

- U128 は 5V が来る前提の設計だが、実際には 3.3V で動いている。SY8003A はほとんど電圧を下げられないので、SIM7080G には「Shield の 3V3 − コンバーターでの落ち込み」がそのまま行く。SIM7080G の VBAT の範囲は 2.7〜4.8V（標準 3.8V、Cat-M1 のピーク電流は 0.5A 程度）なので、動作自体は範囲内
- 電池の電圧が下がり、LTE の送信バーストで VSYS が 3.3〜3.4V 付近まで下がると、ETA3410 は 3.3V を保てなくなる。すると 3V3 のラインは電池の電圧の落ち込みをそのまま受け、同じラインにつながる ESP32-S3 の電源電圧も落ちる。運用中のブラウンアウトリセットの一番有力な原因（#74、結論は [74-brownout-conclusions.md](74-brownout-conclusions.md)）。電池が Deep Sleep 中 約 3.70V・送信時 最低 約 3.27V のときに起き、約 4.08V・最低 3.73V では約 44h 起きなかった
- このため **LTE-M 版では、1 回目のブラウンアウト（`resetReason=brownout`）を「すぐ充電」の合図として扱う**（[74-brownout-conclusions.md](74-brownout-conclusions.md) §3.1）
- Shield の回路図には、SW1 のところに「Imax=500mA」の注記がある。LTE の送信時には 600mA 超が流れることを実測している（#74）
- 昇圧回路（3.7V→5V）は追加していない。U128 の SY8003A は入力 2.7V から動くので、3.3V でも LiPo 直結の電圧でも動作する

**充電回路とDeep Sleepの関係（Issue #57 調査）：**
Grove Shield上の充電IC **ETA6003**（[schematic](datasheets/grove-shield-xiao-v1.0-sch.pdf)）がUSB-Cの5VからLiPoへの充電をハードウェアのみで自律的に行う。`USB_DET` / `STAT` 等のピンはETA6003内で完結しており、XIAO（ESP32S3）のGPIOには配線されていない。そのため、**ESP32S3がDeep Sleep中かどうかに関わらず充電は継続する**。USB接続時に給電元がUSB側に切り替わるpower-path動作も同様にハードウェアのみで完結し、ファームウェアの介在は不要（かつ不可能）。

**稼働日数の試算（LiPo 4,400mAh・実効率90%・実効3,960mAh）：**

| 条件 | 稼働日数 |
|---|---|
| 5分間隔・Wi-Fi | 約74日 |
| 15分間隔・Wi-Fi | 約220日 |
| 5分間隔・LTE-M | 約37日 |
| **15分間隔・LTE-M（推奨）** | **約100日** |

上表は [README.md](../README.md) §6.2 と同じ**初期試算**（LTE active 5〜10秒前提）である。

**LTE-M 15 分推奨の根拠**（2026-07 時点。現在の方針・試算は README §6.2）:

1. 電池試算 … 5 分だと約37日、15 分だと約100日（PoC を電池交換なしで回す余裕）
2. 業務要件 … 満空監視に秒単位の即時性は不要
3. LTE は 1 サイクルあたりの awake が長い … 間隔を詰めるほど電池負荷が増える

**2026-07 実機（XIAO + SIM7080G + AWS IoT TLS、#6）:** active 約70秒、クラウド受信間隔 約8分（`PSS_SLEEP_SECONDS=300`）。満空 PoC としては許容範囲だが、試算より重く、**電池持ちは100日より短い可能性** がある。モデムは `poweroff()` 後も Grove 5V が供給され続ける（青 LED が点滅し続ける場合は完全停止していない疑い）。USB 電流計での実測で試算を更新する（README §8.1）。

**#25 Phase 0（2026-07-10）:** U200 で待機 ≈23 mA の内訳を確定。LTE が支配的で Grove 上では VCC 遮断不可。**現時点では LTE を電池 PoC のコア経路に据えない**（[25-low-power-mode.md](25-low-power-mode.md)）。

**2026-09-29 実測再試算（#76 修正後、Issue #74 の計測）— 最新:**

電池 #2・`xiao-s3-aws-lte-relay-pot`・#76 修正後のファームで、U200 高速ロガー（`logger-devkit-fast`）の約 44.5h の記録から求めた（詳細: [74-brownout-conclusions.md](74-brownout-conclusions.md) §4）。この値で計算した合計 65.0 mAh は、実測の合計 64.8 mAh（平均 1.46 mA）とほぼ一致する。

| 項目 | 実測値 |
|---|---|
| Deep Sleep 待機電流 | **0.43 mA**（平均。中央値 0.37 mA） |
| フル送信サイクル（起床〜LTE 接続〜MQTT publish〜切断〜Deep Sleep、毎回コールドアタッチ） | **16.8 秒・0.446 mAh**（41 回の中央値、0.43〜0.54 mAh） |
| スキップサイクル（LTE に触れずセンサー読取のみ） | 4.8 秒・0.0475 mAh（484 回の中央値） |
| ブートモード 1 回（約 4 分、送信 5 回） | 4.67 mAh |

稼働日数（LiPo 実効 3,960 mAh、起床間隔 304.8 秒（実測）、状態変化がなければ 13 回の起床に 1 回送信）:

| シナリオ | 1 日の消費 | 稼働日数（容量をすべて使える場合） |
|---|---|---|
| 定常（状態変化なし、約 66 分に 1 回の heartbeat のみ送信） | 32.4 mAh | **約 122 日** |
| 状態変化 1 日 20 回 | 40.4 mAh | 約 98 日 |
| 状態変化 1 日 50 回 | 52.3 mAh | 約 76 日 |
| 毎回変化（worst case、毎サイクル送信） | 137 mAh | 約 29 日 |

- 状態が 1 回変わるごとに、スキップサイクルが送信に置き換わるので約 0.40 mAh 増える
- 送信 1 回の値が 09-20 の値（0.327 mAh）より大きいのは、09-20 の値が「11.2 秒 × 105 mA」という、publish までの区間の値だったため。実際には接続・TLS の途中に 300〜500 mA 級のピークがあり、切断にも数秒かかる。#76 の修正前は、切断で約 30 秒余計に通電していて、送信 1 回が約 51 秒・約 1.3 mAh だった
- **LTE-M 版は、電池の電圧が下がるとブラウンアウトが起き始めるので、実際に使えるのはその手前まで**。一般的な LiPo の目安では休ませたときの 3.7V は残量 10〜15% 程度だが、未確認（[74-brownout-conclusions.md](74-brownout-conclusions.md) §2.4）

**2026-09-20 実測再試算（#46リレー・change-only-send反映、Issue #60実機検証時）— 上の 09-29 の値で置き換え:**

> 以下の実測は、**旧方式（ラッチングリレー、廃止）の機体**のもの。ロードスイッチ基板（#88）に替えたあとの待機電流は、未計測（TPS22918 の OFF 時の電流は 0.5µA typ で、リレー方式の保持電流ゼロと同等の見込み）。

上記の試算・議論はいずれも2026-07時点のもので、#46（リレーによるLTE-M電源の物理遮断）実装前、かつ`PSS_CHANGE_ONLY_SEND`（状態変化時のみ送信）導入前の前提である。当時は待機電流をLTE-Mの待機リーク（実測 ≈23mA、#25 Phase 0）が支配しており、Grove上ではVCCを遮断できなかった。リレー・change-only-send実装後の実機（`xiao-s3-aws-lte-relay`、`xiao-e83dc1fb05fc`）で改めて実測したところ、前提が根本的に変わっている。

実測値（電源ロガー`tools/power-logger`、詳細は[60-potentiometer-threshold-design.md](60-potentiometer-threshold-design.md) §10.2）:

| 項目 | 実測値 |
|---|---|
| Deep Sleep待機電流 | **0.45 mA**（#25 Phase0の23mAから約1/50に低減） |
| フル送信サイクル（LTE接続+MQTT publish、毎回コールドアタッチ） | 11.2秒 @ 105.2mA平均 = 0.327mAh |
| スキップサイクル（`PSS_CHANGE_ONLY_SEND`によりLTEに触れずセンサー読取のみ） | 5.07秒 @ 34.3mA平均 = 0.048mAh |

`PSS_HEARTBEAT_CYCLES=12`・`PSS_SLEEP_SECONDS=300`により、状態変化がなければ実質**1時間に1回**しか送信しない。これを踏まえた稼働日数（LiPo実効3,960mAh、5分間隔固定）:

| シナリオ | 稼働日数 |
|---|---|
| 定常（状態変化なし、1時間に1回のheartbeatのみ送信） | **約127日** |
| 毎回変化（worst case、実質毎サイクル送信＝旧試算と同条件） | 約38日 |

旧試算「5分間隔・LTE-M 約37日」は、`PSS_CHANGE_ONLY_SEND`導入前の「毎サイクル強制送信」を前提にしていたため、上記のworst caseとほぼ一致する（≈38日 vs 37日、たまたま近い数字になっているだけで前提は別物）。一方、実運用で想定される「状態がそう頻繁には変わらない」定常ケースでは、約127日と3倍以上の差が出る。**旧試算の「約100日」（15分間隔・LTE-M推奨）は、「active時間の過小評価（5〜10秒仮定）」と「待機電流の過大評価（23mA想定）」という2つの誤差がたまたま打ち消し合っていただけで、現在の構成（#46リレー＋change-only-send）にはそのまま当てはまらない**。15分間隔での再試算は未実施（`PSS_SLEEP_SECONDS`を変更した実測が必要）。

なお、Issue #60（現地調整用ポテンショメーター）を現地調整後も常時接続したままにすると、Deep Sleep待機電流が0.45mA→0.75mAへ増加し、定常ケースの稼働日数は127日→103日（-19%）に低下する。現地調整完了後はケーブルを抜いて常設する運用を推奨する（詳細: [60-potentiometer-threshold-design.md](60-potentiometer-threshold-design.md) §10.3/§10.4）。

**LoRaWAN:** Grove Wio-E5（STM32WLE5JC、技適付き）を調達済（2026-07-10）。ゲートウェイが現場にあり得る場合は経路優先度で LoRaWAN を第一とする。送信が短いため **5 分間隔** でも電池的に現実的（README §6.2）。待機電流は Phase 0 と同型の計測で評価予定。

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
Grove Shield UART ─ Grove ケーブル ─ [ロードスイッチ基板 J1→J2] ─ Grove ケーブル ─ M5STACK-U128
Grove Shield D0   ─ Grove ケーブル ─ [ロードスイッチ基板 J3]（LTE_EN、HIGH で ON）
```

**LTE-M の電源スイッチ：ロードスイッチ基板（#88・基板評価中）**

- Grove Shield のポート VCC は 3.3V レール直結で GPIO では切れないため、U128 の VCC 線だけを TI TPS22918（ロードスイッチ IC）で開閉する。Deep Sleep・リセット・電源喪失のどれでも、ON ピンのプルダウンで自動的に OFF になる（ステートレス）
- 基板は Grove コネクタ 3 つ（IN / OUT / CTRL）の小基板で、ケーブルを切らずに挿すだけ（**rev A は、コネクタのピン番号が鏡像のため、この使い方ができない。rev B（作成済み・未発注）で直した**）。設計は [88-load-switch-design.md](88-load-switch-design.md)、設計ファイルは [hardware/lte-power-switch/](../hardware/lte-power-switch/)
- 旧方式（Grove 2-Coil ラッチングリレー）は、5V 定格のコイルを 3.3V で駆動する設計上の誤りがあり廃止した。経緯と教訓は [25-low-power-phase2-hardware-cutoff.md](25-low-power-phase2-hardware-cutoff.md) §2

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
