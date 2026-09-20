# Issue #60: 現地調整用ポテンショメーターによる判定閾値の可変化 実装計画

対象Issue: https://github.com/makeOurCity/parking-status-sensor/issues/60

本ドキュメントは、実コード(`firmware/include/config.h`, `firmware/include/board_xiao.h`,
`firmware/include/classify.h`, `firmware/src/classify.cpp`, `firmware/include/relay.h`,
`firmware/src/relay.cpp`, `firmware/src/main.cpp`, `firmware/platformio.ini`,
`docs/data-model.md`)と突き合わせて検討した実装計画。Issueの「次のアクション」4項目
(board_xiao.hへのピン定義追加 / 読み取り・閾値算出関数の追加 / classify.cpp呼び出し箇所の置き換え
/ テレメトリJSONへの追加)を、既存の`relay.h/cpp`(ハードウェア周辺機能)・`#50`ブートモード
(ビルドフラグによる機能ゲート、複数呼び出し箇所での一貫性)の設計パターンに沿って具体化する。

## 改訂履歴

| 版 | 主な変更点 |
|---|---|
| v1 | 初版。新規モジュール`potentiometer.h/cpp`の新設、対数マッピング関数の実装方式、`classify.cpp`無改修方針、`buildPayload()`/`publishWithRetry()`シグネチャ拡張、GPIO3がESP32-S3のストラップピンである点の指摘を含む。 |
| v2 | レビュー結果を受け、ポテンショメーターの接続先を**D2/A2(GPIO3)からD1/A1(GPIO2)に変更**(GPIO2はESP32-S3のストラッピングピンではないため、GPIO3のストラップピン懸念を実機検証を待たずに設計変更で解消)。あわせて`platformio.ini`のenv追加案を、卓上テスト用・実機ベンチデバッグ用・本番投入用の3種類に整理し、§8テスト計画・§9実装ステップの対応関係を明確化。`setup()`内の`initPotentiometer()`呼び出し順序が、`initRelay()`のような安全上の要請ではなく便宜上のものである旨を明記。 |
| v3(本版) | ユーザー判断により、`platformio.ini`への新規env追加を**本番投入用の`xiao-s3-aws-lte-relay-pot`1つのみ**に簡略化(卓上テスト専用・実機ベンチデバッグ専用のenvは追加しない)。卓上での事前確認・起動安定性確認は、専用デバッグenvの代わりに既存のブートモード(`#50`、電源投入直後の最大4分間はDeep Sleepなしで5回連続送信する)を利用する方針に変更し、§8テスト計画・§9実装ステップを単一env前提に書き直した。反復速度に不満が出た場合は、既存の`xiao-s3-aws-lte-relay-debug`と同じパターンで`-pot-debug`亜種を後日追加できる(YAGNI)。 |

---

## 1. 目的・要件(Issue #60 より)

**背景**: 在/不在判定の閾値`PSS_STATUS_THRESHOLD`(`firmware/include/config.h:17-21`)は
コンパイル時の固定値で、`classify.cpp`のR-G差分判定にそのまま使われている
(`firmware/src/classify.cpp:3-14`)。

- 320ms積分時代の基準値は**100**(`README.md:163`「差 ≥ 100」相当)。
- `#43`で積分時間を320ms→40ms(1/8)に変更した際、スケール比に基づく暫定値**13**への変更を
  検討したが未投入で、本番は今も`100`のまま稼働している。

設置場所ごとに満空灯の輝度・距離・周辺光量が異なり、固定値では現場ごとに追加検証・再書き込みが
必要になる。2026-08-24〜25の屋外実証と2026-09-19〜20の室内テストの比較から、**積分時間
(40ms)自体は屋外で飽和しておらず変更不要である一方、屋内外で生値の絶対値が数十〜百倍程度
異なる**ことが確認された(周辺光量・満空灯との距離・`#3`遮光フード未実装による外光混入が要因と
推定)。

**要件(確定)**:
1. 積分時間は40ms固定のまま変更しない。判定閾値のみを現地で無段階に調整できるようにする。
2. ハードウェアはGrove - Rotary Angle Sensor(電位差計)を、Grove Shield for XIAOのADC対応
   ポート(Analogポート)に接続する。ピンはD1/GPIO2(採用理由は§2.1参照。Issue本文はD2/GPIO3を
   提示していたが、設計協議の結果D1/GPIO2に変更した)。
3. 起床のたびにADC値(0〜4095)を複数回サンプリング・平均してノイズを軽減する。
4. 対数マッピング(下限30・上限15000、`threshold = round(30 × (15000/30)^(adc/4095))`)で
   ADC値を閾値に変換する。
5. 消費電力への影響はほぼ無視できる想定(要検証)。
6. テレメトリJSONに実効閾値だけでなく、ポットの生ADC値も含める。
7. Issue記載の段階的実装方針(board_xiao.hへのピン定義→読み取り/閾値算出関数→
   classify.cpp呼び出し箇所の置き換え→テレメトリJSON追加)に従う。

---

## 2. 設計方針

### 2.1 ADCピン・読み取り方式

