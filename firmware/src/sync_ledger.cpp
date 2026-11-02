#include "sync_ledger.h"

#include <Arduino.h>
#include <Preferences.h>

namespace {

constexpr char kNamespace[] = "pss_sync";
constexpr char kLegacyOutboxNamespace[] = "pss_outbox";
constexpr uint8_t kSchemaVersion = 1;

// NVS keys (<= 15 chars).
constexpr char kKeySchema[] = "sv";
constexpr char kKeyLastStatus[] = "lstatus";
constexpr char kKeyLastBoot[] = "lboot";
constexpr char kKeyPendValid[] = "pval";
constexpr char kKeyPendBoot[] = "pboot";
constexpr char kKeyPendStatus[] = "pstatus";
constexpr char kKeyPrevOutcome[] = "pout";
constexpr char kKeyPrevAttempts[] = "patt";
constexpr char kKeyPrevMqttErr[] = "perr";
constexpr char kKeyPrevActiveMs[] = "pms";
constexpr char kKeySkippedSince[] = "skipn";

SyncLedger ledger;

// #123: the ledger's primary store is RTC memory; NVS is a best-effort backup.
//
// The ledger drives whether to send (state change / pending retry / heartbeat),
// so it must keep working when an NVS write fails. It used to live only in NVS;
// when NVS ran out of space (the history log's blob writes starved it) the
// heartbeat counter stopped advancing and the device went silent for 11 days.
//
// RTC memory survives Deep Sleep but is lost on power loss and on brownout
// (docs/74: bootCount goes back to 1, and boot mode runs only for power-on). On
// the next boot the ledger is then restored from the NVS backup; if that is
// missing or stale the worst case is an extra send (the safe direction).
// `skippedSinceConfirmed` is backed up too: a brownout loop must not reset the
// heartbeat count every cycle, which it would if the count lived only in RTC.
constexpr uint32_t kRtcMagic = 0x50535301;  // "PSS" + layout version 1

struct RtcLedger {
  uint32_t magic;  // kRtcMagic when valid; 0 after a power-on reset
  uint8_t lastConfirmedStatus;
  uint8_t pendingValid;
  uint8_t pendingStatus;
  uint8_t prevOutcome;
  uint8_t prevAttempts;
  uint8_t reserved;
  int16_t prevMqttError;
  uint32_t lastConfirmedBoot;
  uint32_t pendingBoot;
  uint32_t prevActiveMs;
  uint32_t skippedSinceConfirmed;
  uint32_t nvsWriteFailures;  // saturating; diagnostic
  uint32_t checksum;          // FNV-1a over every byte above
};

RTC_DATA_ATTR RtcLedger rtcLedger = {};

uint8_t statusToU8(ParkingStatus status) {
  return static_cast<uint8_t>(status);
}

ParkingStatus u8ToStatus(uint8_t value) {
  if (value > static_cast<uint8_t>(ParkingStatus::kUnknown)) {
    return ParkingStatus::kUnknown;
  }
  return static_cast<ParkingStatus>(value);
}

uint32_t rtcChecksum(const RtcLedger& r) {
  const uint8_t* p = reinterpret_cast<const uint8_t*>(&r);
  const size_t n = sizeof(RtcLedger) - sizeof(uint32_t);
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < n; ++i) {
    h = (h ^ p[i]) * 16777619u;
  }
  return h;
}

bool rtcValid() {
  return rtcLedger.magic == kRtcMagic &&
         rtcLedger.checksum == rtcChecksum(rtcLedger);
}

void rtcSeal() {
  rtcLedger.magic = kRtcMagic;
  rtcLedger.checksum = rtcChecksum(rtcLedger);
}

// Copy the in-RAM ledger into the RTC copy (keeps nvsWriteFailures).
void rtcStore() {
  rtcLedger.lastConfirmedStatus = statusToU8(ledger.lastConfirmedStatus);
  rtcLedger.pendingValid = ledger.pendingValid ? 1 : 0;
  rtcLedger.pendingStatus = statusToU8(ledger.pendingStatus);
  rtcLedger.prevOutcome = static_cast<uint8_t>(ledger.prevOutcome);
  rtcLedger.prevAttempts = ledger.prevAttempts;
  rtcLedger.reserved = 0;
  rtcLedger.prevMqttError = ledger.prevMqttError;
  rtcLedger.lastConfirmedBoot = ledger.lastConfirmedBoot;
  rtcLedger.pendingBoot = ledger.pendingBoot;
  rtcLedger.prevActiveMs = ledger.prevActiveMs;
  rtcLedger.skippedSinceConfirmed = ledger.skippedSinceConfirmed;
  rtcSeal();
}

