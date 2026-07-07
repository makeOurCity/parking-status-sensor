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

SyncLedger ledger;

uint8_t statusToU8(ParkingStatus status) {
  return static_cast<uint8_t>(status);
}

ParkingStatus u8ToStatus(uint8_t value) {
  if (value > static_cast<uint8_t>(ParkingStatus::kUnknown)) {
    return ParkingStatus::kUnknown;
  }
  return static_cast<ParkingStatus>(value);
}

void wipeLegacyOutbox() {
  Preferences legacy;
  if (legacy.begin(kLegacyOutboxNamespace, false)) {
    legacy.clear();
    legacy.end();
    Serial.println("sync: wiped legacy pss_outbox namespace");
  }
}

void persist() {
  Preferences prefs;
  prefs.begin(kNamespace, false);
  prefs.putUChar(kKeySchema, kSchemaVersion);
  prefs.putUChar(kKeyLastStatus, statusToU8(ledger.lastConfirmedStatus));
  prefs.putUInt(kKeyLastBoot, ledger.lastConfirmedBoot);
  prefs.putBool(kKeyPendValid, ledger.pendingValid);
  prefs.putUInt(kKeyPendBoot, ledger.pendingBoot);
  prefs.putUChar(kKeyPendStatus, statusToU8(ledger.pendingStatus));
  prefs.putUChar(kKeyPrevOutcome, static_cast<uint8_t>(ledger.prevOutcome));
  prefs.putUChar(kKeyPrevAttempts, ledger.prevAttempts);
  prefs.putShort(kKeyPrevMqttErr, ledger.prevMqttError);
  prefs.putUInt(kKeyPrevActiveMs, ledger.prevActiveMs);
  prefs.end();
}

}  // namespace

void initSyncLedger() {
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
    prefs.end();
    Serial.printf(
        "sync: loaded ledger lastStatus=%s pending=%d prevOutcome=%s\n",
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
  persist();
}

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
  persist();
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
  persist();
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
