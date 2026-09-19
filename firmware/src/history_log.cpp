#include "history_log.h"

#include <Arduino.h>
#include <Preferences.h>
#include <nvs_flash.h>
#include <string.h>
#include <time.h>

#include "config.h"

namespace {

constexpr char kNamespace[] = "pss_hlog";
constexpr uint8_t kSchemaVersion = 1;

// NVS keys (<= 15 chars, same convention as sync_ledger.cpp).
constexpr char kKeySchema[] = "sv";
constexpr char kKeyCapacity[] = "cap";
constexpr char kKeySegments[] = "segs";
constexpr char kKeyTotal[] = "total";

constexpr uint16_t kCapacity = config::kHistoryLogCapacity;
constexpr uint16_t kSegments = config::kHistoryLogSegments;
constexpr uint16_t kEntriesPerSegment = kCapacity / kSegments;
constexpr size_t kEntrySize = 16;
constexpr size_t kSegmentBytes = static_cast<size_t>(kEntriesPerSegment) * kEntrySize;

// Same threshold as main.cpp's formatTimestamp(): reject clocks that
// haven't been set from network time yet (modem power-on defaults, or a
// cold RTC domain after a full power loss). Duplicated here rather than
// shared, to keep this module free of any dependency on main.cpp's
// internals; see docs/47-history-log-design.md §3.4.
// NOTE: main.cpp's formatTimestamp() uses the same threshold (1700000000).
// Keep both in sync if this value ever changes.
constexpr time_t kMinValidEpoch = 1700000000;

uint32_t gTotal = 0;
bool gInitialized = false;

void segmentKeyFor(uint16_t segIndex, char* out, size_t outSize) {
  snprintf(out, outSize, "seg%u", segIndex);
}

// (epoch, synced) — synced=false means epoch is 0 and must not be
// interpreted as a real timestamp.
void currentTimestampOrZero(uint32_t* outEpoch, bool* outSynced) {
  const time_t now = time(nullptr);
  if (now <= kMinValidEpoch) {
    *outEpoch = 0;
    *outSynced = false;
    return;
  }
  *outEpoch = static_cast<uint32_t>(now);
  *outSynced = true;
}

void encodeEntry(uint8_t out[16], uint32_t timestampEpoch, bool synced,
                  ParkingStatus status, uint8_t bootCountLo8, uint16_t red,
                  uint16_t green, uint16_t blue, uint16_t white) {
  out[0] = static_cast<uint8_t>(timestampEpoch & 0xFF);
  out[1] = static_cast<uint8_t>((timestampEpoch >> 8) & 0xFF);
  out[2] = static_cast<uint8_t>((timestampEpoch >> 16) & 0xFF);
  out[3] = static_cast<uint8_t>((timestampEpoch >> 24) & 0xFF);
  out[4] = static_cast<uint8_t>(status);
  out[5] = synced ? 0x01 : 0x00;
  out[6] = bootCountLo8;
  out[7] = 0;  // reserved
  out[8] = static_cast<uint8_t>(red & 0xFF);
  out[9] = static_cast<uint8_t>((red >> 8) & 0xFF);
  out[10] = static_cast<uint8_t>(green & 0xFF);
  out[11] = static_cast<uint8_t>((green >> 8) & 0xFF);
  out[12] = static_cast<uint8_t>(blue & 0xFF);
  out[13] = static_cast<uint8_t>((blue >> 8) & 0xFF);
  out[14] = static_cast<uint8_t>(white & 0xFF);
  out[15] = static_cast<uint8_t>((white >> 8) & 0xFF);
}

struct DecodedEntry {
  uint32_t timestampEpoch;
  bool synced;
  ParkingStatus status;
  uint8_t bootCountLo8;
  uint16_t red, green, blue, white;
};

DecodedEntry decodeEntry(const uint8_t in[16]) {
  DecodedEntry e{};
  e.timestampEpoch = static_cast<uint32_t>(in[0]) |
                      (static_cast<uint32_t>(in[1]) << 8) |
                      (static_cast<uint32_t>(in[2]) << 16) |
                      (static_cast<uint32_t>(in[3]) << 24);
  e.status = static_cast<ParkingStatus>(in[4]);
  e.synced = (in[5] & 0x01) != 0;
  e.bootCountLo8 = in[6];
  e.red = static_cast<uint16_t>(in[8] | (in[9] << 8));
  e.green = static_cast<uint16_t>(in[10] | (in[11] << 8));
  e.blue = static_cast<uint16_t>(in[12] | (in[13] << 8));
  e.white = static_cast<uint16_t>(in[14] | (in[15] << 8));
  return e;
}

void loadSegment(Preferences& prefs, uint16_t segIndex, uint8_t* buf) {
  char key[16];
  segmentKeyFor(segIndex, key, sizeof(key));
  const size_t got = prefs.getBytes(key, buf, kSegmentBytes);
  if (got != kSegmentBytes) {
    memset(buf, 0, kSegmentBytes);
  }
}

void storeSegment(Preferences& prefs, uint16_t segIndex, const uint8_t* buf) {
  char key[16];
  segmentKeyFor(segIndex, key, sizeof(key));
  prefs.putBytes(key, buf, kSegmentBytes);
}

void writeInitialValues(Preferences& prefs) {
  prefs.putUChar(kKeySchema, kSchemaVersion);
  prefs.putUShort(kKeyCapacity, kCapacity);
  prefs.putUShort(kKeySegments, kSegments);
  prefs.putUInt(kKeyTotal, 0);
  gTotal = 0;
}

// #47 design doc §9.3: confirm the on-disk NVS budget against the model in
// §2.3/§2.4 (fixed per-key overhead) rather than trusting the arithmetic
// alone. Cheap; printed at the end of historyLogDumpToSerial() rather than
// at boot — ESP32-S3 native USB CDC reliably drops the first several
// Serial.print lines emitted right after a host reconnects post-reset, so
// anything printed immediately in initHistoryLog() was consistently lost
// in the field. The dump itself survives because it's long enough to
// outlast that window; stats appended after it inherit that reliability.
void logNvsStats() {
  nvs_stats_t stats{};
  const esp_err_t err = nvs_get_stats(nullptr, &stats);
  if (err != ESP_OK) {
    Serial.printf("hlog: nvs_get_stats failed err=%d\n", static_cast<int>(err));
    return;
  }
  Serial.printf(
      "hlog: nvs stats used=%d free=%d total=%d namespaces=%d\n",
      static_cast<int>(stats.used_entries), static_cast<int>(stats.free_entries),
      static_cast<int>(stats.total_entries),
      static_cast<int>(stats.namespace_count));
}

}  // namespace

