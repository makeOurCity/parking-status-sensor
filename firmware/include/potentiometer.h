#pragma once

#include <stdint.h>

// #60: 現地調整用ポテンショメーター(Grove - Rotary Angle Sensor)。
// Grove Shield for XIAO Analogポート(D1/GPIO2)、対数マッピングで判定閾値を算出する。
// docs/60-potentiometer-threshold-design.md 参照。
struct PotReading {
  uint16_t raw = 0;   // 0-4095、平均済みADC値(kPotEnabled=falseの場合は常に0)
  int threshold = 0;  // rawから算出した実効閾値
                       // (kPotEnabled=falseの場合はconfig::kStatusThreshold)

  PotReading() = default;
  PotReading(uint16_t rawIn, int thresholdIn) : raw(rawIn), threshold(thresholdIn) {}
};

void initPotentiometer();
PotReading readPotentiometerThreshold();

// 単体で境界値確認しやすいよう、対数マッピングだけを切り出した純粋関数。
int computeThresholdFromAdc(uint16_t adc);
