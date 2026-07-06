#include "outbox.h"

#include <Arduino.h>
#include <Preferences.h>
#include <string.h>

namespace {

constexpr char kNamespace[] = "pss_outbox";
constexpr char kCountKey[] = "count";
constexpr uint8_t kMaxItems = 3;
constexpr size_t kMaxPayload = 1024;

Preferences prefs;

String itemKey(uint8_t index) { return String("item") + index; }

}  // namespace

void initOutbox() {
  prefs.begin(kNamespace, false);
  prefs.end();
}

uint8_t outboxCount() {
  prefs.begin(kNamespace, true);
  const uint8_t count = prefs.getUChar(kCountKey, 0);
  prefs.end();
  return count;
}

bool outboxPeek(char* out, size_t outSize) {
  if (out == nullptr || outSize == 0) {
    return false;
  }

  prefs.begin(kNamespace, true);
  const uint8_t count = prefs.getUChar(kCountKey, 0);
  if (count == 0) {
    prefs.end();
    return false;
  }

  const String payload = prefs.getString(itemKey(0).c_str(), "");
  prefs.end();

  if (payload.length() == 0 || payload.length() >= outSize) {
    return false;
  }

  strncpy(out, payload.c_str(), outSize - 1);
  out[outSize - 1] = '\0';
  return true;
}

bool outboxEnqueue(const char* payload) {
  if (payload == nullptr || payload[0] == '\0') {
    return false;
  }

  const size_t len = strlen(payload);
  if (len >= kMaxPayload) {
    Serial.println("outbox: payload too large");
    return false;
  }

  prefs.begin(kNamespace, false);
  uint8_t count = prefs.getUChar(kCountKey, 0);

  if (count >= kMaxItems) {
    Serial.println("outbox: full, dropping oldest");
    for (uint8_t i = 1; i < count; ++i) {
      const String next = prefs.getString(itemKey(i).c_str(), "");
      prefs.putString(itemKey(i - 1).c_str(), next);
    }
    count = kMaxItems;
  } else {
    ++count;
  }

  prefs.putString(itemKey(count - 1).c_str(), payload);
  prefs.putUChar(kCountKey, count);
  prefs.end();

  Serial.printf("outbox: enqueued (%u pending)\n", count);
  return true;
}

void outboxDequeue() {
  prefs.begin(kNamespace, false);
  uint8_t count = prefs.getUChar(kCountKey, 0);
  if (count == 0) {
    prefs.end();
    return;
  }

  for (uint8_t i = 1; i < count; ++i) {
    const String next = prefs.getString(itemKey(i).c_str(), "");
    prefs.putString(itemKey(i - 1).c_str(), next);
  }
  prefs.remove(itemKey(count - 1).c_str());
  --count;
  prefs.putUChar(kCountKey, count);
  prefs.end();

  Serial.printf("outbox: dequeued (%u remaining)\n", count);
}