void rtcLoad() {
  ledger.lastConfirmedStatus = u8ToStatus(rtcLedger.lastConfirmedStatus);
  ledger.lastConfirmedBoot = rtcLedger.lastConfirmedBoot;
  ledger.pendingValid = rtcLedger.pendingValid != 0;
  ledger.pendingBoot = rtcLedger.pendingBoot;
  ledger.pendingStatus = u8ToStatus(rtcLedger.pendingStatus);
  ledger.prevOutcome = static_cast<CycleOutcome>(rtcLedger.prevOutcome);
  ledger.prevAttempts = rtcLedger.prevAttempts;
  ledger.prevMqttError = rtcLedger.prevMqttError;
  ledger.prevActiveMs = rtcLedger.prevActiveMs;
  ledger.skippedSinceConfirmed = rtcLedger.skippedSinceConfirmed;
}

void wipeLegacyOutbox() {
  Preferences legacy;
  if (legacy.begin(kLegacyOutboxNamespace, false)) {
    legacy.clear();
    legacy.end();
    Serial.println("sync: wiped legacy pss_outbox namespace");
  }
}

// Best-effort NVS backup. Returns false if any write failed (e.g. NVS full).
// Preferences::put* return the number of bytes written, 0 on failure.
bool nvsStore() {
  Preferences prefs;
  if (!prefs.begin(kNamespace, false)) {
    return false;
  }
  bool ok = true;
  ok &= prefs.putUChar(kKeySchema, kSchemaVersion) == sizeof(uint8_t);
  ok &= prefs.putUChar(kKeyLastStatus, statusToU8(ledger.lastConfirmedStatus)) ==
        sizeof(uint8_t);
  ok &= prefs.putUInt(kKeyLastBoot, ledger.lastConfirmedBoot) == sizeof(uint32_t);
  ok &= prefs.putBool(kKeyPendValid, ledger.pendingValid) == sizeof(uint8_t);
  ok &= prefs.putUInt(kKeyPendBoot, ledger.pendingBoot) == sizeof(uint32_t);
  ok &= prefs.putUChar(kKeyPendStatus, statusToU8(ledger.pendingStatus)) ==
        sizeof(uint8_t);
  ok &= prefs.putUChar(kKeyPrevOutcome,
                       static_cast<uint8_t>(ledger.prevOutcome)) == sizeof(uint8_t);
  ok &= prefs.putUChar(kKeyPrevAttempts, ledger.prevAttempts) == sizeof(uint8_t);
  ok &= prefs.putShort(kKeyPrevMqttErr, ledger.prevMqttError) == sizeof(int16_t);
  ok &= prefs.putUInt(kKeyPrevActiveMs, ledger.prevActiveMs) == sizeof(uint32_t);
  ok &= prefs.putUInt(kKeySkippedSince, ledger.skippedSinceConfirmed) ==
        sizeof(uint32_t);
  prefs.end();
  return ok;
}

// RTC first (never fails), then the NVS backup. A failed backup is only counted
// and logged; it never changes what the ledger says.
void saveLedger() {
  rtcStore();
  if (!nvsStore()) {
    if (rtcLedger.nvsWriteFailures < UINT32_MAX) {
      rtcLedger.nvsWriteFailures++;
    }
    rtcSeal();
    Serial.printf("sync: NVS backup write failed (count=%lu), ledger kept in RTC\n",
                  static_cast<unsigned long>(rtcLedger.nvsWriteFailures));
  }
}

}  // namespace

