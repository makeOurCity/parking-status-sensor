#include "sensor.h"

#include <Arduino.h>
#include <Wire.h>
#include <veml6040.h>

#include "board.h"

namespace {

VEML6040 sensor;

constexpr uint8_t kVemlIntegration =
    VEML6040_IT_40MS | VEML6040_AF_AUTO | VEML6040_SD_ENABLE;

// #94: setConfiguration() 後に最初の有効な測定値が出るまでの待ち。
// 実測（コールドブート、満・空 各3回）では、書込み後 約37 ms で G/B/W、
// 約46 ms で R が有効になり、それ以前は全チャネル 0 を返す（積分時間 40 ms と
// 整合）。約2.2倍の余裕を見て 100 ms とする。
// Deep Sleep 中もセンサーは測定を続けるため、タイマー復帰では書込み直後から
// 有効値が読める（実測）。電源投入直後だけがこの待ちを必要とする。
constexpr uint32_t kSettleMs = 100;

}  // namespace

bool initSensor() {
  Wire.begin(I2C_SDA, I2C_SCL);
  // thewknd/VEML6040 の begin() は Wire.begin() を引数なしで呼ぶため、
  // ピン指定後にプローブのみ行う（XIAO: GPIO5/6 = docs/wiring.md）
  Wire.beginTransmission(VEML6040_I2C_ADDRESS);
  if (Wire.endTransmission() != 0) {
    return false;
  }
  sensor.setConfiguration(kVemlIntegration);
  delay(kSettleMs);
  return true;
}

void scanI2cBus() {
  Serial.println("I2C scan (expected VEML6040 at 0x10):");
  uint8_t found = 0;
  for (uint8_t addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      Serial.printf("  found 0x%02X\n", addr);
      found++;
    }
  }
  if (found == 0) {
    Serial.println("  (no devices — check Grove cable / I2C port)");
  }
}

bool readSensor(RawSample& out) {
  out.red = sensor.getRed();
  out.green = sensor.getGreen();
  out.blue = sensor.getBlue();
  out.white = sensor.getWhite();
  return true;
}
