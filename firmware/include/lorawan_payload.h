#pragma once

#include <stddef.h>
#include <stdint.h>

#include <array>

#include "classify.h"
#include "sensor.h"
#include "sync_ledger.h"

// #40: LoRaWAN アップリンクのペイロード（fPort 1, ver 1, 固定 11 バイト）。
// バイト配置は docs/40-lorawan-design.md §3。デコーダは tools/lorawan/decode.py。
// deviceId / timestamp は載せない（クラウド側で Wireless Device 名と受信時刻から補う）。

// RP002 AS923, UplinkDwellTime=1 の DR2 の最大アプリペイロード。
// Join 直後（ADR 収束前）は DR2 で送ることがあるため、常にこれに収める。
constexpr size_t kAs923Dr2DwellMaxPayload = 11;
constexpr size_t kLoRaWanCorePayloadSize = 11;
static_assert(kLoRaWanCorePayloadSize <= kAs923Dr2DwellMaxPayload,
              "core uplink must fit AS923 DR2 with dwell time");

constexpr uint8_t kLoRaWanCoreFPort = 1;
constexpr uint8_t kLoRaWanCoreVersion = 1;

enum class SendReason : uint8_t {
  kStateChange = 0,
  kHeartbeat = 1,
  kPendingRetry = 2,
  kBootMode = 3,
};

struct LoRaWanUplinkInput {
  ParkingStatus status = ParkingStatus::kUnknown;
  SendReason reason = SendReason::kStateChange;
  bool coldBoot = false;  // esp_reset_reason() == ESP_RST_POWERON
  RawSample raw{};
  CycleOutcome prevOutcome = CycleOutcome::kNone;
  uint8_t prevAttempts = 0;   // 3 で頭打ち
  uint8_t bootSlot = 0;       // 0 = 通常サイクル、1-7 = ブートモードの何回目か
  uint32_t prevActiveMs = 0;  // 250ms 単位、255（63.75s）で頭打ち
};

using LoRaWanCorePayload = std::array<uint8_t, kLoRaWanCorePayloadSize>;

LoRaWanCorePayload encodeLoRaWanCore(const LoRaWanUplinkInput& in);

// payload を大文字 16 進文字列にする（AT+CMSGHEX 用）。out は 2*len+1 以上。
void loRaWanToHex(const uint8_t* data, size_t len, char* out, size_t outSize);