void initSyncLedger() {
  // Normal case (Deep Sleep wake, power still on): the RTC copy is current.
  if (rtcValid()) {
    rtcLoad();
    Serial.printf(
        "sync: loaded ledger lastStatus=%s pending=%d prevOutcome=%s "
        "(source=rtc nvsFailures=%lu)\n",
        statusToString(ledger.lastConfirmedStatus), ledger.pendingValid ? 1 : 0,
        cycleOutcomeToString(ledger.prevOutcome),
        static_cast<unsigned long>(rtcLedger.nvsWriteFailures));
    return;
  }

  // Power-on (or damaged RTC): restore from the NVS backup.
  Preferences prefs;
  prefs.begin(kNamespace, true);
  const bool initialized = prefs.isKey(kKeySchema);

  if (initialized) {
    ledger.lastConfirmedStatus =
        u8ToStatus(prefs.getUChar(kKeyLastStatus,
                                  statusToU8(ParkingStatus::kUnknown)));
    ledger.lastConfirmedBoot = prefs.getUInt(kKeyLastBoot, 0);
    ledger.pendingValid = prefs.getBool(kKeyPendValid, false);
    ledger.pendingBoot = prefs.getUInt(kKeyPendBoot, 0);
    ledger.pendingStatus =
        u8ToStatus(prefs.getUChar(kKeyPendStatus,
                                  statusToU8(ParkingStatus::kUnknown)));
    ledger.prevOutcome =
        static_cast<CycleOutcome>(prefs.getUChar(kKeyPrevOutcome, 0));
    ledger.prevAttempts = prefs.getUChar(kKeyPrevAttempts, 0);
    ledger.prevMqttError = prefs.getShort(kKeyPrevMqttErr, 0);
    ledger.prevActiveMs = prefs.getUInt(kKeyPrevActiveMs, 0);
    ledger.skippedSinceConfirmed = prefs.getUInt(kKeySkippedSince, 0);
    prefs.end();
    rtcLedger = RtcLedger{};
    rtcStore();  // seed the RTC copy so later cycles do not touch NVS
    Serial.printf(
        "sync: loaded ledger lastStatus=%s pending=%d prevOutcome=%s "
        "(source=nvs)\n",
        statusToString(ledger.lastConfirmedStatus), ledger.pendingValid ? 1 : 0,
        cycleOutcomeToString(ledger.prevOutcome));
    return;
  }

  // First run: migrate from the legacy FIFO outbox by discarding it, then
  // write initial values. Stale (>5 min) snapshots have no delivery value.
  prefs.end();
  Serial.println("sync: first run, initializing ledger (migrating from outbox)");
  wipeLegacyOutbox();
  ledger = SyncLedger{};
  rtcLedger = RtcLedger{};
  saveLedger();
}

uint32_t syncLedgerNvsFailures() { return rtcLedger.nvsWriteFailures; }

const SyncLedger& syncLedger() { return ledger; }

void ledgerRecordConfirmed(ParkingStatus status, uint32_t bootCount,
                           uint8_t attempts, int16_t mqttError,
                           uint32_t activeMs) {
  ledger.lastConfirmedStatus = status;
  ledger.lastConfirmedBoot = bootCount;
  ledger.pendingValid = false;
  ledger.prevOutcome = CycleOutcome::kConfirmed;
  ledger.prevAttempts = attempts;
  ledger.prevMqttError = mqttError;
  ledger.prevActiveMs = activeMs;
  ledger.skippedSinceConfirmed = 0;
  saveLedger();
}

void ledgerRecordFailure(CycleOutcome outcome, ParkingStatus status,
                         uint32_t bootCount, uint8_t attempts,
                         int16_t mqttError, uint32_t activeMs) {
  // connect/publish/budget failures carry the current observation as pending
  // (diagnostic only in PoC). sensor_error has no valid observation; skipped
  // means we intentionally did not publish. Neither updates pending.
  const bool hasObservation = outcome == CycleOutcome::kConnectFailed ||
                              outcome == CycleOutcome::kPublishFailed ||
                              outcome == CycleOutcome::kBudgetExhausted;
  if (hasObservation) {
    ledger.pendingValid = true;
    ledger.pendingBoot = bootCount;
    ledger.pendingStatus = status;
  }
  ledger.prevOutcome = outcome;
  ledger.prevAttempts = attempts;
  ledger.prevMqttError = mqttError;
  ledger.prevActiveMs = activeMs;
  if (outcome == CycleOutcome::kSkipped) {
    ledger.skippedSinceConfirmed++;
  }
  saveLedger();
}

const char* cycleOutcomeToString(CycleOutcome outcome) {
  switch (outcome) {
    case CycleOutcome::kConfirmed:
      return "confirmed";
    case CycleOutcome::kConnectFailed:
      return "connect_failed";
    case CycleOutcome::kPublishFailed:
      return "publish_failed";
    case CycleOutcome::kBudgetExhausted:
      return "budget_exhausted";
    case CycleOutcome::kSensorError:
      return "sensor_error";
    case CycleOutcome::kSkipped:
      return "skipped";
    case CycleOutcome::kNone:
    default:
      return "none";
  }
}
