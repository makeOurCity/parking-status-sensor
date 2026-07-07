#pragma once

#include <stdint.h>

#include "classify.h"

// Result of the previous wake cycle's delivery attempt.
// Persisted so the next cycle can report it (see docs/sync-delivery-design.md §4.2).
enum class CycleOutcome : uint8_t {
  kNone = 0,
  kConfirmed,
  kConnectFailed,
  kPublishFailed,
  kBudgetExhausted,
  kSensorError,
  kSkipped,
};

// Delivery ledger persisted in NVS (namespace pss_sync). Replaces the old
// FIFO outbox. Holds only the latest confirmed state, at most one pending
// observation (diagnostic in PoC full-send mode), and the previous cycle result.
struct SyncLedger {
  ParkingStatus lastConfirmedStatus = ParkingStatus::kUnknown;
  uint32_t lastConfirmedBoot = 0;

  bool pendingValid = false;
  uint32_t pendingBoot = 0;
  ParkingStatus pendingStatus = ParkingStatus::kUnknown;

  CycleOutcome prevOutcome = CycleOutcome::kNone;
  uint8_t prevAttempts = 0;
  int16_t prevMqttError = 0;
  uint32_t prevActiveMs = 0;
};

// Load the ledger into RAM. On first run (schemaVersion key absent) this also
// wipes the legacy pss_outbox namespace and writes initial values.
void initSyncLedger();

// The in-RAM snapshot loaded at boot: reflects state up to the *previous* cycle,
// which is what the outgoing payload should report.
const SyncLedger& syncLedger();

// Record a successful delivery (PUBACK). Clears pending, updates lastConfirmed*.
void ledgerRecordConfirmed(ParkingStatus status, uint32_t bootCount,
                           uint8_t attempts, int16_t mqttError,
                           uint32_t activeMs);

// Record a failed cycle. connect/publish/budget failures keep the current
// observation as pending (diagnostic); sensor/skip outcomes leave pending as-is.
void ledgerRecordFailure(CycleOutcome outcome, ParkingStatus status,
                         uint32_t bootCount, uint8_t attempts,
                         int16_t mqttError, uint32_t activeMs);

const char* cycleOutcomeToString(CycleOutcome outcome);
