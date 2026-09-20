#pragma once

#include <stdint.h>

// #60: 現地調整用ポテンショメーター(Grove - Rotary Angle Sensor)。
// Grove Shield for XIAO Analogポート(D1/GPIO2)、対数マッピングで判定閾値を算出する。
// ブートモード(#50)の5回の送信の間だけADCを生読みしてNVSへ永続化し、それ以降の通常
// サイクルはNVSの値を使い続ける(ADCには一切触れない)。現地調整完了後にGroveケーブルを
// 抜いても閾値が壊れない。docs/60-potentiometer-threshold-design.md §2.2/§2.7参照。
struct PotReading {
  uint16_t raw = 0;   // 0-4095、平均済みADC値(kPotEnabled=falseの場合は常に0)
  int threshold = 0;  // rawから算出した実効閾値
                       // (kPotEnabled=falseの場合はconfig::kStatusThreshold)

  PotReading() = default;
  PotReading(uint16_t rawIn, int thresholdIn) : raw(rawIn), threshold(thresholdIn) {}
};

// setup()から1回呼ぶ。ADCのアッテネーション設定 + NVSに永続化済みの値のロードを行う。
void initPotentiometer();

// runBootMode()専用。ADCを生読みし、結果をNVSへ永続化してから返す。
PotReading readPotentiometerThresholdLive();

// runCycle()専用。ADCには一切触れず、initPotentiometer()でロード済み
// (直近のreadPotentiometerThresholdLive()呼び出しでNVSに永続化された)値を返す。
PotReading currentPotThreshold();

// 単体で境界値確認しやすいよう、対数マッピングだけを切り出した純粋関数。
int computeThresholdFromAdc(uint16_t adc);
