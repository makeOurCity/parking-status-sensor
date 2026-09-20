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
    cached = PotReading{0, config::kStatusThreshold};
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
  // 仕様上analogRead()は0-4095に収まるが、防御的にクランプしてから計算する。
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
      // 安定待ち(sensor.cpp)に比べ無視できる遅延。
      delay(2);
    }
  }
  const uint16_t avg = static_cast<uint16_t>(sum / config::kPotSampleCount);
  cached = PotReading(avg, computeThresholdFromAdc(avg));
  persist(cached);
  return cached;
}

PotReading currentPotThreshold() { return cached; }
