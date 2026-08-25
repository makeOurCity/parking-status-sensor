#include "sensor.h"

#include <Arduino.h>
#include <Wire.h>
#include <veml6040.h>

#include "board.h"

namespace {

VEML6040 sensor;

constexpr uint8_t kVemlIntegration =
    VEML6040_IT_40MS | VEML6040_AF_AUTO | VEML6040_SD_ENABLE;

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
  // Seeed Wiki サンプルに合わせ、初回測定の安定待ち
  delay(1500);
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
