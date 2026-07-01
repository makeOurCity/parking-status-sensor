#include "sensor.h"

#include <Arduino.h>
#include <Wire.h>
#include <veml6040.h>

#include "board.h"

namespace {

VEML6040 sensor;

constexpr uint8_t kVemlIntegration =
    VEML6040_IT_320MS | VEML6040_AF_AUTO | VEML6040_SD_ENABLE;

}  // namespace

bool initSensor() {
  Wire.begin(I2C_SDA, I2C_SCL);
  if (!sensor.begin()) {
    return false;
  }
  sensor.setConfiguration(kVemlIntegration);
  // Seeed Wiki サンプルに合わせ、初回測定の安定待ち
  delay(1500);
  return true;
}

bool readSensor(RawSample& out) {
  out.red = sensor.getRed();
  out.green = sensor.getGreen();
  out.blue = sensor.getBlue();
  out.white = sensor.getWhite();
  return true;
}
