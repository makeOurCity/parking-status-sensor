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
  // 仕様上analogRead()は0-4095に収まるが、防御的にクランプしてから計算する。
  const uint16_t clamped = adc > kAdcMax ? kAdcMax : adc;
  const float ratio = static_cast<float>(clamped) / static_cast<float>(kAdcMax);
  const float lower = static_cast<float>(config::kPotThresholdMin);
  const float upper = static_cast<float>(config::kPotThresholdMax);
  const float threshold = lower * powf(upper / lower, ratio);
  return static_cast<int>(lroundf(threshold));
}

PotReading readPotentiometerThreshold() {
  if (!config::kPotEnabled) {
    // 未配線機体の既定値。ADCには一切触れない。
    return PotReading{0, config::kStatusThreshold};
  }

  uint32_t sum = 0;
  for (uint8_t i = 0; i < config::kPotSampleCount; ++i) {
    sum += analogRead(POT_ADC_PIN);
    if (i + 1 < config::kPotSampleCount) {
      // ADC自体のノイズとワイパー接触ノイズの平滑化用。VEML6040の1500ms
      // 安定待ち(sensor.cpp)に比べ無視できる遅延。
      delay(2);
    }
  }
  const uint16_t avg = static_cast<uint16_t>(sum / config::kPotSampleCount);
  return PotReading{avg, computeThresholdFromAdc(avg)};
}
