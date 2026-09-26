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
// #74: 瞬間的な電圧低下（LTE-M通電時の突入電流など）を捉える高速モード。
// INA226を最短変換・平均なしで連続読み取りし、LOGGER_WINDOW_MSごとに
// 最低電圧・最大電流などを集計して1行出力する。
#ifndef LOGGER_FAST_MODE
#define LOGGER_FAST_MODE 0
#endif
#ifndef LOGGER_WINDOW_MS
#define LOGGER_WINDOW_MS 50
#endif
#ifndef LOGGER_I2C_HZ
#define LOGGER_I2C_HZ 400000
#endif
// 高速モードで電流を読む間隔（電圧 N サンプルに 1 回）。電流の読み取りは
// レジスタポインタの切り替えを伴い電圧読み取りの約 4 倍の時間がかかるため、
// 電圧（最優先）のサンプル密度を落とさないよう間引く。
#ifndef LOGGER_CURRENT_EVERY
#define LOGGER_CURRENT_EVERY 8
#endif
// 高速モードでは、OLED更新(I2Cを数十ms占有)の間は計測できない。試験対象機が
// 起きている間に計測の空白を作らないよう、直前ウィンドウの最大電流がこの値
// 未満（Deep Sleep中）のときだけOLEDを更新する。
#ifndef LOGGER_OLED_IDLE_MA
#define LOGGER_OLED_IDLE_MA 5.0f
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

#if LOGGER_FAST_MODE
// 1ウィンドウ分の集計。
struct Window {
  uint32_t startMs = 0;
  uint32_t samples = 0;
  float busMinMv = 0.0f;
  double busSumMv = 0.0;
  float currentMaxMa = 0.0f;
  float currentMinMa = 0.0f;
  double currentSumMa = 0.0;
};

Window window;
float sessionBusMinMv = 0.0f;
uint32_t sessionBusMinAtMs = 0;
float lastWindowCurrentMaxMa = 0.0f;
uint32_t loopCount = 0;
float lastCurrentMa = 0.0f;

// INA226 のレジスタ（データシート 7.6）。
constexpr uint8_t kRegBusVoltage = 0x02;
constexpr uint8_t kRegCurrent = 0x04;
constexpr float kBusLsbMv = 1.25f;
#endif

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
#if LOGGER_FAST_MODE
  ina226.setAverage(INA226_1_SAMPLE);
  ina226.setBusVoltageConversionTime(INA226_140_us);
  ina226.setShuntVoltageConversionTime(INA226_140_us);
#else
  // 注意: setAverage() の引数は回数ではなく enum 値。旧コードの setAverage(4) は
  // INA226_128_SAMPLES（1.1ms×2×128 ≈ 282ms 平均）を意味していた。過去ログとの
  // 比較可能性を保つため通常モードはこの設定のまま据え置く（#74）。
  ina226.setAverage(INA226_128_SAMPLES);
#endif
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

#if LOGGER_FAST_MODE
void updateOledFast(float busMinMv, float currentAvgMa) {
  if (!oledReady) {
    return;
  }

  char currentBuf[16];
  formatCurrent(currentAvgMa, currentBuf, sizeof(currentBuf));

  const float elapsedS = (millis() - sessionStartMs) / 1000.0f;

  display.clearDisplay();
  display.setCursor(0, 0);
  display.println(F("#74 Fast Logger"));
  display.print(F("I: "));
  display.println(currentBuf);
  display.print(F("Vmin(win): "));
  display.print(busMinMv / 1000.0f, 3);
  display.println(F("V"));
  display.print(F("Vmin(all): "));
  display.print(sessionBusMinMv / 1000.0f, 3);
  display.println(F("V"));
  display.print(F(" at "));
  display.print(sessionBusMinAtMs / 1000.0f, 1);
  display.println(F("s"));
  display.print(F("pk:"));
  display.print(peakAbsMa, 0);
  display.print(F("mA "));
  display.print(elapsedS, 0);
  display.println(F("s"));
  display.display();
}

// INA226 はレジスタポインタを保持するので、ポインタを一度設定すれば以降は
// 読み取りトランザクション 1 回で同じレジスタを読める。ライブラリの
// get*() は毎回ポインタ書き込み＋読み取りの 2 トランザクションで、ESP32 の
// Wire ではそれぞれ約 0.3ms かかるため、高速モードでは直接読む。
bool setRegisterPointer(uint8_t reg) {
  Wire.beginTransmission(kIna226Addr);
  Wire.write(reg);
  return Wire.endTransmission() == 0;
}

bool readPointedRegister(uint16_t& value) {
  if (Wire.requestFrom(kIna226Addr, static_cast<uint8_t>(2)) != 2) {
    return false;
  }
  value = static_cast<uint16_t>(Wire.read()) << 8;
  value |= static_cast<uint16_t>(Wire.read());
  return true;
}

void resetWindow(uint32_t nowMs) {
  window = Window{};
  window.startMs = nowMs;
}

