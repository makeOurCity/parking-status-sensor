#include <Arduino.h>

#include "board.h"
#include "sensor.h"

namespace {

constexpr uint32_t kSerialWaitMs = 3000;
constexpr uint32_t kSampleIntervalMs = 400;

void waitForSerial() {
  const uint32_t start = millis();
  while (!Serial && (millis() - start) < kSerialWaitMs) {
    delay(10);
  }
}

}  // namespace

void setup() {
  Serial.begin(115200);
  waitForSerial();

  Serial.printf("board=%s i2c_sda=%d i2c_scl=%d\n", BOARD_NAME, I2C_SDA,
                I2C_SCL);

  if (!initSensor()) {
    Serial.println("ERROR: VEML6040 not found at 0x10");
    scanI2cBus();
    while (true) {
      delay(1000);
    }
  }

  Serial.println("VEML6040 ready");
  Serial.println("R G B W R-G");
}

void loop() {
  RawSample sample{};
  readSensor(sample);

  const int rgDiff =
      static_cast<int>(sample.red) - static_cast<int>(sample.green);

  Serial.printf("%u %u %u %u %d\n", sample.red, sample.green, sample.blue,
                sample.white, rgDiff);

  delay(kSampleIntervalMs);
}