**ピン選定の妥当性(ESP32-S3固有の確認事項)**: XIAO ESP32S3のGrove Shield Analogポートには
A1(D1/GPIO2)・A2(D2/GPIO3)の2系統があり、いずれもGrove Shield上で電気的に利用可能である
(実測: `variants/XIAO_ESP32S3/pins_arduino.h`で`D1=GPIO2`、`D2=GPIO3`と定義されている)。
本設計では**A1/D1(GPIO2)を採用する**(選定理由は次段落)。ESP32-S3のADCチャンネル割り当て
では、GPIO1〜GPIO10が**ADC1**(GPIO2 = ADC1_CH1)、GPIO11〜GPIO20が**ADC2**である。既存の
I2C(D4/D5=GPIO5/6)・UART(D6/D7=GPIO43/44)とは重複せず、かつ**ADC1はWi-Fi動作中でも読み取り
制限を受けない**(ADC2はWi-Fi PHYと排他制御されるため、Wi-Fi/BTアクティブ中は精度が落ちる/
使えない場合がある、という一般に知られる制約がある。ただしこの制約は主にオリジナルESP32
(Xtensa LX6世代)で顕著だったものであり、ESP32-S3ではADC2まわりの制約状況が異なる可能性
がある。本設計はいずれにせよADC1(GPIO2)を使う結論のため、この点は「なぜADC1を選んだかの
補足説明」に過ぎず結論には影響しない)。本プロジェクトは`kLteOnly`ビルドではLTEのみ使うが、
Wi-Fi版env(`env:xiao-s3-aws`)も存在するため、ADC1を使えることは設計上重要な確認事項である。

**ピン選定の経緯(GPIO3ではなくGPIO2を選んだ理由)**: 検討初期にはA2/D2(GPIO3)も候補で
あった(GPIO3も同じADC1バンクに属し、電気的にはA1/D1と同格で、I2C/UART/リレーとも未競合)。
しかし**GPIO3はESP32-S3のストラップピンの一つ**(GPIO0/GPIO3/GPIO45/GPIO46の4本)であり、
リセット時にJTAGの信号ソース選択に使われる。GPIO0(ダウンロードモード選択)のように
「Highでなければ通常起動できない」類の必須ピンではなく、JTAG未使用時は機能に影響しない
はずであり、Seeed純正のGrove Shield for XIAOがAnalogポートとしてこのピンを標準的に露出
させている(=商用シールドとして広く使われている実績がある)ことを踏まえても、電位差計
接続時の起動安定性への影響はゼロと断定はできない。**GPIO2(A1/D1)はESP32-S3のストラッピング
ピンではなく**、上記の懸念が構造的に生じないため、ユーザーとの協議の結果、電気的特性・
既存配線との非競合という結論に影響を与えず、かつ余計なリスクを負わないGPIO2を採用する
ことに決定した。これにより、v1で「§8のテスト計画で実機確認する」としていた未解決リスク
(GPIO3ストラップピンの起動安定性への影響)は、テストによる確認を待たずに**設計変更に
よって解消**される(念のための基本確認は§8テスト項目5で引き続き行う)。

**読み取り実装**:
- `analogReadResolution(12)`で12bit(0〜4095)を明示する(Arduino-ESP32のデフォルトも12bitだが、
  他の設定同様に明示しておく)。
- `analogSetPinAttenuation(POT_ADC_PIN, ADC_11db)`でフルレンジ(0〜3.3V付近)を使えるようにする。
- ESP32系ADCの既知の非線形性・ノイズ対策として、`config::kPotSampleCount`回(既定8回)
  `analogRead()`し、サンプル間に短いdelay(2ms)を挟んで単純平均する。対数マッピングは
  下限30・上限15000という広いレンジに対してADCコード単位の微小な非線形性の影響は相対的に
  小さく、`analogReadMilliVolts()`(内蔵校正)や中央値フィルタのような高度な補正までは不要と
  判断する(実測で問題が出れば§6の未確定事項として後日補正方式を追加する)。

### 2.2 新規モジュールの設計

**結論: `classify.h/cpp`には手を入れず、`relay.h/cpp`と同じパターンで新規ペアファイル
`potentiometer.h`/`potentiometer.cpp`を新設する。**

理由: `classify.cpp`(`firmware/src/classify.cpp:1-14`)は`RawSample`と`int threshold`を
受け取って`ParkingStatus`を返すだけの、Arduino APIに一切依存しない純粋ロジックであり、
呼び出し元(`main.cpp`)が`config::kStatusThreshold`をどう決めるかについて`classify.cpp`
自身は無関心(閾値はすでに外部から渡されるパラメータになっている)。ここにADC読み取り
(`Arduino.h`, `analogRead()`, `delay()`)や`config.h`依存のマッピングロジックを混ぜると、
現在依存ゼロの純粋判定ロジックにハードウェア依存を持ち込むことになり、`#47`の
history-log設計が「既存の`sync_ledger.*`には一切変更を加えない」としたのと同じ理由で
避けるべきである。一方`relay.h/cpp`は「GPIOを介した周辺機能の初期化・操作」という
`classify.cpp`とは異なる責務を持つ独立モジュールとして最初から切られており、ポットの
「ADC初期化・読み取り・平均化・閾値算出」はこれと同種の責務なので、同じ構成
(`initXxx()`+`XxxOn/Off()`ではなく`initXxx()`+`readXxx()`)を踏襲する。

