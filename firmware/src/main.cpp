#include <Adafruit_TCS34725.h>
#include <Arduino.h>
#include <Wire.h>

#include "board.h"

#ifndef RGB_LED_ENABLED
#define RGB_LED_ENABLED 0
#endif

#ifndef OLED_ENABLED
#define OLED_ENABLED 0
#endif

#if OLED_ENABLED
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#endif

namespace {

constexpr uint32_t kSerialWaitMs = 3000;
constexpr uint32_t kSampleIntervalMs = 300;

Adafruit_TCS34725 tcs(TCS34725_INTEGRATIONTIME_50MS, TCS34725_GAIN_4X);

void waitForSerial() {
  const uint32_t start = millis();
  while (!Serial && (millis() - start) < kSerialWaitMs) {
    delay(10);
  }
}

bool initSensor() {
  Wire.begin(I2C_SDA, I2C_SCL);
  if (!tcs.begin()) {
    return false;
  }
  // 搭載白色 LED は消灯（表示灯の光のみ読む）
  tcs.setInterrupt(true);
  return true;
}

#if OLED_ENABLED

constexpr uint8_t kOledWidth = 128;
constexpr uint8_t kOledHeight = 64;
constexpr int8_t kOledResetPin = -1;

Adafruit_SSD1306 display(kOledWidth, kOledHeight, &Wire, kOledResetPin);
bool oledReady = false;

bool initOled() {
  if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
    return false;
  }
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(0, 0);
  display.println(F("TCS34725"));
  display.display();
  return true;
}

void showOledText(const char* line1, const char* line2 = nullptr) {
  if (!oledReady) {
    return;
  }
  display.clearDisplay();
  display.setCursor(0, 0);
  display.println(line1);
  if (line2 != nullptr) {
    display.println(line2);
  }
  display.display();
}

void updateOled(uint16_t red, uint16_t green, uint16_t blue, uint16_t clear,
                int rgDiff) {
  if (!oledReady) {
    return;
  }
  display.clearDisplay();
  display.setCursor(0, 0);
  display.println(F("TCS34725"));
  display.print(F("R: "));
  display.println(red);
  display.print(F("G: "));
  display.println(green);
  display.print(F("B: "));
  display.println(blue);
  display.print(F("C: "));
  display.println(clear);
  display.print(F("R-G: "));
  display.println(rgDiff);
  display.display();
}

#endif  // OLED_ENABLED

#if RGB_LED_ENABLED

constexpr uint32_t kLedPwmFreqHz = 5000;
constexpr uint8_t kLedPwmResolutionBits = 8;
constexpr uint8_t kLedcChannelR = 0;
constexpr uint8_t kLedcChannelG = 1;
constexpr uint8_t kLedcChannelB = 2;

struct RgbLevels {
  uint8_t red;
  uint8_t green;
  uint8_t blue;
};

struct AmbientBaseline {
  uint16_t red = 0;
  uint16_t green = 0;
  uint16_t blue = 0;
  uint16_t clear = 0;
  int32_t rRatio = 0;  // channel * 1000 / clear
  int32_t gRatio = 0;
  int32_t bRatio = 0;
};

AmbientBaseline ambientBaseline;

int32_t channelRatio(uint16_t channel, uint16_t clear) {
  if (clear == 0) {
    return 0;
  }
  return static_cast<int32_t>(channel) * 1000 / clear;
}

void initRgbLed() {
  ledcSetup(kLedcChannelR, kLedPwmFreqHz, kLedPwmResolutionBits);
  ledcSetup(kLedcChannelG, kLedPwmFreqHz, kLedPwmResolutionBits);
  ledcSetup(kLedcChannelB, kLedPwmFreqHz, kLedPwmResolutionBits);
  ledcAttachPin(RGB_LED_PIN_R, kLedcChannelR);
  ledcAttachPin(RGB_LED_PIN_G, kLedcChannelG);
  ledcAttachPin(RGB_LED_PIN_B, kLedcChannelB);
  ledcWrite(kLedcChannelR, 0);
  ledcWrite(kLedcChannelG, 0);
  ledcWrite(kLedcChannelB, 0);
}

void setRgbLed(const RgbLevels& levels) {
  ledcWrite(kLedcChannelR, levels.red);
  ledcWrite(kLedcChannelG, levels.green);
  ledcWrite(kLedcChannelB, levels.blue);
}

