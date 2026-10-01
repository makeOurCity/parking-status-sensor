# 配線図（Wi-Fi 第1弾）

Issue #11。試作1台の実装配線。部品リストは [bom.md](bom.md) を参照。

**単線図・複線図・回路図**: [schematic.md](schematic.md)  
本文は組み立て手順・実物確認向けの補足。

- **対象**: XIAO ESP32S3 + Grove Shield + Grove I2C Color Sensor V3.0 + LiPo（Wi-Fi のみ）
- **対象外**: LTE-M モジュール、防水ケース内レイアウト（#14）

---

## 1. システム構成

```
[満空灯発光面]
      │ 光
      ▼
[黒シート + Grove Color Sensor V3.0]  ← センサパッチ（テープ固定・取り外し可）
      │ Grove 4芯ケーブル（50〜100cm）
      ▼
[XIAO ESP32S3 + Grove Shield]  ← 本体ユニット
      │ Wi-Fi（内蔵アンテナ）/ MQTT
      ▼
[AWS IoT Core] → [Lambda ブリッジ] → FIWARE Orion

[LiPo 3.7V] ──JST-PH──→ [Grove Shield BAT パッド]
```

```mermaid
flowchart LR
  subgraph sensor_patch [センサパッチ]
    Sheet[黒カッティングシート]
    Sensor[Grove I2C Color Sensor V3.0]
    Sheet --> Sensor
  end

  subgraph main_unit [本体ユニット]
    Shield[Grove Shield for XIAO]
    XIAO[XIAO ESP32S3]
    CAP[470µF]
    LIPO[LiPo]
    XIAO --- Shield
    LIPO -->|JST-PH| Shield
    CAP --- Shield
  end

  Sensor <-->|Grove I2C| Shield
  Shield -->|Wi-Fi MQTT| MQTT[AWS IoT Core]
```

---

## 2. XIAO + Grove Shield

### 2.1 スタック構成

1. XIAO ESP32S3 に 1×40 ピンヘッダー（14ピン分）をはんだ付け
2. Grove Shield for XIAO を XIAO に装着（全ピンを通す）
3. センサ・電源・コンデンサは **Shield 上の Grove ポート / BAT パッド**を使用する

### 2.2 本 PoC で使用する接続

| 接続先 | 用途 | 備考 |
|---|---|---|
| Grove I2C ポート（いずれか1つ） | Grove I2C Color Sensor V3.0 | 標準 Grove ピン配置。ピン入替不要 |
| BAT+ / BAT− パッド | LiPo | JST-PH メスをはんだ付け |
| 3V3 / GND（Shield 上のパッドまたはピン） | 470µF | Wi-Fi 時の電圧降下対策 |

I2C は Shield 経由で XIAO の **D4（GPIO5 / SDA）**・**D5（GPIO6 / SCL）** にルーティングされる（ファームウェアの `board_xiao.h` と一致）。

### 2.3 未使用（第1弾）

| 接続 | 備考 |
|---|---|
| Grove UART ポート | LTE-M（M5STACK-U128）または LoRaWAN（Grove Wio-E5）を接続する。2つは排他（§9） |
| その他 Grove ポート | 未使用 |

### 2.4 はんだ付け位置

#### A. XIAO ピンヘッダー（Shield 装着用）

1×40 ピンヘッダーから **14ピン分** を切り出し、XIAO 長辺のパッド列にはんだ付ける。表からピンを刺し、裏で半田する。

```
        USB-C（この端が上）
  ┌─●─●─●─●─●─●─●─┐  ← 長辺のパッド列（ここにピンヘッダー）
  │   XIAO 表（部品面） │
  └─●─●─●─●─●─●─●─┘
```

#### B. LiPo 用 JST（Grove Shield BAT パッド）

**Grove Shield 基板**上の `BAT+` / `BAT−` パッドに、JST-PH 2.0mm **メス**コネクタ（またはリード線）をはんだ付けする。

- XIAO 本体には JST コネクタは**搭載されていない**（BAT パッドのみ）。電源接続は Shield 側で行う。
- **はんだ付け前にテスターで極性（＋−）を必ず確認**する。
- LiPo（手元: 4,400mAh・JST PH 2.0mm オス）を抜き差し可能にする。

