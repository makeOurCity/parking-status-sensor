#pragma once

// ESP32-DevKitC 系の開発ベンチ配線（firmware/devkit-bench.md）
#define BOARD_NAME "devkit"
#define I2C_SDA 21
#define I2C_SCL 22

// 開発ベンチ用 RGB LED（共陰極: Cathode → GND）
#define RGB_LED_ENABLED 1
#define RGB_LED_PIN_R 25
#define RGB_LED_PIN_G 26
#define RGB_LED_PIN_B 27