```cpp
// firmware/include/potentiometer.h
#pragma once

#include <stdint.h>

// #60: 現地調整用ポテンショメーター(Grove - Rotary Angle Sensor)。
// Grove Shield for XIAO Analogポート(D1/GPIO2)、対数マッピングで判定閾値を算出する。
// docs/60-potentiometer-threshold-design.md 参照。
struct PotReading {
  uint16_t raw = 0;                        // 0-4095、平均済みADC値
                                            // (kPotEnabled=falseの場合は常に0)
  int threshold = 0;                       // rawから算出した実効閾値
                                            // (kPotEnabled=falseの場合はconfig::kStatusThreshold)
};

void initPotentiometer();
PotReading readPotentiometerThreshold();

// 単体で境界値確認しやすいよう、対数マッピングだけを切り出した純粋関数。
int computeThresholdFromAdc(uint16_t adc);
```

呼び出しタイミング: `initPotentiometer()`は`relay.h`の`initRelay()`と同じく`setup()`から
1回(ボード起床のたび、すなわちDeep Sleep復帰のたびに`setup()`ごと再実行される)呼ぶ。
`readPotentiometerThreshold()`は**`runCycle()`と`runBootMode()`の両方**で、
`readSensor(sample)`の直後・`classifyStatus()`の直前に呼ぶ(Issueが指摘する「boot-mode時も
同じ固定値`config::kStatusThreshold`を渡している」問題を、両方の呼び出し箇所で解消する)。

`runBootMode()`では**5回のスロットそれぞれで再読み込みする**設計にする。ブートモード
(`#50`)は電源投入直後の最大4分間、1分おきに5回連続送信する機能であり、この間に現地作業者が
ポットを回しながらクラウド側/シリアルログで判定結果の変化をほぼリアルタイムに確認できる
ことは、本Issueが解決したい「現地調整の往復コスト」を最小化する副次効果になる。

補足(v3): この「ブートモード中はDeep Sleepなしで最大4分間動き続ける」性質は、§8のテスト
計画で専用デバッグenvの代わりに使う前提にもなっている(§8参照)。

### 2.3 閾値マッピング関数

`threshold = round(30 × (15000/30)^(adc/4095))`は浮動小数点`powf()`で素直に実装する。
ESP32-S3はハードウェアFPU(単精度)を持ち、この計算はサイクルに1回(既定300秒に1回、
ブートモード中でも最大60秒に1回)しか呼ばれないため、整数演算近似によるコスト削減は
不要と判断する(過去に他の箇所で整数近似が採用された形跡もない)。

```cpp
// firmware/src/potentiometer.cpp
#include "potentiometer.h"

#include <Arduino.h>
#include <math.h>

#include "board.h"
#include "config.h"

namespace {
constexpr uint16_t kAdcMax = 4095;
}  // namespace

void initPotentiometer() {
  if (!config::kPotEnabled) {
    return;
  }
  analogReadResolution(12);
  analogSetPinAttenuation(POT_ADC_PIN, ADC_11db);
}

int computeThresholdFromAdc(uint16_t adc) {
  // 仕様上analogRead()は0-4095に収まるが、防御的にクランプしてから計算する
  // (§7「エッジケース対応」参照)。
  const uint16_t clamped = adc > kAdcMax ? kAdcMax : adc;
  const float ratio = static_cast<float>(clamped) / static_cast<float>(kAdcMax);
  const float lower = static_cast<float>(config::kPotThresholdMin);
  const float upper = static_cast<float>(config::kPotThresholdMax);
  const float threshold = lower * powf(upper / lower, ratio);
  return static_cast<int>(lroundf(threshold));
}

PotReading readPotentiometerThreshold() {
  if (!config::kPotEnabled) {
    // 未配線機体の既定値。ADCには一切触れない(§7参照)。
    return PotReading{0, config::kStatusThreshold};
  }

  uint32_t sum = 0;
  for (uint8_t i = 0; i < config::kPotSampleCount; ++i) {
    sum += analogRead(POT_ADC_PIN);
    if (i + 1 < config::kPotSampleCount) {
      // ADC自体のノイズとワイパー接触ノイズの平滑化用。VEML6040の1500ms
      // 安定待ち(sensor.cpp)に比べ無視できる遅延(§2.4参照)。
      delay(2);
    }
  }
  const uint16_t avg = static_cast<uint16_t>(sum / config::kPotSampleCount);
  return PotReading{avg, computeThresholdFromAdc(avg)};
}
```

`PSS_POT_THRESHOLD_MIN`/`MAX`/ADC最大値4095は`config.h`に`PSS_POT_*`マクロとして追加する
(§3)。4095自体はESP32のADC分解能そのもの(ハードウェア固定値)なのでビルドフラグ化は
せず、`potentiometer.cpp`内の`kAdcMax`定数のままとする。下限30・上限15000は「複数現場の
実測が揃うまで再検討する」とIssueが明記している調整対象の値なので、`PSS_POT_THRESHOLD_MIN`/
`MAX`としてビルドフラグ化し、コード変更なしで現場ごと・季節ごとに再調整できるようにする。