極性の目安（Shield シルク・[Seeed Wiki](https://wiki.seeedstudio.com/Grove-Shield-for-Seeeduino-XIAO-embedded-battery-management-chip/) を実物で確認）:
- **BAT+** … LiPo の赤（＋）
- **BAT−** … LiPo の黒（−）

---

## 3. Grove I2C Color Sensor V3.0 接続

### 3.1 センサ仕様

| 項目 | 値 |
|---|---|
| 製品名 | Grove - I2C Color Sensor V3.0（SKU 101021133） |
| 搭載 IC | Vishay VEML6040（RGBW） |
| インターフェース | I2C（Grove コネクタ内蔵） |
| I2C アドレス | `0x10`（7-bit） |
| 動作電圧 | 2.5〜3.6 V（モジュールは 3.3 V 系統で使用） |
| 出力チャンネル | Red / Green / Blue / White |

データモデル上の `rawSensor.clear` には **White チャンネル**を対応させる（[data-model.md](data-model.md)）。

**Grove Shield の I2C ポート（3.3 V）に接続すること。** 5 V 専用ポートは使わない。

### 3.2 接続方法

センサモジュールには **Grove コネクタが内蔵**されている。追加のはんだ付けやケーブルピン入替は不要。

1. **Grove 4芯ケーブル**（50〜100 cm）を用意する
2. 一端を Grove Shield の **I2C ポート**に挿す
3. もう一端を Grove Color Sensor V3.0 に挿す

```
[Grove Shield I2C]     [Grove 4芯ケーブル]     [Grove Color Sensor V3.0]
  標準ピン配置    ═══════════════════════   標準ピン配置（入替不要）
  黄 SCL ─────────────────────────────────→ 黄 SCL
  白 SDA ─────────────────────────────────→ 白 SDA
  赤 VCC ─────────────────────────────────→ 赤 VCC
  黒 GND ─────────────────────────────────→ 黒 GND
```

### 3.3 センサパッチへの固定

1. 黒カッティングシートに受光窓を切り抜く
2. Grove Color Sensor V3.0 の受光部を窓に合わせてシートに貼付（モジュール底面のテープまたは両面テープ）
3. Grove コネクタ側はケーブルで本体ユニットへ延長

---

## 4. 電源配線

### 4.1 LiPo → Grove Shield

```
[LiPo 4,400mAh]          [Grove Shield]
  JST-PH オス ────────→  JST-PH メス（はんだ付け）
                         ├→ BAT+
                         └→ BAT−
                              │
                         [XIAO へ給電・充電管理]
```

| 項目 | 内容 |
|---|---|
| コネクタ | JST-PH 2.0（2pin） |
| 極性 | **接続前にテスターで確認** |
| 充電 | USB-C 接続で Shield 経由の充電管理で LiPo を充電 |
| 注意 | LiPo を BAT パッドに直結。5V ピンや VBUS への直結はしない |

### 4.2 470µF コンデンサ

Wi-Fi 送信時の電流スパイクによる電圧降下を抑える。Grove Shield 上の **3V3** と **GND** の間にできるだけ近接して接続する。

```
  3V3 ────┬──── （Shield / XIAO 系統）
          │
        ┌─┴─┐
        │470│ µF  （− マークの脚 → GND）
        │ µF│
        └─┬─┘
          │
  GND ────┴────
```

はんだ付けが難しい初期デバッグ時は、ジャンパ線（オス-メス）で仮接続してもよい。

---

## 5. 接続一覧（全体）

| 起点 | 終点 | 線種 | 備考 |
|---|---|---|---|
| LiPo + | Grove Shield BAT+ | JST-PH 2pin | 極性確認必須 |
| LiPo − | Grove Shield BAT− | JST-PH 2pin | 同上 |
| Grove Shield I2C | Grove Color Sensor V3.0 | Grove 4芯ケーブル | 標準配線（ピン入替不要） |
| Shield 3V3 | 470µF + | 短い線 or 直接はんだ | Shield 近傍 |
| Shield GND | 470µF − | 短い線 or 直接はんだ | Shield 近傍 |

I2C バスに追加デバイスはない。プルアップ抵抗は Grove モジュール基板側に実装済み。

---

## 6. センサパッチの機構（参考）

現場設置時の固定方法。電気配線とは別だが組み立て時に合わせて実施する。

1. 黒カッティングシートに受光窓を切り抜く（推奨位置: LED 配列の **下から2行目・左から2列目** 付近）
2. Grove Color Sensor V3.0 の受光部を窓に合わせてシートに貼付
3. 透明テープで発光面（透明アクリル）全体に固定（落下防止）

詳細は README §3.3・[hardware.md](hardware.md) を参照。

---

## 7. 組み立て順序

[bom.md](bom.md) のチェックリストに対応。

1. **棚卸し**: Raspberry Pi センサーキットがあれば重複部品を確認
2. **XIAO**: ピンヘッダー 14ピン分をはんだ → Grove Shield に装着
3. **電源**: Shield BAT パッドに JST-PH メスをはんだ（極性確認）→ LiPo 接続・起動確認
4. **センサパッチ**: 黒シートに受光窓を切り、Grove Color Sensor V3.0 を貼付
5. **470µF**: Shield 3V3-GND 間に接続
6. **結線**: Grove ケーブルで Shield I2C ↔ センサパッチを接続
7. **動作確認**: USB 接続でシリアル出力・I2C スキャン（#5）

---

## 8. 動作確認のヒント

### I2C スキャン

アドレス `0x10`（VEML6040）が見えれば配線成功の目安。

### よくあるミス

| 症状 | 確認点 |
|---|---|
| I2C デバイスが見えない | SDA/SCL 取り違え、Grove ケーブル接触不良、VCC/GND 逆 |
| 値が不安定 | GND 共通が取れていない、Grove ケーブル接触不良 |
| 起動しない | LiPo JST 極性逆、Shield BAT はんだの虚焊 |
| センサが飽和・異常 | 5 V ポートに接続していないか、受光窓の位置・遮光を確認 |

---

## 9. 将来拡張（参考・未配線）

LTE-M 導入時は **M5Stack SIM7080G CAT-M Unit（M5STACK-U128）** を Grove Shield の **UART ポート**にケーブル1本で接続する。PoC 第1弾では配線しない。

| 項目 | 内容 |
|---|---|
| モジュール | M5STACK-U128（Grove UART・SIM7080G） |
| SIM | SORACOM plan-D / plan-KM1（動作確認済み） |
| 判断 | Wi-Fi が使えない現場が出た時点で追加購入 |

詳細は [hardware.md](hardware.md) の通信セクションを参照。

### 9.1 LoRaWAN（Grove Wio-E5、#40 評価中）

**Grove Wio-E5**（STM32WLE5JC、技適付き）を、LTE-M と同じ Grove Shield の **UART ポート**に Grove 4芯ケーブルで接続する。LTE-M と同時には載せない（UART ポートが1つのため。ファームは env で切り替え、同時に有効にするとビルドエラーになる）。

| 項目 | 内容 |
|---|---|
| 接続先 | Grove Shield UART ポート |
| XIAO 側ピン | D6（GPIO43, TX）→ Wio-E5 RX / D7（GPIO44, RX）← Wio-E5 TX |
| ボーレート | 9600 bps（Wio-E5 の既定値） |
| 電源 | Shield の 3.3V（GPIO で切れないため、ESP32 の Deep Sleep 中も通電。省電力は `AT+LOWPOWER` で行う） |
| アンテナ | 基板の IPEX（u.FL）に付属ワイヤアンテナ |
| ファーム | `board_xiao.h` の `LORAWAN_UART_*`、疎通確認は env `xiao-s3-lorawan-test`（[firmware/README.md](../firmware/README.md)） |

- **アンテナは付属品か Seeed 純正の Wio-E5 向けのものだけを使う**。技適はモジュールとアンテナの組み合わせで取られている可能性が高く、他社製アンテナへの交換は法令上のリスクがある
- GPIO43 は ESP32-S3 の UART0 TX と同じピンで、起動時の ROM ログが Wio-E5 の RX に流れる。Wio-E5 が誤って起きる・応答が乱れる可能性があるため、ファームは最初に受信を捨ててから `AT` を数回送って同期する