uint8_t applyLedGamma(uint32_t channel) {
  // ガンマ < 1 で中間調を持ち上げ、LED の発色にメリハリを付ける
  constexpr float kGamma = 0.55f;
  if (channel == 0) {
    return 0;
  }
  const float normalized = static_cast<float>(channel) / 255.0f;
  const float corrected = powf(normalized, kGamma);
  return static_cast<uint8_t>(min<uint32_t>(255, corrected * 255.0f + 0.5f));
}

void calibrateAmbientBaseline() {
  Serial.println("Calibrating ambient baseline (2s) - leave sensor unobstructed");
#if OLED_ENABLED
  showOledText("Calibrating...", "leave unobstructed");
#endif

  uint32_t sumR = 0;
  uint32_t sumG = 0;
  uint32_t sumB = 0;
  uint32_t sumC = 0;
  constexpr int kSamples = 8;

  for (int i = 0; i < kSamples; i++) {
    uint16_t red = 0;
    uint16_t green = 0;
    uint16_t blue = 0;
    uint16_t clear = 0;
    tcs.getRawData(&red, &green, &blue, &clear);
    sumR += red;
    sumG += green;
    sumB += blue;
    sumC += clear;
    delay(250);
  }

  ambientBaseline.red = static_cast<uint16_t>(sumR / kSamples);
  ambientBaseline.green = static_cast<uint16_t>(sumG / kSamples);
  ambientBaseline.blue = static_cast<uint16_t>(sumB / kSamples);
  ambientBaseline.clear = static_cast<uint16_t>(sumC / kSamples);
  ambientBaseline.rRatio =
      channelRatio(ambientBaseline.red, ambientBaseline.clear);
  ambientBaseline.gRatio =
      channelRatio(ambientBaseline.green, ambientBaseline.clear);
  ambientBaseline.bRatio =
      channelRatio(ambientBaseline.blue, ambientBaseline.clear);

  Serial.printf("ambient baseline R=%u G=%u B=%u C=%u ratio=%ld %ld %ld\n",
                ambientBaseline.red, ambientBaseline.green, ambientBaseline.blue,
                ambientBaseline.clear, ambientBaseline.rRatio,
                ambientBaseline.gRatio, ambientBaseline.bRatio);
}

// Clear 正規化比率のベースライン差分（符号付き）
void chromaDelta(uint16_t red, uint16_t green, uint16_t blue, uint16_t clear,
                 int32_t& outR, int32_t& outG, int32_t& outB) {
  outR = channelRatio(red, clear) - ambientBaseline.rRatio;
  outG = channelRatio(green, clear) - ambientBaseline.gRatio;
  outB = channelRatio(blue, clear) - ambientBaseline.bRatio;
}

int32_t positiveOnly(int32_t value) {
  return max<int32_t>(0, value);
}

