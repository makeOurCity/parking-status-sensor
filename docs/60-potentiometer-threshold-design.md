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
| v3 | ユーザー判断により、`platformio.ini`への新規env追加を**本番投入用の`xiao-s3-aws-lte-relay-pot`1つのみ**に簡略化(卓上テスト専用・実機ベンチデバッグ専用のenvは追加しない)。卓上での事前確認・起動安定性確認は、専用デバッグenvの代わりに既存のブートモード(`#50`、電源投入直後の最大4分間はDeep Sleepなしで5回連続送信する)を利用する方針に変更し、§8テスト計画・§9実装ステップを単一env前提に書き直した。反復速度に不満が出た場合は、既存の`xiao-s3-aws-lte-relay-debug`と同じパターンで`-pot-debug`亜種を後日追加できる(YAGNI)。 |
| v4 | 実機検証(§10)を追加。ブートモード・通常運用でのAWS IoT Core経由の送受信を確認した一方、電源ロガーでの実測により**ポットを常時接続したままだとDeep Sleep待機電流が0.45mA→0.75mAへ増加する**ことが判明。`PSS_CHANGE_ONLY_SEND`/`PSS_HEARTBEAT_CYCLES`を反映して稼働日数を再試算した結果、定常運用で約19%(24日分)の低下という結論に至った(§2.6・§6 #6に参照を追記、`docs/hardware.md`の稼働日数試算表も合わせて更新)。当初は「調整完了後に`PSS_POT_ENABLED=0`+確定値で最終再書き込みしてからケーブルを抜く」運用を推奨していたが、v5でより良い設計に置き換えた。 |
| v5 | ユーザー提案により設計変更: **ADCの生読みをブートモード(`#50`)の5回の送信時だけに限定し、結果をNVSへ永続化。通常サイクル(`runCycle()`)はNVSの値を使うだけでADCには一切触れない**設計に変更した(§2.2/§2.7)。これにより、v4で推奨していた「最終書き込みして`PSS_POT_ENABLED=0`に切り替える」手順が不要になり、**ブートモード完了後はいつでもケーブルを抜いてよい**(NVSに既に永続化済みのため、フローティングピンの不定値を拾わない)。`potentiometer.h/cpp`に`readPotentiometerThresholdLive()`(ブートモード専用、生読み+NVS永続化)と`currentPotThreshold()`(通常サイクル専用、NVS値を返すだけ)を新設し、`readPotentiometerThreshold()`を置き換えた。あわせて、ケーブル撤去後に物理的な電源サイクル(バッテリー交換等)が発生した場合の考慮(§2.7)と、実際の運用ではLiPoを抜かずにUSB-C充電で完結する(`docs/hardware.md`記載のETA6003によるハードウェアのみの充電、システム電源の瞬断なし)ため、この考慮は実質的に問題にならないことを明記した。さらに§11として、リレー(#46)の空きチャンネルにポットのVCCを通し、ケーブルの抜き差し自体を不要にしつつDeep Sleep中のリーク電流も自動的にゼロにするハードウェア拡張案(ユーザー提案)を、コードベース調査による裏付け(制御GPIOが1本のみ・製品名が「2-Coil」であること等、2回路がDPDT的に連動する状況証拠)とともに記録した(実機未検証、本PRのスコープ外・別Issue候補)。 |
| v6 | v5実機検証(§10.1)を追加: ブートモード完了後につまみを回しても`threshold`/`pot.adcRaw`が一切変化しないことを確認し、§8テスト項目8(ケーブル抜去確認)の意図を同等以上の方法で満たしたと判断。ユーザー判断により、§8テスト項目7(屋外実地確認)を本PRのスコープ外とし、テスト項目8(物理的なケーブル抜去)は追加確認不要と結論。一方、**電源投入直後にLTE-M/センサーの接続が安定するまで複数回の電源再投入が必要になる事象が、別々のテストセッションで複数回observed**されたため、§6 #7として新たに記録。当初「一過性の接触不良」と判断していたが、v5検証時にも再発したため根本原因は未解明のまま残っていることを明記し、§8テスト項目5は「未解決」のまま完了扱いとしないことにした。この状態でPRをマージした(#61)。起動安定性の懸念は別Issue([#63](https://github.com/makeOurCity/parking-status-sensor/issues/63))として起票済み。 |
| v7 | §2.7の「充電時にシステム電源が瞬断しない」という前提を、電源ロガーの実測で裏付け。USB-C接続時に約65秒間-413.5mAの定電流充電(3903mV→4007mV)が観測され、充電の前後でDeep Sleep放電電流(0.44mA)に乱れなく復帰することを確認した。 |
| v8(本版) | §11(リレー空きチャンネルによるポット電源のハードウェア遮断)を「将来の拡張案」から「**実装済み・動作確認済み**」に更新。実機検証(§10.1)時点で既にこの配線が施されていたことが後日判明し、後続の電源ロガー実測でDeep Sleep中の待機電流が一貫して300〜450µA(ポットなし相当)に収まっていることを確認した(§11.6)。§10.2で報告した0.75mAの生ログは、その後の`pio device monitor > file`再実行によるファイル上書きで失われているが、測定自体は当時実施したものであり、§1〜§11の記述内容(0.75mAの実測含む)自体に変更はない。 |

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
// ブートモード(#50)の5回の送信の間だけADCを生読みしてNVSへ永続化し、それ以降の通常
// サイクルはNVSの値を使い続ける(ADCには一切触れない)。詳細は§2.7参照。
struct PotReading {
  uint16_t raw = 0;                        // 0-4095、平均済みADC値
                                            // (kPotEnabled=falseの場合は常に0)
  int threshold = 0;                       // rawから算出した実効閾値
                                            // (kPotEnabled=falseの場合はconfig::kStatusThreshold)

  // デフォルトメンバ初期化子付きの集成体は2引数の波括弧初期化
  // (`PotReading{raw, threshold}`)に使えないため、main.cpp既存の
  // BootModeSendInfo(main.cpp:150-158)と同じパターンで明示的コンストラクタを持つ。
  PotReading() = default;
  PotReading(uint16_t rawIn, int thresholdIn) : raw(rawIn), threshold(thresholdIn) {}
};

// setup()から1回呼ぶ。ADCのアッテネーション設定 + NVSに永続化済みの値のロードを行う。
void initPotentiometer();

// runBootMode()専用。ADCを生読みし、結果をNVSへ永続化してから返す。
PotReading readPotentiometerThresholdLive();

// runCycle()専用。ADCには一切触れず、initPotentiometer()でロード済み(直近の
// readPotentiometerThresholdLive()呼び出しでNVSに永続化された)値を返す。
PotReading currentPotThreshold();

// 単体で境界値確認しやすいよう、対数マッピングだけを切り出した純粋関数。
int computeThresholdFromAdc(uint16_t adc);
```

呼び出しタイミング: `initPotentiometer()`は`relay.h`の`initRelay()`と同じく`setup()`から
1回(ボード起床のたび、すなわちDeep Sleep復帰のたびに`setup()`ごと再実行される)呼ぶ。

**v5で変更(ユーザー提案)**: `readPotentiometerThreshold()`を`runCycle()`と
`runBootMode()`の両方で呼ぶ、というv1〜v4の設計は、「調整完了後にケーブルを抜くと
フローティングピンの不定値を拾ってしまう」という運用上の弱点があった(v4時点では
「最後に`PSS_POT_ENABLED=0`+確定値で再書き込みしてから抜く」手順で回避していたが、
再書き込みという追加コストが発生する)。v5では、ADCを生読みするのは
**`runBootMode()`の5回のスロットのみ**とし、読むたびに結果を**NVSへ永続化**する
(`readPotentiometerThresholdLive()`)。`runCycle()`(以降の全ての通常サイクル)は
ADCに一切触れず、NVSに永続化済みの値をそのまま使う(`currentPotThreshold()`)。

これにより:
- ブートモード完了後は**いつでもケーブルを抜いてよい**(直近の値が既にNVSに書き込み
  済みのため、フローティングピンの不定値を拾うことがない)。
- 再調整したい場合は、ポットを挿し直して物理的に電源を入れ直す(電池抜き差し等)だけで
  よい。ブートモードが`ESP_RST_POWERON`で自動的に再発動する(`#50`の既存機構をそのまま
  流用、追加のトリガー機構は不要)。
- 再書き込み(ビルド・USB接続)は一切不要になる。

詳細な運用手順・関連する考慮事項は§2.7を参照。

ブートモード(`#50`)は電源投入直後の最大4分間、1分おきに5回連続送信する機能であり、この間に
現地作業者がポットを回しながらクラウド側/シリアルログで判定結果の変化をほぼリアルタイムに
確認できることは、本Issueが解決したい「現地調整の往復コスト」を最小化する副次効果になる。

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
#include <Preferences.h>
#include <math.h>

#include "board.h"
#include "config.h"

namespace {

constexpr uint16_t kAdcMax = 4095;

// sync_ledger.cpp/history_log.cppと同じPreferences(NVS)パターン。
constexpr char kNamespace[] = "pss_pot";
constexpr char kKeyRaw[] = "raw";
constexpr char kKeyThreshold[] = "thr";

// initPotentiometer()でNVSからロードし、readPotentiometerThresholdLive()で更新する。
// currentPotThreshold()はこれをそのまま返すだけでADCには触れない。
PotReading cached;

void persist(const PotReading& reading) {
  Preferences prefs;
  prefs.begin(kNamespace, false);
  prefs.putUShort(kKeyRaw, reading.raw);
  prefs.putInt(kKeyThreshold, reading.threshold);
  prefs.end();
}

}  // namespace

void initPotentiometer() {
  if (!config::kPotEnabled) {
    cached = PotReading(0, config::kStatusThreshold);
    return;
  }
  analogReadResolution(12);
  analogSetPinAttenuation(POT_ADC_PIN, ADC_11db);

  Preferences prefs;
  prefs.begin(kNamespace, true);
  const bool hasStored = prefs.isKey(kKeyThreshold);
  const uint16_t raw = prefs.getUShort(kKeyRaw, 0);
  const int threshold = prefs.getInt(kKeyThreshold, config::kStatusThreshold);
  prefs.end();
  // ブートモードがまだ一度もADCを読んでいない初回起動は、既定の固定値にフォールバックする。
  cached = hasStored ? PotReading(raw, threshold)
                     : PotReading(0, config::kStatusThreshold);
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

PotReading readPotentiometerThresholdLive() {
  if (!config::kPotEnabled) {
    return cached;  // {0, config::kStatusThreshold}(initPotentiometer()で設定済み)
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
  cached = PotReading(avg, computeThresholdFromAdc(avg));
  persist(cached);
  return cached;
}

PotReading currentPotThreshold() { return cached; }
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
- `readPotentiometerThresholdLive()`/`currentPotThreshold()`(v5、§2.2/§2.7)は
  いずれも内部で`config::kPotEnabled`を判定して`config::kStatusThreshold`をそのまま
  返すため、呼び出し元(`runCycle()`/`runBootMode()`)は分岐を書かずに済み、
  `relayLteOn()`等と同様「呼び出しは常に行い、有効/無効の判定は関数内部に閉じる」
  という既存の設計言語を踏襲できる。

`main.cpp`側の呼び出し箇所2箇所(`runCycle()`: `main.cpp:434`、`runBootMode()`:
`main.cpp:588`)を、それぞれ`currentPotThreshold()`/`readPotentiometerThresholdLive()`
(v5)で得た`PotReading.threshold`を渡す形に変更する(§4.2/4.3)。

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
`readPotentiometerThresholdLive()`(v5、ブートモード専用)内の8回×2ms=16ms程度の
サンプリング間隔は、ノイズ平滑化目的の遅延であってハードウェア安定待ちではない。
`currentPotThreshold()`(v5、通常サイクル用)はADCに一切触れないためこの遅延自体も
発生しない。

`kPotSampleCount=8`回の`analogRead()`自体は1回あたりマイクロ秒オーダーであり、
`initSensor()`の1500ms安定待ちや、LTE接続フェーズ(数秒〜数十秒)と比べて無視できるコスト
増分である。Issueの「消費電力への影響はほぼ無視できる」という見立ては、**ADC読み取り自体の
所要時間**については実機でも妥当と確認された(§10.2)。

一方、これとは別に、**ポット(抵抗分圧器)がGroveポートの3V3ラインから常時電流を消費する**
ことによるDeep Sleep待機電流の増加は、本項執筆時点では想定していなかった論点である。
実機実測でこちらは無視できない規模であることが判明した(§10.2/§10.3、§6 #6)。

呼び出し位置は`readSensor(sample)`直後・`classifyStatus()`直前とする(`initSensor()`の
成否判定より後)。センサーI2C初期化に失敗した場合(`kSensorError`)は元々`classifyStatus()`
に到達せず送信もしないため、ポット読み取りもそのケースでは行わない(無駄なADC読み取りを
避ける)。

### 2.7 現地調整完了後の運用(NVS永続化・v5)

v4までは「調整完了後にケーブルを抜くと閾値が壊れる」問題への対策として、
「`PSS_POT_ENABLED=0`+確定値で最終再書き込みしてから抜く」手順を推奨していた。
v5ではユーザー提案により、**ADCの生読みをブートモード(`#50`)の5回の送信時だけに
限定し、結果をNVSへ永続化する**設計に変更し、再書き込みという追加コストを解消した
(§2.2/§4.1参照)。

**確立された運用手順**:

1. 現地でポットを回し、テレメトリ(`pot.adcRaw`/`threshold`)を見ながら値を決定する
   (ブートモードの5回の送信、電源投入から最大約4分間)。
2. ブートモードが完了した時点で、その最後の値が既にNVSへ永続化されている。
   **以降はいつでもGroveケーブルを抜いてよい**(`runCycle()`はADCに一切触れず、
   NVSの値をそのまま使い続けるため、フローティングピンの不定値を拾わない)。
3. 再調整したい場合は、ポットを挿し直してから物理的に電源を入れ直す
   (電池抜き差し等)。`ESP_RST_POWERON`でブートモードが自動的に再発動し、
   新しい値がNVSに上書きされる。

**検討した懸念(結論: 実運用では問題にならない)**: ケーブルを抜いた後に何らかの理由で
物理的な電源サイクル(`ESP_RST_POWERON`)が発生すると、ブートモードが再発動して
フローティングピンを読み、NVSの正しい値を不定値で上書きしてしまうおそれがある。
この点について検討した結果、以下の理由で実運用上の問題にはならないと判断した:

- 本プロジェクトの通常のバッテリー充電手順は、**LiPoを抜かずにUSB-Cを接続する**方式
  である。Grove Shield上の充電IC ETA6003がハードウェアのみで充電を完結させ、
  `docs/hardware.md`に記載の通り「ESP32S3がDeep Sleep中かどうかに関わらず充電は継続する」
  ため、**充電のためにシステム電源が瞬断・リセットされることはない**。つまり定期的な
  バッテリー充電(この運用では約100日ごと、`docs/hardware.md`稼働日数試算参照)は
  `ESP_RST_POWERON`を発生させず、ブートモードも再発動しない。
- LiPoが完全に枯渇した場合(通常運用では想定しない障害系)は、装置が電源を失う。
  この場合の復旧は「NVSの値が破損する」という個別の問題ではなく、**ポットを接続し直して
  初期設定からやり直す**という、より上位の再セットアップ手順の一部として自然に解決する
  (このケースでは元々ポットを挿し直すことが前提のフローになるため)。

したがって、リレー(#46)のような追加ハードウェアや、NVS書き込みの信頼性を上げるための
追加のファームウェア機構(フローティング検出等、§6 #6で検討し不採用とした)は不要と
判断する。

**実測による裏付け(2026-09-20)**: 上記の「充電時にシステム電源が瞬断しない」という
前提を、電源ロガー(`tools/power-logger`)の実測で確認した。USB-C接続時、約65秒間
-413.5mAの定電流(バッテリーへの充電方向)が流れ、電圧が3903mV→4007mVへ滑らかに
上昇する、典型的なLiPoのCC充電プロファイルが観測された。充電の開始・終了前後で
通常のDeep Sleep放電電流(0.44mA)にきれいに復帰しており、リセットやブラウンアウトを
示すような電流の乱れは見られなかった。これにより、本節の結論(バッテリー充電が
ブートモードの再発動=NVSの意図しない上書きを引き起こさないこと)は、文献・仕様上の
推測だけでなく実測でも裏付けられた。

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
  const PotReading potReading = currentPotThreshold();  // #60: NVS永続化済みの値(ADCには触れない)
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
    const PotReading potReading = readPotentiometerThresholdLive();  // #60: スロットごとに生読み+NVS永続化
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

`runBootMode()`は「`readSensor()`直後→`readPotentiometerThresholdLive()`(生読み+NVS
永続化)→`classifyStatus()`→(送信する場合は)`buildPayload()`に同じ`potReading`を渡す」、
`runCycle()`は「`readSensor()`直後→`currentPotThreshold()`(NVSの値をそのまま返す)→
`classifyStatus()`→`buildPayload()`」という順序を踏む(v5、§2.2/§2.7)。呼び出す関数は
異なるが、**いずれも「1回のスロット/サイクルにつき1回だけ`PotReading`を取得し、
`classifyStatus()`とペイロードの両方に同じ値を渡す」という構造は共通**であり、
`#50`ブートモード設計時に発生した「`metrics.transport`がスロットによって不整合になる」
類の回帰(`docs/50-boot-mode-design.md` §2.3)と同種の問題(片方だけ新しい値、もう片方は
古い値、というズレ)は起きない。

### 5.3 `config::kPotEnabled=false`時はADCに一切触れない

`readPotentiometerThresholdLive()`/`currentPotThreshold()`はいずれも`config::kPotEnabled`
が偽の場合、`analogRead()`を含むADC API呼び出しを一切行わずに`initPotentiometer()`で
設定済みの`PotReading(0, config::kStatusThreshold)`を返す(`relay.cpp`の`initRelay()`/
`relayLteOn()`が`kLtePowerRelayEnabled`で早期returnするのと同一パターン)。既存の
稼働機体(`PSS_POT_ENABLED`未指定=既定`0`)は、この変更によって挙動が一切変わらない
(`doc["threshold"]`は従来通り`config::kStatusThreshold`のまま)。

### 5.5 通常サイクルはADCに一切触れない(v5)

v5では`currentPotThreshold()`(`runCycle()`から呼ばれる)がNVSにキャッシュ済みの
`PotReading`をそのまま返すだけの実装になっており、`config::kPotEnabled`の真偽に
関わらず`analogRead()`等のADC APIを一切呼ばない。ADCに触れるのは
`readPotentiometerThresholdLive()`(`runBootMode()`専用)のみである。これにより、
ブートモード完了後にGroveケーブルを抜いても、通常サイクルの動作(NVSの値を読むだけ)
には一切影響しない(§2.7)。

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
| 6(v4で発見、実機実測、v5/§11で対策確定) | ポットを現地調整後も常時接続したままにすることの消費電力への影響 | 実測(§10.2)により、Deep Sleep待機電流が0.45mA→0.75mAへ増加することが判明。`PSS_CHANGE_ONLY_SEND`/`PSS_HEARTBEAT_CYCLES`を反映した再試算(§10.3)では、定常運用で稼働日数が約19%(24日分)低下する。**v5のNVS永続化により、ブートモード完了後はいつでもケーブルを抜いてよい**(§2.7)ため、この影響は「ケーブルを抜けば回避できる」問題として解決した。さらに、ハードウェア側でポット電源自体を自動遮断する対策(リレー(#46)の空きチャンネル活用)は**既に実装済みであり、実機での事後確認によりリークが解消されていることを確認した**(§11、特に§11.6)。ケーブルを常時接続したままでも稼働日数への影響がない状態になっている。 |
| 7(v6で発見、#63で机上調査済み・実機確認待ち) | 電源投入直後、リレー/LTE-Mが安定して動作するまでに複数回の電源再投入が必要になることがある | 実機検証中(§10.1)、書き込み・電源投入直後に`LTE modem.init() failed`の繰り返しや`sensor_error`が発生し、ブートモードが正常完了するまでに複数回電源を入れ直す場面が複数回(別々のテストセッションで)観測された。当初は「一過性の接触不良」と判断していたが(§10.1)、v5の検証時にも同様の事象が再発したため、**単発の偶発事象と決めつけず、根本原因が未解明のまま残っている**と認識を改めた。別issue([#63](https://github.com/makeOurCity/parking-status-sensor/issues/63))として切り出し、firmware/のコード・PlatformIOの書き込み設定・リレーモジュール(Seeed 103020010)の公式回路図まで掘り下げた机上調査を実施した結果、**esptool書き込み時のGPIO1 Hi-Z滞留とリレーSIGピンの弱いプルダウン(100kΩ)の組み合わせによるエッジ検出回路の誤発火**という有力仮説と、**書き込み時はリレーのGroveケーブルを外す**という実用的な回避策が得られた(詳細は[issueコメント](https://github.com/makeOurCity/parking-status-sensor/issues/63#issuecomment-5752199383)参照、実機オシロスコープでの最終確認は未実施)。本Issue(#60、ポット機能自体)のスコープでは対応せず、追加調査・対策の実装は#63側で追跡する。§8テスト項目5(起動安定性の反復確認)は、実機確認が済んでいないため引き続き「未解決のまま」とし、実施完了とはしない。 |

---

## 7. エッジケース対応

| ケース | 対処 |
|---|---|
| `PSS_POT_ENABLED=0`(既定、未配線機体) | `currentPotThreshold()`/`readPotentiometerThresholdLive()`が内部で早期return、`config::kStatusThreshold`をそのまま返す。ADC APIに一切触れないためフローティングピンの影響を受けない(§5.3)。 |
| ポット未配線のまま`PSS_POT_ENABLED=1`で誤って書き込んだ | フローティングピンのADC値は不定(周辺ノイズ次第で0〜4095のどこにでも張り付き得る)。実行時の自動検出(分散チェック等)は行わず、`relay.cpp`と同じ「配線済みenvでのみビルドフラグを立てる」運用ルールのみで防ぐ。実装ステップ・レビュー観点に明記する(§9)。 |
| ADC平均値が0(可変抵抗を最小まで回した) | `computeThresholdFromAdc(0)`: `ratio=0` → `powf(x,0)=1` → `threshold = 30`(下限)。想定通り。 |
| ADC平均値が4095(可変抵抗を最大まで回した) | `computeThresholdFromAdc(4095)`: `ratio=1` → `powf(x,1)=500` → `threshold = 30×500 = 15000`(上限)。想定通り。 |
| ADC平均値が理論上4095をわずかに超える(仕様上は起こらないが防御的に) | `computeThresholdFromAdc()`内で`kAdcMax`にクランプしてから計算するため、`ratio`が1.0を超えて`threshold`が15000を超えることはない。 |
| ブートモード中(`#50`)に現地作業者がポットを回す | 意図した使い方。5スロットそれぞれで`readPotentiometerThresholdLive()`を再読込・NVS永続化するため、回転操作の効果を最大約4分以内(次スロットまで最大60秒)に確認できる(§2.2)。 |
| GPIO2(D1/A1)を使用する | ストラッピングピンではないため通常のGPIO起動リスクはないと考えられるが、他のGPIOと同様の基本的な起動安定性確認は§8テスト項目5で行う(§6 #5)。 |
| ブートモード完了後にGroveケーブルを抜く(v5、想定される主要な運用) | 安全。`currentPotThreshold()`はADCに一切触れず、直近のブートモードでNVSに永続化された値をそのまま使い続ける(§2.7)。 |
| ケーブル撤去後に物理的な電源サイクルが発生する | ブートモードが再発動し、フローティングピンを読んでNVSの値を不定値で上書きするおそれがある。ただし本プロジェクトの通常のバッテリー充電はLiPoを抜かずUSB-C接続のみで完結する(システム電源の瞬断なし)ため、通常運用では発生しない。LiPo完全枯渇時は初期設定からのやり直し(ポット再接続)が前提となるため問題にならない(§2.7で詳細に検討)。 |
| `PSS_POT_ENABLED=1`だが`PSS_BOOT_MODE_ENABLED=0`のビルド(非推奨の組み合わせ) | `readPotentiometerThresholdLive()`が一切呼ばれず、NVSに値が永続化されないため`currentPotThreshold()`は常に`initPotentiometer()`時点のフォールバック値(`config::kStatusThreshold`)を返し続ける。ポット機能が実質的に無効化された状態になる。`PSS_BOOT_MODE_ENABLED`は既定で`1`であり、ポット有効機体でこれを`0`にする運用は想定していない(組み合わせる場合は別途対応を検討)。 |

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
5. **起動安定性の基本確認(D1/GPIO2、念のための確認)** — **未解決のまま(§6 #7参照)**:
   ポットを複数の角度(両端・中間の3〜5パターン)に固定した状態で電源投入を各10回程度
   繰り返し、毎回正常に`ESP_RST_POWERON`起動→センサー初期化→LTE接続まで到達することを
   確認する。D1(GPIO2)自体はストラッピングピンではないため他のGPIOと同様以上のリスクは
   想定していない(§6 #5)が、**実機検証中に電源投入直後の接続失敗(`LTE modem.init()
   failed`の繰り返しや`sensor_error`)が複数回のテストセッションで再発しており、複数回の
   電源再投入が必要になる場合があることを確認した**(§6 #7、§10.1)。GPIO2/ポット自体が
   原因という証拠はない(ソースコード上はGPIO2以外に触れない実装であることを確認済み、
   §10.1)が、根本原因は未解明であり、本項目は完了とはしない。現状の回避策は電源の
   入れ直しのみ。今回のPRのスコープでは対応せず、既知の懸念事項として記録するに留める。
6. **消費電力確認** — **実施済み(§10.2/§10.3)**: ブートモード終了後の通常運用
   (Deep Sleep有効)に戻った状態で、電源ロガー(`tools/power-logger`)を用いてポット
   読み取り追加前後のアクティブ時間・電流波形を比較する(`docs/50-boot-mode-design.md`
   §10.4のような実測ベースの評価を踏襲)。**結果: 有意な増加あり**(Deep Sleep待機電流
   0.45mA→0.75mA)。詳細・対応方針は§10.2/§10.3/§2.7参照。
7. **屋外実地確認** — **本PRのスコープ外**: 実際の設置現場で、現行の暫定閾値(100、
   または13)相当になるようポットを合わせた状態から、2026-08-25実証データ相当の
   r-g差分実測ログと突き合わせ、算出される`threshold`が妥当な範囲(飽和判定を誤らない
   範囲)に収まることを確認する。現地設置のタイミングで別途実施する。
8. **ケーブル抜去後の閾値保持確認(v5、NVS永続化)** — **実施済み(同等の代替方法で)**:
   ブートモード完了後にGroveケーブルを物理的に抜き、その後の通常サイクルで
   `doc["threshold"]`が変化しないことを確認する想定だったが、**実機検証では「ケーブルを
   抜く」代わりに「ブートモード完了後にポットのつまみを回す」方法で同等以上の確認を
   行った**(§10.1)。`currentPotThreshold()`はADCに一切触れない実装(§5.5)のため、
   「つまみを回しても変化しない」ことは「ケーブルを抜いても変化しない」ことの十分条件
   であり、物理的なケーブル抜去による追加確認は不要と判断する。

---

## 9. 実装ステップ

1. `docs/60-potentiometer-threshold-design.md`(本ドキュメント)を確定として先にコミット
   する(`#47`/`#50`と同じ、設計docを先にコミットしてから実装するプロジェクト慣習)。
2. `firmware/include/board_xiao.h`に`POT_ADC_PIN`定義(D1/GPIO2)を追加(§3)。
3. `firmware/include/config.h`に`PSS_POT_*`マクロ+`config::kPot*`定数+`static_assert`を
   追加(§3)。
4. `firmware/include/potentiometer.h` / `firmware/src/potentiometer.cpp`を新規作成
   (§2.2/2.3/4.1)。`Preferences`(NVS)による永続化(`readPotentiometerThresholdLive()`)と
   キャッシュ読み出し(`currentPotThreshold()`)を実装する(v5)。
5. `firmware/src/main.cpp`: `#include "potentiometer.h"`追加、`setup()`に
   `initPotentiometer()`呼び出しを追加、`buildPayload()`/`publishWithRetry()`の
   シグネチャに`PotReading`パラメータを追加、`runBootMode()`は
   `readPotentiometerThresholdLive()`、`runCycle()`は`currentPotThreshold()`を
   呼ぶよう更新する(§4.2〜4.5、v5)。`classify.h`/`classify.cpp`・`history_log.*`は
   変更しない。
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
- `runBootMode()`は`readPotentiometerThresholdLive()`、`runCycle()`は
  `currentPotThreshold()`を呼び、いずれも同じ`PotReading`インスタンスを
  `classifyStatus()`と`buildPayload()`の両方に一貫して渡していること(片方だけ更新して
  閾値がズレる、という`#50`類似の回帰を避ける、§5.2)。
- `computeThresholdFromAdc()`の境界値(adc=0→30、adc=4095→15000)が仕様通りであること
  (§7)。
- `POT_ADC_PIN`がストラッピングピンではないGPIO2(D1/A1)になっていること、および
  基本的な起動安定性が実機(§8テスト項目5)で確認されていること。
- `currentPotThreshold()`(`runCycle()`用)が`analogRead()`等のADC APIを一切呼ばず、
  NVSからロード済みのキャッシュを返すだけであること(v5、§5.5、ケーブル抜去後の
  安全性の要となる最重要ガード)。
- ブートモード完了後にGroveケーブルを抜いても、直後の通常サイクルで`threshold`が
  ブレないこと(§8テスト項目8)。
- 新規env`xiao-s3-aws-lte-relay-pot`がポット未配線の既存本番機体のenv
  (`xiao-s3-aws-lte-relay`)から独立しており、既存機体のビルド・書き込みフローに
  影響しないこと。

---

## 10. 実機検証結果(2026-09-20)

### 10.1 動作確認(ブートモード・通常運用)

実機(`xiao-e83dc1fb05fc`、リレー・LTE配線済み、iPad版満空表示灯シミュレーター(#54)に
カラーセンサーを貼付)に`xiao-s3-aws-lte-relay-pot`を書き込み、AWS IoT Core→Lambda
ブリッジ→CloudWatch Logs(`/aws/lambda/parking-status-bridge`)で受信を確認した。

- **未配線相当の回帰確認**(`xiao-s3-aws-lte-relay`、ポット無効、§8テスト項目3): ブート
  モード5スロットすべて正常送信。`threshold`は従来通り固定値100、`pot.enabled=false`の
  まま。既存機体への影響なしを確認。
- **ポット有効ビルドでのブートモード連携確認**(§8テスト項目4): ブートモード5スロット
  すべて正常送信・CloudWatchで受信確認。`pot.adcRaw=0`・`threshold=30`が一貫して
  ペイロードに反映され、途中でiPadシミュレーターの表示を切り替えたところ
  `unknown`→`full`へ正しく判定が変化した。
- **通常運用(ブートモード終了後)での状態変化検知**: `bootMode.active=false`・
  `wakeCause=timer`・`resetReason=deep_sleep`の通常サイクルでも、`pot`設定
  (`threshold=30`)を引き継いだまま、`PSS_CHANGE_ONLY_SEND`との組み合わせで
  iPadシミュレーターの表示切り替え(空↔満)のたびに正しく送信されることを確認した。
- **v5実機検証(NVS固定の決定的確認)**: v5ファームウェア書き込み後、ブートモード5スロット
  すべて正常送信を確認。ブートモード完了後(通常サイクルに移行後)にポットのつまみを
  回したが、直後の通常サイクル(`bootMode.active=false`・`wakeCause=timer`・
  `resetReason=deep_sleep`)で`threshold=30`・`pot.adcRaw=0`のまま**一切変化しない**
  ことを確認した(`currentPotThreshold()`がADCに一切触れない実装であることの実機での
  裏付け、§5.5)。その後、iPadシミュレーターの状態変化(満→空→満)で`PSS_CHANGE_ONLY_SEND`
  によるリレー起動・LTE-M接続・publishが発生した際も、`threshold`/`pot.adcRaw`は一貫して
  保持されたままだった。「ケーブルを物理的に抜く」代わりに「つまみを回す」という同等以上に
  厳しい確認方法で、§8テスト項目8の意図を満たしたと判断する。

**起動安定性に関する未解決の懸念(§6 #7、v6で記録)**: 実機検証中、電源投入・書き込み
直後に`LTE modem.init() failed`の繰り返しや`sensor_error`が発生し、ブートモードが
正常に完了するまでに複数回の電源再投入が必要になる事象が、**別々のテストセッションで
複数回**観測された。

- 1回目(ポット有効ビルド初回書き込み時): LTE-M接続が繰り返し失敗。Arduino-ESP32の
  ソース(`esp32-hal-adc.c`/`esp32-hal-gpio.c`)を確認し、`analogRead()`/
  `analogSetPinAttenuation()`が内部で呼ぶ`pinMode(pin, ANALOG)`は指定したGPIO(本設計
  ではGPIO2)のみを対象とし、リレー信号線(GPIO1)には一切触れない実装であることを
  ソースレベルで確認し、コード起因の可能性は排除した。再書き込み後は再現せず、当初は
  「一過性の接触不良」と判断していた。
- 2回目(v5ファームウェア書き込み時): 電源投入直後に`sensor_error`が1回記録された後、
  約65秒後に**別の電源投入(`bootCount`が再び1から始まる)**でブートモードが正常に
  完了した(§10.1のログ参照)。

この2回目の再発により、**「一過性の接触不良」という1回目の判断だけでは説明が
不十分な可能性がある**と認識を改めた。GPIO2/ポット機能自体が原因である具体的な証拠は
見つかっていない(ソースコード上はGPIO2以外に触れない実装であることは確認済み)が、
根本原因(コールドブート直後のLTE-M電源安定化タイミング、リレー動作のばらつき、
その他)は未解明のまま残っている。現状の回避策は電源の入れ直しのみ。**本Issue(#60)の
スコープでは対応せず、既知の懸念事項として記録した上でPRをマージする**方針とする
(§8テスト項目5は完了扱いとしない)。屋外実地確認(§8テスト項目7)は本PRのスコープ外
とし、現地設置のタイミングで別途実施する。

**追記(2026-09-21、[#63](https://github.com/makeOurCity/parking-status-sensor/issues/63)で机上調査)**:
上記の事象は「Firmware書き込み直後にのみ」発生し、書き込み後にリレーが一度でも正常に
切り替わればそのセッション中は再現しない、という追加の目視事実が得られた。firmware/の
コード・PlatformIOの書き込み設定・リレーモジュール(Seeed 103020010)の公式回路図まで
掘り下げた結果、esptoolの書き込み時にチップがブートローダに数秒間滞留してGPIO1が
Hi-Zになり、リレーSIGピンの弱いプルダウン(100kΩ)経由でしか既知の状態に戻らないため、
エッジ検出回路(コンデンサ結合、時定数約47ms)が部分的にしか発火しない、という仮説に
至った(実機オシロ確認は未実施)。実用的な回避策として、**書き込み時はリレーのGrove
ケーブルを外しておく**ことを推奨する。

外部調査でも、(a) Espressif公式のesptoolトラブルシューティングドキュメントが
「書き込み中にGPIOへ外部デバイスを接続していると問題が起きうるので外して試せ」と
明記していること、(b) ESP32-S3のネイティブUSB-CDC/JTAGの自動リセットがclassic
UART-bridge基板より信頼性が低いという複数の報告があること、(c) コンデンサ結合の
エッジ検出回路が遅い信号で誤発火することが一般電子工学として知られていること、
(d) 同じ「LEDは反応するが機械的に切り替わらない」症状パターンが別のGrove Relay製品で
独立に報告されていること、という4点の裏付けが見つかった(ピンポイントで同一事例は
なし)。詳細は#63の調査コメントを参照。

**追記(2026-10-02、[#90](https://github.com/makeOurCity/parking-status-sensor/issues/90)・[#88](https://github.com/makeOurCity/parking-status-sensor/issues/88)で訂正)**:
[#87](https://github.com/makeOurCity/parking-status-sensor/issues/87)の調査で、リレーモジュールの回路図(Seeed公式Eagle v1、2013年)を
改めて読み、簡易シミュレーション(実機未確認)をした結果、上の仮説と恒久対策の
一部は**そのままでは採用できない**ことが分かった。

- **「Hi-Zの緩い遷移で部分発火」仮説は、このモデルでは再現しなかった。** SIGが
  100kΩのプルダウンだけで減衰しても、SET側(立ち下がり)のトランジスタを動かすには
  電流が足りず、SETは起きない(コイル電流はほぼ0)。実機のオシロ確認は未実施のため、
  棄却ではなく「支持されない」にとどめる。
- **「SIG-GND間に4.7〜10kΩのプルダウンを追加する」恒久対策案(#63のコメント)は、
  勧めない。** モデルでは15kΩ以下だと、Deep SleepでGPIOがHi-Zになるたびに
  SET(LTE ON)が出る。既存の100kΩのままが安全側。実測前は変更しない。
- **LEDが光ることは、コイルに十分な電流が流れた証拠にならない。** LEDはコイルと別の
  経路(約0.5mA)で光る。上の「LEDは点滅するがカチッと鳴らない」症状は、
  コイルの電圧不足・断線・機械的な固着でも起きる。
- **リレーは5V定格で、3.3Vで駆動している。** SET側は特に電圧余裕が薄い
  (詳細は[25-low-power-phase2-hardware-cutoff.md](25-low-power-phase2-hardware-cutoff.md) §2.2の訂正)。
  #63の事象(書き込み直後に切り替わらない)も、この余裕不足が関係した可能性があるが、
  未確認。

切り分けは#88で追跡する。

### 10.2 消費電力実測: ポット常時接続によるDeep Sleepリーク電流

`tools/power-logger`(INA226)で実機のLiPo経路の電流波形を実測したところ、**ポット
(Grove - Rotary Angle Sensor)を接続したままだと、Deep Sleep中も継続的にリーク電流が
増加する**ことが判明した。これは§2.6が前提としていた「ADC読み取り自体の所要時間は
ごく短く無視できる」という評価とは**別の問題**である。Groveポートの3V3ラインは
MCUのスリープ状態に関わらず常時給電されているため、ポット(抵抗分圧器)がDeep Sleep中も
継続的に電流を消費することが原因と考えられる。

| 状態 | Deep Sleep電流(実測) |
|---|---|
| ポット未接続(既存機体相当) | 0.45 mA |
| ポット接続(`PSS_POT_ENABLED=1`、常時接続) | 0.75 mA |

あわせて、実機のシリアルログ・CloudWatchログとCSV波形を突き合わせて以下も実測した:

| イベント | 所要時間 | 平均電流 | 電荷 |
|---|---|---|---|
| フル送信サイクル(LTE接続+MQTT publish、`活性ms`基準で毎回コールドアタッチ) | 11.2秒 | 105.2mA | 0.327mAh |
| スキップサイクル(`PSS_CHANGE_ONLY_SEND`によりLTEに触れずセンサー読取のみ) | 5.07秒 | 34.3mA | 0.048mAh |
| ブートモード(電源投入直後、5回連続送信) | 260秒 | 96.1mA | 5.07mAh |

ブートモードの電荷(5.07mAh)は`docs/50-boot-mode-design.md` §10.4の実測値(約5.2mAh)と
ほぼ一致しており、測定手法のクロスチェックになった。

### 10.3 稼働日数の再試算(change-only-send・heartbeatを反映)

> **注記(2026-09-29):** 本節の稼働日数は、送信1回を0.327mAh(publishまでの区間)とした試算。切断までを含めた実測(#76修正後)では送信1回0.446mAhで、定常運用は約122日、worst caseは約29日になる(`docs/hardware.md`の「2026-09-29 実測再試算」)。ポットあり・なしの差の議論は変わらない。

このenv(`xiao-s3-aws-lte-relay`系)は`PSS_SLEEP_SECONDS=300`(5分)・
`PSS_HEARTBEAT_CYCLES=12`のため、状態変化がなければ**実質1時間に1回**しか送信せず、
残り11回は上記の「スキップサイクル」(LTEに触れない軽い処理)になる。`docs/hardware.md`の
既存試算(2026-07時点、#46リレー実装前・change-only-send考慮前)はこの挙動を反映して
いないため、10.2の実測値を使って以下の通り再計算した(前提・詳細は
[docs/hardware.md](hardware.md)の該当節を参照)。

| シナリオ | ポットなし | ポットあり(常時接続) | 差 |
|---|---|---|---|
| 定常(状態変化なし、1時間に1回のheartbeatのみ送信) | 約127日 | 約103日 | -24日(-19%) |
| 毎回変化(worst case、実質毎サイクル送信) | 約38日 | 約35日 | -3日(-8%) |

**結論**: §2.6の「消費電力への影響はほぼ無視できる」という評価は、ADC読み取り自体の
所要時間についてのみ正しかった。ポット自体の常時通電による定常リーク電流は別の論点で
あり、実運用に近い「定常(状態変化なし)」シナリオでこそ影響が大きい(-19%、24日分)。
理由は、送信頻度が低いぶん待機時間の割合が増え、待機電流の増分(+0.3mA)の相対的な
重みが大きくなるため。**現地調整完了後はGroveケーブルを抜いて常設する運用を推奨する**
(§6 #6)。再調整の利便性を優先して接続したままにする選択も、即座に問題になる規模
(103日 vs 127日)ではないため、運用judgment次第で成立する。

### 10.4 ケーブルを抜いた場合の閾値の扱い(v5で解消、NVS永続化)

**この節はv4時点の記述を置き換える(旧: 「最終書き込みして`PSS_POT_ENABLED=0`に
切り替える」手順を推奨していたが、v5でより良い設計に置き換えたため不要になった)。**

v4までの設計(`readPotentiometerThreshold()`が`PSS_POT_ENABLED=1`である限り**毎サイクル
必ずADCを生で読み直す**)では、調整完了後に単純にGroveケーブルを抜くと、GPIO2が
フローティングになり不定値を拾い続けてしまう問題があった。

v5では、ユーザー提案により**ADCの生読みをブートモード(`#50`)の5回の送信時だけに
限定し、結果をNVSへ永続化する**設計に変更した(`readPotentiometerThresholdLive()`/
`currentPotThreshold()`、§2.2/§2.7)。これにより:

- **ブートモード完了後はいつでもケーブルを抜いてよい**(直近の値が既にNVSに永続化
  済みのため、フローティングピンの不定値を拾わない、§5.5)。
- 再書き込み(ビルド・USB接続)は一切不要。
- 再調整したい場合は、ポットを挿し直して物理的に電源を入れ直すだけでよい
  (`ESP_RST_POWERON`でブートモードが自動的に再発動、§2.7)。

確立した運用手順・関連する考慮事項(バッテリー充電時に電源サイクルが発生しないこと等)の
詳細は§2.7を参照。§11で検討する将来のハードウェア拡張(リレーの空きchでポット電源
自体を自動遮断する案)が実現すれば、**ケーブルを抜く操作自体が不要**になり、この節の
運用手順も不要になる見込み。

副次的な利点として、屋外設置後の振動・コネクタ劣化等でポットの物理的な位置が
経年でズレても、NVSに永続化された値は(ブートモードが再発動するまで)変わらない
という安定性がある。

---

## 11. リレー空きチャンネルによるポット電源のハードウェア遮断(実装済み・動作確認済み)

ユーザー提案(2026-09-20)。本設計(v5)のNVS永続化により「ケーブルを抜いても閾値が
壊れない」問題は解決済みだが、**ケーブルを物理的に抜く操作自体をなくす**、かつ
Deep Sleep中のリーク電流(§10.2、+0.3mA)を**自動的にゼロにする**、より優れた
ハードウェア側の代替案として提案されたもの。**この実機での検証時点(§10.1・§10.2)で
既に配線・実装済みであったことが後日判明した**(§11.6)。当初は「将来の拡張案・本PRの
スコープ外」として記録していたが、実際には最初から実装済みであり、かつ正しく機能して
いることが後続の実測で確認できたため、本節はその内容に更新する。

### 11.1 アイデア

`#46`で導入したGrove 2-Coil Latching Relay(Seeed SKU 103020010)は**2回路搭載だが
現在1chのみ使用**(LTE-M用)、もう1chは「未使用・将来の予備」(
`docs/25-low-power-phase2-hardware-cutoff.md` §2.3)。この空きチャンネルにポットの
VCC線を通し、LTE-Mと同じSET/RESET制御に連動させる。

### 11.2 電気的な裏付け(コードベース調査、実機テスター未使用)

この基板の2回路が機械的に連動(DPDT: 1組のコイルで2つの接点を同時に切替)しているか
どうかを、実機測定前にコードベースから調査した:

- ファームウェア全体を検索しても、リレー制御に使うGPIOは`LTE_POWER_RELAY_PIN`
  (`board_xiao.h:15`)**1本のみ**。2回路を独立制御するなら追加の制御信号が必要な
  はずだが存在しない。
- 製品名が「**2-Coil** Latching Relay」(コイル数=2、SET用+RESET用)であり、
  独立2回路(2ch)を仮定すると通常必要になる4コイル構成にはなっていない。
- `docs/25-low-power-phase2-hardware-cutoff.md`の「制御側:...ふつうのGroveケーブルで
  ...GPIOポートに接続するだけ」という記述、および端子台命名(「1COM」「1NO」)からも、
  1組のコイルで2つの可動接点(pole)を同時に駆動するDPDT構成であることが強く示唆される。

これらは状況証拠であり、製品データシートそのものではないが、**実際に配線した上で
運用しており、後日の電源ロガー実測(§11.6)でLTE-M側の通電タイミングとポット側の
待機電流の変化が一致することを確認した**(このプロジェクトが`relay.cpp`のSET/RESET
極性を最終的にベンチ実測で確定させたのと同じ文化)。

### 11.3 想定される動作(2回路が連動する前提)

| フェーズ | リレー状態 | ポットの通電 |
|---|---|---|
| ブートモード中(電源投入直後、約4分間) | SET(ON)を保持 | 通電(現行の`readPotentiometerThresholdLive()`がそのまま動作) |
| 通常サイクルのフル送信(LTE接続+publish、約11秒) | SET | 通電(副次効果、実害なし) |
| Deep Sleep中・スキップサイクル(大部分の時間) | RESET(OFF) | **無通電(リーク電流ゼロ)** |

「run loopに入ったら開きっぱなしで遮断」という当初のイメージとは異なり、**LTE-Mの
SET/RESETと完全に同期して自動的に開閉する**形になる。ただし結果として、
「ケーブル抜き差し不要」「Deep Sleep中のリーク電流ゼロ」という2つの目的はどちらも
達成できる。

### 11.4 ソフトウェアへの影響: なし

この変更は**ハードウェア配線のみ**で完結し、ファームウェアの変更は一切不要である。
理由:

- ブートモード中はリレーが継続してSETされる(`runBootMode()`の既存実装、§2.2)ため、
  `readPotentiometerThresholdLive()`は電気的に問題なく生読みできる。
- `currentPotThreshold()`(通常サイクル用)はそもそもADCに触れない(v5、§5.5)ため、
  Deep Sleep中にポットが無通電になっていても影響を受けない。
- ケーブルを常時接続したままにしても、§2.6で述べた常時通電リーク(+0.3mA)自体が
  発生しなくなるため、§10.3の稼働日数試算の「ポットあり」列は「ポットなし」列と
  実質同じ値になる(定常運用で約127日、常時接続でも劣化なし)。§10.2の`+0.3mA`測定
  (0.45mA→0.75mA)は、この配線が実装される前後いずれかの時点のものと考えられるが、
  §11.6の通り後続の実測ではこのリーク自体が観測されておらず、配線後は解消済みと判断する。

### 11.5 スコープ・実装状況

**実装済み。** 本Issue(#60)の実機検証(§10.1)を行った実機は、この節で検討した
配線が既に施された状態だったことが後日判明した。ファームウェアの変更は一切不要
(§11.4)であるため、本PR・本リポジトリのコード上の対応事項は存在しない。今後
新規に組み立てる機体でも同じ配線を行うことを推奨する(配線手順は`#46`の
`docs/25-low-power-phase2-hardware-cutoff.md` §2.4と同種の要領)。

### 11.6 実機での動作確認(事後確認)

§10.1の実機検証時点で、ポットのVCCは既にこの配線(リレー空きチャンネル経由)を
経ていた。これを踏まえて電源ロガー(`tools/power-logger`)の実測記録を改めて確認した
ところ、Deep Sleep中の待機電流はほぼ一貫して**300〜450µA**の範囲に収まっており、
「ポットなし」時の基準値(0.45mA)と同水準だった。§10.2で報告した「0.75mA
(+0.3mAのリーク)」を裏付ける生ログは、その後複数回`pio device monitor > file`を
実行し直した際にファイルが上書き(`>`)されて残っていなかったため直接の再検証は
できなかったが、測定自体は当時実際に行われたものである。**その後の(=配線が
既に施された状態での)実測でリークが再現しないことは、この配線が意図通りDeep Sleep
中のポット電源を遮断できていることの実質的な裏付けとなる**。

以上により、§11.1〜§11.4で検討した設計(2回路連動によるLTE-M/ポット電源の同期制御)は、
**実装済みかつ実機で正しく機能していることが確認できた**と結論する。