### 2.4 `classify.cpp`の変更方針

**結論: `classify.h`/`classify.cpp`は一切変更しない。** `classifyStatus(sample, threshold)`は
既にthresholdを外部から受け取る設計になっているため(`firmware/include/classify.h:8`)、
「固定値→実行時算出値への置き換え」は呼び出し元(`main.cpp`)で完結する。

`config::kStatusThreshold`は**削除せず、ポット無効時のフォールバック値として残す**。
`relay.cpp`の`config::kLtePowerRelayEnabled`と全く同じパターンで、新設する
`config::kPotEnabled`(既定`0`)によってポット機能自体を有効/無効化できるビルドフラグを
設ける。理由:
- リレー同様、ポットが物理配線されていない既存機体(現行運用中の実機を含む)に誤って
  ポット由来の不定値を閾値として使わせないための安全弁が必要。
- `readPotentiometerThreshold()`自体が内部で`config::kPotEnabled`を判定して
  `config::kStatusThreshold`をそのまま返すため、呼び出し元(`runCycle()`/`runBootMode()`)は
  分岐を書かずに済み、`relayLteOn()`等と同様「呼び出しは常に行い、有効/無効の判定は
  関数内部に閉じる」という既存の設計言語を踏襲できる。

`main.cpp`側の呼び出し箇所2箇所(`runCycle()`: `main.cpp:434`、`runBootMode()`:
`main.cpp:588`)を、それぞれ`readPotentiometerThreshold()`で得た`PotReading.threshold`を
渡す形に変更する(§4.2/4.3)。

### 2.5 テレメトリJSON

`buildPayload()`(`main.cpp:160-234`)は既に`doc["threshold"] = config::kStatusThreshold;`
(`main.cpp:178`)を出力している。この値は`docs/data-model.md:25`で「判定に使用したR-G差の
閾値」と定義済みであり、**フィールドの意味自体は変えず、値を実効閾値(ポット有効時は
算出値、無効時は従来通り`config::kStatusThreshold`)に差し替えるだけ**で済む。

新たに`doc["pot"]`オブジェクトを追加し、生ADC値と有効/無効フラグを載せる(現地での調整
履歴追跡がIssueの要求)。マッピング上下限(`kPotThresholdMin`/`MAX`)はビルド時定数で
メッセージごとに変化しないため、ペイロードには含めない(ファームウェアバージョン/
ビルド設定側の情報として扱う)。

```cpp
doc["threshold"] = potReading.threshold;  // #60: 実効閾値(ポット有効時は算出値)
doc["determinedBy"] = "device";
...
// #60: 現地でのポット調整履歴を追跡できるよう、生ADC値も併記する。
JsonObject pot = doc["pot"].to<JsonObject>();
pot["enabled"] = config::kPotEnabled;
pot["adcRaw"] = potReading.raw;
```

`kPayloadSize = 1024`(`main.cpp:23`)に対し、追加分は50バイト程度でヘッドルームは十分。

### 2.6 消費電力・タイミング

`initPotentiometer()`(アッテネーション設定)は`setup()`から`initRelay()`と同様、
起床のたびに(Deep Sleep復帰は`setup()`ごと再実行されるため)毎回呼ぶ。VEML6040のような
外部I2Cペリフェラルの電源投入直後の安定待ち(`sensor.cpp`の`delay(1500)`)とは異なり、
内蔵ADCは電源投入直後から即座に読み取り可能であり、**専用の安定待ちは不要**と判断する。
`readPotentiometerThreshold()`内の8回×2ms=16ms程度のサンプリング間隔は、ノイズ平滑化目的の
遅延であってハードウェア安定待ちではない。

`kPotSampleCount=8`回の`analogRead()`自体は1回あたりマイクロ秒オーダーであり、
`initSensor()`の1500ms安定待ちや、LTE接続フェーズ(数秒〜数十秒)と比べて無視できるコスト
増分である。Issueの「消費電力への影響はほぼ無視できる」という見立ては妥当と判断する
(実測での裏付けは§8テスト計画6で行う)。

呼び出し位置は`readSensor(sample)`直後・`classifyStatus()`直前とする(`initSensor()`の
成否判定より後)。センサーI2C初期化に失敗した場合(`kSensorError`)は元々`classifyStatus()`
に到達せず送信もしないため、ポット読み取りもそのケースでは行わない(無駄なADC読み取りを
避ける)。

---

## 3. 設定値の追加(`firmware/include/config.h`)

既存の`PSS_*`マクロ + `config::k*`定数という命名規約(`config.h:17-21`, `246-256`)に倣う。

