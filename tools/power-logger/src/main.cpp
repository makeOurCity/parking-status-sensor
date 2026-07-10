#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <Arduino.h>
#include <INA226.h>
#include <Wire.h>

#ifndef LOGGER_I2C_SDA
#define LOGGER_I2C_SDA 21
#endif
#ifndef LOGGER_I2C_SCL
#define LOGGER_I2C_SCL 22
#endif
#ifndef LOGGER_OLED_ADDR
#define LOGGER_OLED_ADDR 0x3C
#endif
#ifndef LOGGER_SAMPLE_HZ
#define LOGGER_SAMPLE_HZ 15
#endif
#ifndef LOGGER_OLED_INTERVAL_MS
#define LOGGER_OLED_INTERVAL_MS 250
#endif

namespace {

constexpr uint8_t kIna226Addr = 0x41;
constexpr uint8_t kOledAltAddr = 0x3D;
constexpr float kShuntOhm = 0.08f;
constexpr float kMaxCurrentA = 1.0f;
constexpr uint32_t kSerialWaitMs = 3000;
constexpr uint8_t kOledWidth = 128;
constexpr uint8_t kOledHeight = 64;

INA226 ina226(kIna226Addr);
Adafruit_SSD1306 display(kOledWidth, kOledHeight, &Wire, -1);

const uint32_t kSampleIntervalMs =
    (LOGGER_SAMPLE_HZ > 0) ? (1000u / static_cast<uint32_t>(LOGGER_SAMPLE_HZ)) : 66u;

bool inaReady = false;
bool oledReady = false;
uint8_t oledAddr = LOGGER_OLED_ADDR;

float sessionMah = 0.0f;
float peakAbsMa = 0.0f;
uint32_t sampleCount = 0;
uint32_t sessionStartMs = 0;
uint32_t lastSampleMs = 0;
uint32_t lastOledMs = 0;

void waitForSerial() {
  const uint32_t start = millis();
  while (!Serial && (millis() - start) < kSerialWaitMs) {
    delay(10);
  }
}

void scanI2c(const char* label) {
  Serial.printf("# I2C scan %s (sda=%d scl=%d):\n", label, LOGGER_I2C_SDA,
                LOGGER_I2C_SCL);
  uint8_t found = 0;
  for (uint8_t addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      Serial.printf("#   0x%02X\n", addr);
      found++;
    }
  }
  if (found == 0) {
    Serial.println(F("#   (no devices — check 5V/GND/SDA/SCL)"));
  }
}

bool probeIna226(uint8_t addr) {
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

bool initIna226() {
  if (!probeIna226(kIna226Addr)) {
    return false;
  }
  if (!ina226.begin()) {
    return false;
  }
  ina226.setMaxCurrentShunt(kMaxCurrentA, kShuntOhm);
  ina226.setAverage(4);
  return true;
}

bool initOled(uint8_t addr) {
  if (!display.begin(SSD1306_SWITCHCAPVCC, addr)) {
    return false;
  }
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.display();
  return true;
}

void showOledScan(const char* title) {
  if (!oledReady) {
    return;
  }
  display.clearDisplay();
  display.setCursor(0, 0);
  display.println(title);
  uint8_t line = 1;
  uint8_t found = 0;
  for (uint8_t addr = 1; addr < 127 && line < 7; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      display.print(F("0x"));
      display.println(addr, HEX);
      found++;
      line++;
    }
  }
  if (found == 0) {
    display.println(F("(none)"));
  } else if (found == 1) {
    display.println(F("need 0x41"));
  }
  display.display();
}

void showOledMessage(const char* line1, const char* line2 = nullptr,
                     const char* line3 = nullptr) {
  if (!oledReady) {
    return;
  }
  display.clearDisplay();
  display.setCursor(0, 0);
  display.println(line1);
  if (line2 != nullptr) {
    display.println(line2);
  }
  if (line3 != nullptr) {
    display.println(line3);
  }
  display.display();
}

void formatCurrent(float currentMa, char* buf, size_t len) {
  const float absMa = fabsf(currentMa);
  if (absMa < 1.0f) {
    snprintf(buf, len, "%.1f uA", absMa * 1000.0f);
  } else {
    snprintf(buf, len, "%.2f mA", currentMa);
  }
}

