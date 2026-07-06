#pragma once

// Seeed XIAO ESP32S3（docs/wiring.md §2.1）
#define BOARD_NAME "xiao-s3"
#define I2C_SDA 5  // D4
#define I2C_SCL 6  // D5

// Grove Shield for XIAO UART port（M5Stack SIM7080G CAT-M Unit）
#define LTE_UART_RX 44  // D7: XIAO RX <- module TX
#define LTE_UART_TX 43  // D6: XIAO TX -> module RX
#define LTE_UART_BAUD 115200