```cpp
#ifndef PSS_POT_ENABLED
// #60: 現地調整用ポテンショメーター(Grove - Rotary Angle Sensor、Grove Shield
// for XIAO Analogポート/D1/GPIO2)による判定閾値の可変化。
// リレー(#46)同様、配線済みの機体でのみ1にする。未配線機体でフローティングピンの
// 不定値を閾値として使わないための安全弁。docs/60-potentiometer-threshold-design.md 参照。
#define PSS_POT_ENABLED 0
#endif

#ifndef PSS_POT_SAMPLE_COUNT
#define PSS_POT_SAMPLE_COUNT 8
#endif

#ifndef PSS_POT_THRESHOLD_MIN
// 対数マッピングの下限。複数現場の実測が揃うまでの暫定値(Issue #60時点)。
#define PSS_POT_THRESHOLD_MIN 30
#endif

#ifndef PSS_POT_THRESHOLD_MAX
// 対数マッピングの上限。2026-08-25屋外実測(r-g差分最大-11173)に3割の余裕を持たせた
// 暫定値(Issue #60時点)。#3遮光フード完成後、屋外レンジが変われば再評価する。
#define PSS_POT_THRESHOLD_MAX 15000
#endif
```

```cpp
namespace config {
// ...既存定数群の末尾に追加...
constexpr bool kPotEnabled = PSS_POT_ENABLED;
constexpr uint8_t kPotSampleCount = PSS_POT_SAMPLE_COUNT;
constexpr int kPotThresholdMin = PSS_POT_THRESHOLD_MIN;
constexpr int kPotThresholdMax = PSS_POT_THRESHOLD_MAX;
}  // namespace config

static_assert(PSS_POT_THRESHOLD_MIN > 0 && PSS_POT_THRESHOLD_MAX > PSS_POT_THRESHOLD_MIN,
              "PSS_POT_THRESHOLD_MIN/MAX must form a positive, increasing range for the "
              "logarithmic mapping (powf(MAX/MIN, ratio)) to stay well-defined");
```

`board_xiao.h`には既存の`I2C_SDA`/`LTE_UART_RX`/`LTE_POWER_RELAY_PIN`と同じ命名規約で
ピン定義を追加する。

```cpp
// Grove Shield for XIAO Analogポート(Grove - Rotary Angle Sensor)
// #60: 現地調整用ポテンショメーターによる判定閾値の可変化
// (ADC1_CH1、Wi-Fi動作中でも制限を受けないADC1系。I2C/UART/リレーと未競合)
#define POT_ADC_PIN 2  // D1 (GPIO2。ストラッピングピンではないGPIOを選定。§2.1参照)
```

---

## 4. 疑似コード最終版

### 4.1 `potentiometer.h` / `potentiometer.cpp`(新規)

§2.2/2.3に掲載した全文の通り(`firmware/include/potentiometer.h`,
`firmware/src/potentiometer.cpp`として新規作成)。

### 4.2 `main.cpp`: `setup()`への追加

```cpp
void setup() {
  initRelay();
  initPotentiometer();  // #60: ADCアッテネーション設定。initRelay()との順序に依存関係なし

  Serial.begin(115200);
  waitForSerial();
  ...
```

補足: `initPotentiometer()`をここ(`initRelay()`の直後・`Serial.begin()`より前)に置くこと
自体には、`initRelay()`が持つような安全上の緊急性(ウォッチドッグ等での不整合な再起動時に
最優先でLTE-MをOFFに倒すフェイルセーフ、`relay.cpp`のコメント参照)はない。ADCの
アッテネーション設定は`Serial.begin()`の前後どちらに置いても動作上の差はなく、単に
`initRelay()`とハードウェア初期化群としてまとめて記述する方が読みやすいという、
コーディング上の都合で現在の位置にしているだけである(緊急性のある`initRelay()`と並べて
書いたことで安全上の要請があるかのように読めてしまわないよう、ここに明記する)。

### 4.3 `main.cpp`: `runCycle()`の変更

```cpp
  RawSample sample{};
  readSensor(sample);

  const int rgDiff =
      static_cast<int>(sample.red) - static_cast<int>(sample.green);
  const PotReading potReading = readPotentiometerThreshold();  // #60
  const ParkingStatus status = classifyStatus(sample, potReading.threshold);
  Serial.printf(
      "sample r=%u g=%u b=%u w=%u r-g=%d status=%s threshold=%d potRaw=%u\n",
      sample.red, sample.green, sample.blue, sample.white, rgDiff,
      statusToString(status), potReading.threshold, potReading.raw);
  ...
  const bool ok = publishWithRetry(sample, status, metrics, cycleStart,
                                   faultInject, BootModeSendInfo{}, potReading,
                                   payload, sizeof(payload), pub);
```

### 4.4 `main.cpp`: `runBootMode()`の変更

```cpp
    RawSample sample{};
    readSensor(sample);
    const PotReading potReading = readPotentiometerThreshold();  // #60: スロットごとに再読込
    const ParkingStatus status = classifyStatus(sample, potReading.threshold);
    Serial.printf(
        "boot-mode slot=%u/%u sample r=%u g=%u b=%u w=%u status=%s "
        "threshold=%d potRaw=%u\n",
        sendIndex + 1, config::kBootModeSendCount, sample.red, sample.green,
        sample.blue, sample.white, statusToString(status),
        potReading.threshold, potReading.raw);
    ...
    const bool ok = publishWithRetry(sample, status, metrics, slotStart,
                                     /*faultInject=*/false, bootInfo, potReading,
                                     payload, sizeof(payload), pub);
```

