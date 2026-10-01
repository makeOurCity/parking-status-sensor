#pragma once

#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

// #40: Grove Wio-E5（STM32WLE5JC LoRaWAN AT firmware）の最小 AT ドライバ。
// TinyGSM は Wio-E5 に対応しないため独自に持つ。応答は
// "+<CMD>: <body>" の行単位（AT Command Specification V1.0）。

void wioE5Begin(HardwareSerial& port, int rxPin, int txPin, uint32_t baud);
void wioE5End();
bool wioE5Started();

// 受信バッファを捨ててから "AT" を最大 attempts 回送り、"+AT: OK" を待つ。
// AT+LOWPOWER からの復帰（任意の UART 入力で起きる）もこれで兼ねる。
bool wioE5Wake(uint8_t attempts = 5, uint32_t perAttemptMs = 300);

// cmd を送り、expectPrefix で始まる行が来るまで（最大 timeoutMs）待つ。
// 一致した行を resp にコピーする（resp は nullptr 可）。
// 一致行が "ERROR" を含む場合や timeout の場合は false。
// "AT+KEY" で始まるコマンドと "+KEY:" 行はログ上で伏せ字にする。
bool wioE5Command(const char* cmd, const char* expectPrefix, uint32_t timeoutMs,
                  char* resp = nullptr, size_t respSize = 0);

// AT+LOWPOWER（次の UART 入力まで無期限スリープ）。
bool wioE5Sleep();

// PR1 疎通確認: AT 応答・バージョン・ID・各種設定の読み出しと LOWPOWER 復帰を
// 試し、結果をシリアルに出す。全項目 OK なら true。
bool wioE5RunProbe();

// USB Serial <-> Wio-E5 の素通し（1 回呼ぶごとに溜まっている分を転送）。
void wioE5PassthroughPoll();