// 比率差分 → 優勢色がはっきりしたときだけ発光（共陰極）
RgbLevels sensorToLedLevels(uint16_t red, uint16_t green, uint16_t blue,
                            uint16_t clear) {
  int32_t chromaR = 0;
  int32_t chromaG = 0;
  int32_t chromaB = 0;
  chromaDelta(red, green, blue, clear, chromaR, chromaG, chromaB);

  // ベースラインと同じ色味なら差分はほぼ 0
  const int32_t absR = abs(chromaR);
  const int32_t absG = abs(chromaG);
  const int32_t absB = abs(chromaB);
  int32_t peakAbs = absR;
  if (absG > peakAbs) {
    peakAbs = absG;
  }
  if (absB > peakAbs) {
    peakAbs = absB;
  }
  constexpr int32_t kMinChromaDelta = 25;
  if (peakAbs < kMinChromaDelta) {
    return {0, 0, 0};
  }

  // 増えた方向だけ LED に反映（赤をかざすと R 比率が上がる）
  int32_t adjR = positiveOnly(chromaR);
  int32_t adjG = positiveOnly(chromaG);
  int32_t adjB = positiveOnly(chromaB);

  int32_t peak = adjR;
  if (adjG > peak) {
    peak = adjG;
  }
  if (adjB > peak) {
    peak = adjB;
  }
  if (peak == 0) {
    return {0, 0, 0};
  }

  int32_t second = 0;
  if (adjR != peak && adjR > second) {
    second = adjR;
  }
  if (adjG != peak && adjG > second) {
    second = adjG;
  }
  if (adjB != peak && adjB > second) {
    second = adjB;
  }

  if (second > 0 && peak * 100 < second * 112) {
    return {0, 0, 0};
  }

  int32_t ledR = adjR * 255 / peak;
  int32_t ledG = adjG * 255 / peak;
  int32_t ledB = adjB * 255 / peak;

  // グレー成分を引いてから増幅 → くすみを減らす
  const int32_t minRgb = min(ledR, min(ledG, ledB));
  constexpr int32_t kSaturationBoost = 3;
  ledR = (ledR - minRgb) * kSaturationBoost;
  ledG = (ledG - minRgb) * kSaturationBoost;
  ledB = (ledB - minRgb) * kSaturationBoost;

  int32_t chromaPeak = ledR;
  if (ledG > chromaPeak) {
    chromaPeak = ledG;
  }
  if (ledB > chromaPeak) {
    chromaPeak = ledB;
  }
  if (chromaPeak == 0) {
    return {0, 0, 0};
  }
  if (chromaPeak > 255) {
    ledR = ledR * 255 / chromaPeak;
    ledG = ledG * 255 / chromaPeak;
    ledB = ledB * 255 / chromaPeak;
  }

  // 差分の強さで明るさを決める
  uint32_t brightness = static_cast<uint32_t>(peak) * 255 / 350;
  if (brightness > 255) {
    brightness = 255;
  }
  constexpr uint32_t kMinBrightness = 64;
  if (brightness < kMinBrightness) {
    brightness = kMinBrightness;
  }

  ledR = ledR * static_cast<int32_t>(brightness) / 255;
  ledG = ledG * static_cast<int32_t>(brightness) / 255;
  ledB = ledB * static_cast<int32_t>(brightness) / 255;

  return {applyLedGamma(static_cast<uint32_t>(ledR)),
          applyLedGamma(static_cast<uint32_t>(ledG)),
          applyLedGamma(static_cast<uint32_t>(ledB))};
}

#endif  // RGB_LED_ENABLED

}  // namespace

void setup() {
  Serial.begin(115200);
  waitForSerial();

  Serial.printf("board=%s i2c_sda=%d i2c_scl=%d\n", BOARD_NAME, I2C_SDA, I2C_SCL);

#if RGB_LED_ENABLED
  initRgbLed();
  Serial.printf("rgb_led=r:%d g:%d b:%d (common cathode)\n", RGB_LED_PIN_R,
                RGB_LED_PIN_G, RGB_LED_PIN_B);
#endif

  if (!initSensor()) {
    Serial.println("ERROR: TCS34725 not found at 0x29");
#if OLED_ENABLED
    showOledText("ERROR", "TCS34725 not found");
#endif
    while (true) {
      delay(1000);
    }
  }

#if OLED_ENABLED
  oledReady = initOled();
  if (!oledReady) {
    Serial.printf("WARN: SSD1306 not found at 0x%02x\n", OLED_I2C_ADDR);
  } else {
    Serial.printf("oled=i2c addr=0x%02x sda=%d scl=%d (shared bus)\n",
                  OLED_I2C_ADDR, I2C_SDA, I2C_SCL);
  }
#endif

  Serial.println("TCS34725 ready");
#if RGB_LED_ENABLED
  calibrateAmbientBaseline();
  Serial.println("R G B C R-G  dR dG dB  ledR ledG ledB");
#else
  Serial.println("R G B C R-G");
#endif
}

void loop() {
  uint16_t red = 0;
  uint16_t green = 0;
  uint16_t blue = 0;
  uint16_t clear = 0;

  tcs.getRawData(&red, &green, &blue, &clear);
  const int rgDiff = static_cast<int>(red) - static_cast<int>(green);

#if RGB_LED_ENABLED
  int32_t chromaR = 0;
  int32_t chromaG = 0;
  int32_t chromaB = 0;
  chromaDelta(red, green, blue, clear, chromaR, chromaG, chromaB);
  const RgbLevels led = sensorToLedLevels(red, green, blue, clear);
  setRgbLed(led);
  Serial.printf("%u %u %u %u %d  %ld %ld %ld  %u %u %u\n", red, green, blue,
                clear, rgDiff, chromaR, chromaG, chromaB, led.red, led.green,
                led.blue);
  updateOled(red, green, blue, clear, rgDiff);
#else
  Serial.printf("%u %u %u %u %d\n", red, green, blue, clear, rgDiff);
#if OLED_ENABLED
  updateOled(red, green, blue, clear, rgDiff);
#endif
#endif

  delay(kSampleIntervalMs);
}