### 4.5 `main.cpp`: `buildPayload()` / `publishWithRetry()`のシグネチャ変更

```cpp
void buildPayload(const RawSample& sample, ParkingStatus status,
                  const TransportMetrics& transportMetrics, uint32_t activeMs,
                  uint8_t publishAttempts, const BootModeSendInfo& bootModeInfo,
                  const PotReading& potReading, char* out, size_t outSize) {
  JsonDocument doc;
  ...
  JsonObject raw = doc["raw"].to<JsonObject>();
  raw["red"] = sample.red;
  raw["green"] = sample.green;
  raw["blue"] = sample.blue;
  raw["clear"] = sample.white;

  doc["threshold"] = potReading.threshold;  // #60: 実効閾値(§2.5)
  doc["determinedBy"] = "device";
  ...
  // ...power/network/sync/bootModeオブジェクトは不変...

  // #60: 現地でのポット調整履歴を追跡できるよう、生ADC値も併記する。
  JsonObject pot = doc["pot"].to<JsonObject>();
  pot["enabled"] = config::kPotEnabled;
  pot["adcRaw"] = potReading.raw;

  serializeJson(doc, out, outSize);
}

bool publishWithRetry(const RawSample& sample, ParkingStatus status,
                      TransportMetrics& metrics, uint32_t cycleStart,
                      bool faultInject, const BootModeSendInfo& bootModeInfo,
                      const PotReading& potReading, char* payload,
                      size_t payloadSize, PublishResult& result) {
  result = PublishResult{};
  const uint32_t phaseStart = millis();

  for (uint8_t attempt = 1; attempt <= config::kPublishMaxAttempts; ++attempt) {
    ...
    buildPayload(sample, status, metrics, millis() - cycleStart, attempt,
                 bootModeInfo, potReading, payload, payloadSize);
    ...
  }
  return false;
}
```

---

## 5. 検証済みの設計上の整合性

### 5.1 `classify.h`/`classify.cpp`は無改修

`classifyStatus(sample, threshold)`のシグネチャ(`classify.h:8`)は変更しない。呼び出し元が
渡す`threshold`の値の出所が「コンパイル時定数」から「実行時にADCから算出した値
(ただし無効時は同じコンパイル時定数)」に変わるだけであり、この関数自体はその違いを
一切意識しない。既存の判定ロジック(`rgDiff >= threshold` / `-rgDiff >= threshold`)への
影響はゼロ。

### 5.2 `runCycle()`と`runBootMode()`で一貫した閾値が使われる

両関数とも「`readSensor()`直後→`readPotentiometerThreshold()`→`classifyStatus()`→
(送信する場合は)`buildPayload()`に同じ`potReading`を渡す」という同一の順序を踏む。
`#50`ブートモード設計時に発生した「`metrics.transport`がスロットによって不整合になる」
類の回帰(`docs/50-boot-mode-design.md` §2.3)と同種の問題が起きないよう、`potReading`は
1回のスロット/サイクルにつき1回だけ計算し、`classifyStatus()`に使った値とペイロードに
出力する値が常に同一であることを構造的に保証する(スロット内で2回読み直さない)。

### 5.3 `config::kPotEnabled=false`時はADCに一切触れない

`readPotentiometerThreshold()`は`config::kPotEnabled`が偽の場合、`analogRead()`を含む
ADC API呼び出しを一切行わずに`PotReading{0, config::kStatusThreshold}`を返す
(`relay.cpp`の`initRelay()`/`relayLteOn()`が`kLtePowerRelayEnabled`で早期returnするのと
同一パターン)。既存の稼働機体(`PSS_POT_ENABLED`未指定=既定`0`)は、この変更によって
挙動が一切変わらない(`doc["threshold"]`は従来通り`config::kStatusThreshold`のまま)。

### 5.4 ペイロードサイズへの影響は無視できる

`kPayloadSize = 1024`(`main.cpp:23`)に対し、`pot`オブジェクト追加分は
`{"enabled":false,"adcRaw":0}`相当で30バイト未満。`#50`のブートモード追加時と同様、
既存のバッファサイズで十分に収まる。

---

## 6. 未確定事項への結論(Issue本文より)