void addSample(float currentMa, float busMv) {
  if (window.samples == 0) {
    window.busMinMv = busMv;
    window.currentMaxMa = currentMa;
    window.currentMinMa = currentMa;
  } else {
    if (busMv < window.busMinMv) {
      window.busMinMv = busMv;
    }
    if (currentMa > window.currentMaxMa) {
      window.currentMaxMa = currentMa;
    }
    if (currentMa < window.currentMinMa) {
      window.currentMinMa = currentMa;
    }
  }
  window.busSumMv += busMv;
  window.currentSumMa += currentMa;
  window.samples++;
}

// ウィンドウを1行のCSVとして出力し、セッション統計を更新する。
void flushWindow(uint32_t nowMs) {
  if (window.samples == 0) {
    resetWindow(nowMs);
    return;
  }

  const float busAvgMv = static_cast<float>(window.busSumMv / window.samples);
  const float currentAvgMa =
      static_cast<float>(window.currentSumMa / window.samples);

  Serial.printf("%lu,%lu,%.1f,%.1f,%.2f,%.2f,%.2f\n",
                static_cast<unsigned long>(nowMs),
                static_cast<unsigned long>(window.samples), window.busMinMv,
                busAvgMv, window.currentMaxMa, window.currentMinMa,
                currentAvgMa);

  if (sessionBusMinAtMs == 0 || window.busMinMv < sessionBusMinMv) {
    sessionBusMinMv = window.busMinMv;
    sessionBusMinAtMs = nowMs;
  }
  const float absMaxMa = fmaxf(fabsf(window.currentMaxMa), fabsf(window.currentMinMa));
  if (absMaxMa > peakAbsMa) {
    peakAbsMa = absMaxMa;
  }
  if (lastSampleMs != 0 && nowMs > lastSampleMs) {
    sessionMah += fabsf(currentAvgMa) * (nowMs - lastSampleMs) / 3600000.0f;
  }
  lastSampleMs = nowMs;
  sampleCount += window.samples;
  lastWindowCurrentMaxMa = window.currentMaxMa;

  if (oledReady && lastWindowCurrentMaxMa < LOGGER_OLED_IDLE_MA &&
      (nowMs - lastOledMs >= LOGGER_OLED_INTERVAL_MS)) {
    updateOledFast(window.busMinMv, currentAvgMa);
    lastOledMs = millis();
  }

  // OLED更新中（数十ms）は計測できないが、上の条件でDeep Sleep中に限っている。
  // 空白は次の行の samples 数の減少として現れる。
  resetWindow(nowMs);
}
#endif

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
#if LOGGER_FAST_MODE
  // 出力待ちで計測ループが止まらないよう、送信バッファを確保しておく。
  Serial.setTxBufferSize(2048);
#endif
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
    Wire.setClock(LOGGER_I2C_HZ);
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
#if LOGGER_FAST_MODE
  Serial.printf("# fast_mode=1 window_ms=%u conv_us=140 avg=1 i2c_hz=%lu "
                "current_every=%u oled_idle_ma=%.1f\n",
                LOGGER_WINDOW_MS, static_cast<unsigned long>(LOGGER_I2C_HZ),
                LOGGER_CURRENT_EVERY, static_cast<float>(LOGGER_OLED_IDLE_MA));
  Serial.println(F("ms,samples,bus_min_mV,bus_avg_mV,current_max_mA,current_min_mA,current_avg_mA"));
  setRegisterPointer(kRegBusVoltage);
  resetWindow(millis());
#else
  Serial.println(F("ms,current_mA,bus_mV,power_mW"));
#endif

  if (oledReady) {
    showOledMessage(LOGGER_FAST_MODE ? "#74 Fast Logger" : "#31 Power Logger",
                    "INA226 OK @41", "Logging...");
  } else {
    Serial.println(F("# WARN: OLED not found (0x3C/0x3D) — CSV only"));
  }
}

void loop() {
#if LOGGER_FAST_MODE
  // delayなしで読み続ける。電圧は毎回（ポインタはバス電圧レジスタに固定）、
  // 電流は LOGGER_CURRENT_EVERY 回に 1 回だけ読み、ポインタを電圧に戻す。
  if (loopCount++ % LOGGER_CURRENT_EVERY == 0) {
    uint16_t raw = 0;
    if (setRegisterPointer(kRegCurrent) && readPointedRegister(raw)) {
      lastCurrentMa = static_cast<int16_t>(raw) * ina226.getCurrentLSB_mA();
    }
    setRegisterPointer(kRegBusVoltage);
  }
  uint16_t busRaw = 0;
  if (readPointedRegister(busRaw)) {
    addSample(lastCurrentMa, busRaw * kBusLsbMv);
  }

  const uint32_t now = millis();
  if (now - window.startMs >= LOGGER_WINDOW_MS) {
    flushWindow(now);
  }
#else
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
#endif
}