void initHistoryLog() {
  if (!config::kHistoryLogEnabled) {
    return;
  }

  Preferences prefs;
  prefs.begin(kNamespace, false);

  const bool initialized = prefs.isKey(kKeySchema);
  if (!initialized) {
    Serial.println("hlog: first run, initializing ring buffer");
    writeInitialValues(prefs);
    prefs.end();
    gInitialized = true;
    return;
  }

  const uint8_t storedSchema = prefs.getUChar(kKeySchema, 0);
  const uint16_t storedCap = prefs.getUShort(kKeyCapacity, 0);
  const uint16_t storedSegs = prefs.getUShort(kKeySegments, 0);

  if (storedSchema != kSchemaVersion || storedCap != kCapacity ||
      storedSegs != kSegments) {
    // Layout changed (firmware rebuilt with a different capacity/segments).
    // This is a diagnostics-only log, so favor safety over continuity:
    // wipe and reinitialize rather than risk misreading stale segments.
    Serial.printf(
        "hlog: layout changed (sv %u->%u cap %u->%u segs %u->%u), "
        "resetting ring buffer\n",
        storedSchema, kSchemaVersion, storedCap, kCapacity, storedSegs,
        kSegments);
    prefs.clear();
    writeInitialValues(prefs);
    prefs.end();
    gInitialized = true;
    return;
  }

  gTotal = prefs.getUInt(kKeyTotal, 0);
  prefs.end();
  gInitialized = true;
  Serial.printf("hlog: loaded total=%lu capacity=%u\n",
                static_cast<unsigned long>(gTotal), kCapacity);
}