| # | 論点 | 結論 |
|---|---|---|
| 1 | 対数マッピングの下限30・上限15000が妥当か | 本設計ではIssue記載の値を`PSS_POT_THRESHOLD_MIN`/`MAX`の**デフォルト値**としてそのまま採用し、ビルドフラグで上書き可能にする(§3)。複数現場データが揃うまでの恒久的な結論はIssueの通り持ち越すが、再調整はコード変更なし(ビルドフラグの値のみ)で行える設計にする。 |
| 2 | `#3`遮光フード完成後の閾値レンジ再評価 | 同上。フード完成後に屋外実測レンジが変わった場合も、`PSS_POT_THRESHOLD_MAX`(必要なら`MIN`も)の値を差し替えて再ビルドするだけで対応できる。`potentiometer.cpp`のロジック自体の変更は不要。 |
| 3 | 筐体へのつまみ露出用開口部(防水・防塵設計) | ハードウェア筐体(`#3`関連、`docs/enclosure.md`)の検討事項であり、本ドキュメント(ファームウェア設計)のスコープ外。別途Issueで追跡することを推奨する。 |
| 4 | テレメトリJSONへの実効閾値・ポットADC生値の追加 | §2.5/§4.5で対応済み。`doc["threshold"]`を実効値に置き換え、新規`doc["pot"]`(`enabled`/`adcRaw`)を追加する。 |
| 5(v1で発見、v2でGPIO2選定により解消) | GPIO3がESP32-S3のストラップピン(JTAGソース選択)であることの起動安定性への影響 | v1時点では未検証のリスクだったが、**ポット接続先をA2/D2(GPIO3)からA1/D1(GPIO2)に変更したことで設計上は解消**した(GPIO2はESP32-S3のストラッピングピンではない、§2.1)。念のため§8テスト項目5で実機の基本的な起動安定性を確認する。 |

---

## 7. エッジケース対応

