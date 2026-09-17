#include "relay.h"

#include <Arduino.h>

#include "board.h"
#include "config.h"

namespace {

// SETパルスの論理レベル。ベンチ実測(2026-09-17)でLTE ON/OFFが逆だったため反転済み:
// 「1回目のクリック(起動時RESET)で点灯、2回目(SET)で消灯」という実機観測から、
// 当初 kRelayOnLevel=HIGH としていたのは実際にはOFF方向だったと判明した。
constexpr int kRelayOnLevel = LOW;
constexpr int kRelayOffLevel = HIGH;

void pulse(int level) {
  digitalWrite(LTE_POWER_RELAY_PIN, level);
  delay(config::kRelayPulseMs);
}

}  // namespace

void initRelay() {
  if (!config::kLtePowerRelayEnabled) {
    return;
  }
  pinMode(LTE_POWER_RELAY_PIN, OUTPUT);
  // フェイルセーフ（#46 §2.6）: 起動理由を問わず、他の処理より先に必ず一度
  // RESETパルスを送る。SET後・RESET前にウォッチドッグリセットが起きても
  // LTE-Mが通電しっぱなしにならないようにする。
  pulse(kRelayOffLevel);
}

void relayLteOn() {
  if (!config::kLtePowerRelayEnabled) {
    return;
  }
  Serial.printf("relay: SET (LTE ON) at t=%lu ms\n",
                static_cast<unsigned long>(millis()));
  pulse(kRelayOnLevel);
}

void relayLteOff() {
  if (!config::kLtePowerRelayEnabled) {
    return;
  }
  Serial.printf("relay: RESET (LTE OFF) at t=%lu ms\n",
                static_cast<unsigned long>(millis()));
  pulse(kRelayOffLevel);
}
