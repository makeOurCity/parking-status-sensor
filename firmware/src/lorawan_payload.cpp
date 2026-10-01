#include "lorawan_payload.h"

namespace {

uint8_t saturate(uint32_t value, uint8_t max) {
  return value > max ? max : static_cast<uint8_t>(value);
}

void putU16(uint8_t* out, uint16_t value) {
  out[0] = static_cast<uint8_t>(value >> 8);
  out[1] = static_cast<uint8_t>(value & 0xFF);
}

}  // namespace

LoRaWanCorePayload encodeLoRaWanCore(const LoRaWanUplinkInput& in) {
  LoRaWanCorePayload out{};
  out[0] = static_cast<uint8_t>((kLoRaWanCoreVersion & 0x3) << 6 |
                                (static_cast<uint8_t>(in.status) & 0x3) << 4 |
                                (static_cast<uint8_t>(in.reason) & 0x3) << 2 |
                                (in.coldBoot ? 1 : 0) << 1);
  out[1] = static_cast<uint8_t>((static_cast<uint8_t>(in.prevOutcome) & 0x7) << 5 |
                                saturate(in.prevAttempts, 3) << 3 |
                                saturate(in.bootSlot, 7));
  putU16(&out[2], in.raw.red);
  putU16(&out[4], in.raw.green);
  putU16(&out[6], in.raw.blue);
  putU16(&out[8], in.raw.white);
  out[10] = saturate(in.prevActiveMs / 250, 255);
  return out;
}

void loRaWanToHex(const uint8_t* data, size_t len, char* out, size_t outSize) {
  static const char kDigits[] = "0123456789ABCDEF";
  size_t pos = 0;
  for (size_t i = 0; i < len && pos + 2 < outSize; ++i) {
    out[pos++] = kDigits[data[i] >> 4];
    out[pos++] = kDigits[data[i] & 0xF];
  }
  if (outSize > 0) {
    out[pos < outSize ? pos : outSize - 1] = '\0';
  }
}