| ケース | 対処 |
|---|---|
| `PSS_POT_ENABLED=0`(既定、未配線機体) | `readPotentiometerThreshold()`が内部で早期return、`config::kStatusThreshold`をそのまま返す。ADC APIに一切触れないためフローティングピンの影響を受けない(§5.3)。 |
| ポット未配線のまま`PSS_POT_ENABLED=1`で誤って書き込んだ | フローティングピンのADC値は不定(周辺ノイズ次第で0〜4095のどこにでも張り付き得る)。実行時の自動検出(分散チェック等)は行わず、`relay.cpp`と同じ「配線済みenvでのみビルドフラグを立てる」運用ルールのみで防ぐ。実装ステップ・レビュー観点に明記する(§9)。 |
| ADC平均値が0(可変抵抗を最小まで回した) | `computeThresholdFromAdc(0)`: `ratio=0` → `powf(x,0)=1` → `threshold = 30`(下限)。想定通り。 |
| ADC平均値が4095(可変抵抗を最大まで回した) | `computeThresholdFromAdc(4095)`: `ratio=1` → `powf(x,1)=500` → `threshold = 30×500 = 15000`(上限)。想定通り。 |
| ADC平均値が理論上4095をわずかに超える(仕様上は起こらないが防御的に) | `computeThresholdFromAdc()`内で`kAdcMax`にクランプしてから計算するため、`ratio`が1.0を超えて`threshold`が15000を超えることはない。 |
| ブートモード中(`#50`)に現地作業者がポットを回す | 意図した使い方。5スロットそれぞれで`readPotentiometerThreshold()`を再読込するため、回転操作の効果を最大約4分以内(次スロットまで最大60秒)に確認できる(§2.2)。 |
| GPIO2(D1/A1)を使用する | ストラッピングピンではないため通常のGPIO起動リスクはないと考えられるが、他のGPIOと同様の基本的な起動安定性確認は§8テスト項目5で行う(§6 #5)。 |

---

## 8. テスト計画

すべて実機`xiao-s3-aws-lte-relay-pot`env(リレー・LTE配線済み、Deep Sleep有効な本番相当
ビルド)で行う(v3: 専用の卓上デバッグenvは追加しない。§9参照)。卓上での事前確認・境界値
確認・起動安定性確認は、ブートモード(`#50`)が電源投入直後の最大約4分間Deep Sleepなしで
5回連続送信する性質を利用して行う。1回のブートモード窓(約4分)で確認しきれない場合は、
電源を入れ直せばコールドブートのたびにブートモードが再度発動する(`docs/50-boot-mode-design.md`
§2.1)ため、何度でも繰り返せる。

1. **卓上・単体動作確認**: 電源投入し、ブートモード窓(約4分、1分間隔で5回送信)の間に
   Grove - Rotary Angle Sensorを回しながらシリアルログを確認し、`potRaw`が0〜4095全域で
   滑らかに変化し、`threshold`が対数カーブ(低回転域で緩やか、高回転域で急峻)で追従する
   ことを確認する。4分間で全域を確認しきれない場合は電源を入れ直してブートモードを
   再度発動させる。
2. **境界値確認**: 同様にブートモード窓内でポットを両端いっぱいまで回し、`threshold`が
   ちょうど30・15000付近になることを確認する(§7のエッジケース検証)。
3. **未配線機体での回帰確認**: 既存の量産ファームウェア(`PSS_POT_ENABLED`未指定=既定`0`、
   ビルド変更不要)で、`doc["pot"]["enabled"]=false`・`doc["pot"]["adcRaw"]=0`・
   `doc["threshold"]`が従来通り`config::kStatusThreshold`(現行値100、または`#43`検討値13)
   になることを確認する。
4. **ブートモードとの連携確認**: コールドブート直後、ブートモードの5回の送信の間に
   実際にポットを回し、各スロットの`doc["pot"]["adcRaw"]`/`doc["threshold"]`が変化して
   送信されること、それに応じて`doc["status"]`(満/空/不明)が切り替わることを確認する
   (現地調整の主要ユースケース)。
5. **起動安定性の基本確認(D1/GPIO2、念のための確認)**: ポットを複数の角度(両端・中間の
   3〜5パターン)に固定した状態で電源投入を各10回程度繰り返し、毎回正常に
   `ESP_RST_POWERON`起動→センサー初期化→LTE接続まで到達することを確認する。D1(GPIO2)は
   ストラッピングピンではないため他のGPIOと同様以上のリスクは想定していない(§6 #5)が、
   通常のドッグフーディングの一環として実施する。
6. **消費電力確認**: ブートモード終了後の通常運用(Deep Sleep有効)に戻った状態で、電源
   ロガー(`tools/power-logger`)を用いてポット読み取り追加前後のアクティブ時間・電流波形を
   比較し、有意な増加がないことを確認する(`docs/50-boot-mode-design.md` §10.4のような
   実測ベースの評価を踏襲)。
7. **屋外実地確認**: 実際の設置現場で、現行の暫定閾値(100、または13)相当になるよう
   ポットを合わせた状態から、2026-08-25実証データ相当のr-g差分実測ログと突き合わせ、
   算出される`threshold`が妥当な範囲(飽和判定を誤らない範囲)に収まることを確認する。

---

## 9. 実装ステップ

1. `docs/60-potentiometer-threshold-design.md`(本ドキュメント)を確定として先にコミット
   する(`#47`/`#50`と同じ、設計docを先にコミットしてから実装するプロジェクト慣習)。
2. `firmware/include/board_xiao.h`に`POT_ADC_PIN`定義(D1/GPIO2)を追加(§3)。
3. `firmware/include/config.h`に`PSS_POT_*`マクロ+`config::kPot*`定数+`static_assert`を
   追加(§3)。
4. `firmware/include/potentiometer.h` / `firmware/src/potentiometer.cpp`を新規作成
   (§2.2/2.3/4.1)。
5. `firmware/src/main.cpp`: `#include "potentiometer.h"`追加、`setup()`に
   `initPotentiometer()`呼び出しを追加、`buildPayload()`/`publishWithRetry()`の
   シグネチャに`PotReading`パラメータを追加、`runCycle()`/`runBootMode()`両方の
   呼び出し箇所を更新(§4.2〜4.5)。`classify.h`/`classify.cpp`・`history_log.*`は変更しない。
6. `firmware/platformio.ini`に、本番投入用の新規env`xiao-s3-aws-lte-relay-pot`
   (`env:xiao-s3-aws-lte-relay`を`extends`し`-DPSS_POT_ENABLED=1`のみ追加)を**1つだけ**
   新設する(v3: 卓上テスト専用・実機ベンチデバッグ専用のenvは追加しない。§8参照)。
   反復速度に不満が出た場合は、既存の`xiao-s3-aws-lte-relay-debug`と同じパターンで
   `-pot-debug`亜種を後日追加できる(YAGNI)。
7. `xiao-s3-aws-lte-relay-pot`envの実機で§8テスト項目1・2・5を実施する。あわせて既存の
   量産ビルド(`PSS_POT_ENABLED`未指定=既定`0`)で§8テスト項目3を実施し、未配線機体相当の
   挙動に回帰がないことを確認する。
8. 同envの実機で§8テスト項目4を実施する。
9. 同envの実機で§8テスト項目6(消費電力確認)を実施する。
10. 現場設置後に同envの実機で§8テスト項目7を実施し、`PSS_POT_THRESHOLD_MIN`/`MAX`の
    妥当性を再検討する(§6 #1参照)。
11. `docs/data-model.md`の`threshold`フィールド説明・`sync.*`/`network.*`/`bootMode.*`の
    診断フィールド節(`docs/data-model.md:83`付近)に`pot.*`(`enabled`/`adcRaw`)を追記する。

### レビュー観点(実装レビュー時に確認すること)

- `classify.h`/`classify.cpp`が一切変更されていないこと(純粋ロジックとハードウェア
  依存の分離が保たれているか、§2.2/§5.1)。
- `PSS_POT_ENABLED=0`(既定)ビルドで、`analogRead()`/`analogSetPinAttenuation()`等の
  ADC APIが一切呼ばれないこと(未配線機体で不定なフローティング値を誤って使わないための
  最重要ガード、§5.3/§7)。
- `runCycle()`と`runBootMode()`の両方で`readPotentiometerThreshold()`が呼ばれ、
  どちらも同じ`PotReading`インスタンスを`classifyStatus()`と`buildPayload()`の両方に
  一貫して渡していること(片方だけ更新して閾値がズレる、という`#50`類似の回帰を避ける、
  §5.2)。
- `computeThresholdFromAdc()`の境界値(adc=0→30、adc=4095→15000)が仕様通りであること
  (§7)。
- `POT_ADC_PIN`がストラッピングピンではないGPIO2(D1/A1)になっていること、および
  基本的な起動安定性が実機(§8テスト項目5)で確認されていること。
- 新規env`xiao-s3-aws-lte-relay-pot`がポット未配線の既存本番機体のenv
  (`xiao-s3-aws-lte-relay`)から独立しており、既存機体のビルド・書き込みフローに
  影響しないこと。