void historyLogRecordCycle(ParkingStatus status, const RawSample& sample,
                            uint32_t bootCount) {
  if (!config::kHistoryLogEnabled || !gInitialized) {
    return;
  }

  uint32_t ts = 0;
  bool synced = false;
  currentTimestampOrZero(&ts, &synced);

  uint8_t entry[kEntrySize];
  encodeEntry(entry, ts, synced, status, static_cast<uint8_t>(bootCount & 0xFF),
              sample.red, sample.green, sample.blue, sample.white);

  const uint16_t segIndex =
      static_cast<uint16_t>((gTotal / kEntriesPerSegment) % kSegments);
  const uint16_t offset =
      static_cast<uint16_t>(gTotal % kEntriesPerSegment);

  Preferences prefs;
  prefs.begin(kNamespace, false);

  uint8_t seg[kSegmentBytes];
  loadSegment(prefs, segIndex, seg);
  memcpy(seg + static_cast<size_t>(offset) * kEntrySize, entry, kEntrySize);
  storeSegment(prefs, segIndex, seg);

  gTotal++;
  prefs.putUInt(kKeyTotal, gTotal);
  prefs.end();
}

void historyLogDumpToSerial() {
  if (!config::kHistoryLogEnabled || !gInitialized) {
    return;
  }

  const uint32_t count =
      (gTotal < kCapacity) ? gTotal : static_cast<uint32_t>(kCapacity);
  const uint32_t dumpMax = config::kHistoryLogDumpMax;
  const uint32_t shown = (dumpMax == 0 || dumpMax > count) ? count : dumpMax;

  Serial.printf("history: count=%lu capacity=%u%s\n",
                static_cast<unsigned long>(count), kCapacity,
                count >= kCapacity ? " (full)" : "");

  if (shown == 0) {
    logNvsStats();
    return;
  }

  Preferences prefs;
  prefs.begin(kNamespace, true);

  uint8_t seg[kSegmentBytes];
  int16_t cachedSegIndex = -1;

  for (uint32_t i = 0; i < shown; ++i) {
    const uint32_t seq = gTotal - 1 - i;  // newest first
    const uint16_t segIndex =
        static_cast<uint16_t>((seq / kEntriesPerSegment) % kSegments);
    const uint16_t offset = static_cast<uint16_t>(seq % kEntriesPerSegment);

    if (segIndex != cachedSegIndex) {
      loadSegment(prefs, segIndex, seg);
      cachedSegIndex = static_cast<int16_t>(segIndex);
    }

    const DecodedEntry e =
        decodeEntry(seg + static_cast<size_t>(offset) * kEntrySize);

    char timestampStr[24] = "<unsynced>";
    if (e.synced) {
      const time_t t = static_cast<time_t>(e.timestampEpoch);
      tm utc{};
      gmtime_r(&t, &utc);
      strftime(timestampStr, sizeof(timestampStr), "%Y-%m-%dT%H:%M:%SZ", &utc);
    }

    Serial.printf(
        "[%lu] boot=%u %-20s status=%-9s r=%u g=%u b=%u w=%u\n",
        static_cast<unsigned long>(i), e.bootCountLo8, timestampStr,
        statusToString(e.status), e.red, e.green, e.blue, e.white);
  }

  prefs.end();
  logNvsStats();
}

uint32_t historyLogStoredCount() {
  return (gTotal < kCapacity) ? gTotal : static_cast<uint32_t>(kCapacity);
}

uint32_t historyLogLifetimeTotal() { return gTotal; }