void updateOled(float currentMa, float busMv, float powerMw) {
  if (!oledReady) {
    return;
  }

  char currentBuf[16];
  formatCurrent(currentMa, currentBuf, sizeof(currentBuf));

  const float elapsedS = (millis() - sessionStartMs) / 1000.0f;

  display.clearDisplay();
  display.setCursor(0, 0);
  display.println(F("#31 Power Logger"));
  display.print(F("I: "));
  display.println(currentBuf);
  display.print(F("V: "));
  display.print(busMv / 1000.0f, 2);
  display.println(F(" V"));
  display.print(F("P: "));
  display.print(powerMw, 1);
  display.println(F(" mW"));
  display.print(F("S: "));
  display.print(sessionMah, 4);
  display.println(F(" mAh"));
  display.print(F("pk:"));
  display.print(peakAbsMa, 1);
  display.print(F("mA "));
  display.print(elapsedS, 0);
  display.print(F("s n="));
  display.println(sampleCount);
  display.display();
}

void integrateSample(float currentMa, uint32_t nowMs) {
  if (lastSampleMs != 0 && nowMs > lastSampleMs) {
    const float dtH = (nowMs - lastSampleMs) / 3600000.0f;
    const float absMa = fabsf(currentMa);
    sessionMah += absMa * dtH;
    if (absMa > peakAbsMa) {
      peakAbsMa = absMa;
    }
  }
  lastSampleMs = nowMs;
  sampleCount++;
}

}  // namespace

void setup() {
  Serial.begin(115200);
  waitForSerial();

  Wire.begin(LOGGER_I2C_SDA, LOGGER_I2C_SCL);
  Wire.setClock(100000);

  scanI2c("before init");

  oledReady = initOled(LOGGER_OLED_ADDR);
  if (!oledReady && LOGGER_OLED_ADDR != kOledAltAddr) {
    oledReady = initOled(kOledAltAddr);
    if (oledReady) {
      oledAddr = kOledAltAddr;
    }
  } else if (oledReady) {
    oledAddr = LOGGER_OLED_ADDR;
  }

  inaReady = initIna226();

  if (inaReady) {
    Wire.setClock(400000);
  }

  sessionStartMs = millis();
  lastSampleMs = 0;
  lastOledMs = 0;

  if (!inaReady) {
    Serial.println(F("# ERROR: INA226 not found at 0x41"));
    scanI2c("after fail");
    Serial.println(F("# Hint: U200 Grove — Yellow=SDA→21, White=SCL→22, Red=5V, Black=GND"));
    Serial.println(F("# Hint: if 0x3C only, SDA/SCL may be swapped"));
    showOledScan("I2C scan:");
    while (true) {
      delay(5000);
      scanI2c("retry");
      showOledScan("I2C scan:");
    }
  }

  Serial.println(F("# U200-1A logger (Issue #31)"));
  Serial.printf("# board=esp32dev i2c_sda=%d i2c_scl=%d\n", LOGGER_I2C_SDA,
                LOGGER_I2C_SCL);
  Serial.printf("# ina226=0x41 oled=0x%02X sample_hz=%u\n", oledAddr,
                LOGGER_SAMPLE_HZ);
  Serial.printf("# shunt_ohm=%.3f max_a=%.1f\n", kShuntOhm, kMaxCurrentA);
  Serial.println(F("ms,current_mA,bus_mV,power_mW"));

  if (oledReady) {
    showOledMessage("#31 Power Logger", "INA226 OK @41", "Logging...");
  } else {
    Serial.println(F("# WARN: OLED not found (0x3C/0x3D) — CSV only"));
  }
}

void loop() {
  const uint32_t t0 = millis();
  const float currentMa = ina226.getCurrent_mA();
  const float busMv = ina226.getBusVoltage_mV();
  const float powerMw = ina226.getPower_mW();

  integrateSample(currentMa, t0);

  Serial.printf("%lu,%.3f,%.1f,%.3f\n", t0, currentMa, busMv, powerMw);

  if (oledReady && (t0 - lastOledMs >= LOGGER_OLED_INTERVAL_MS)) {
    updateOled(currentMa, busMv, powerMw);
    lastOledMs = t0;
  }

  const uint32_t elapsed = millis() - t0;
  if (elapsed < kSampleIntervalMs) {
    delay(kSampleIntervalMs - elapsed);
  }
}
