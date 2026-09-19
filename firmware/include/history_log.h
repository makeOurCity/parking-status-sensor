#pragma once

#include <stdint.h>

#include "classify.h"
#include "sensor.h"

// Local diagnostic log of per-cycle observations, kept in a fixed-size NVS
// ring buffer (namespace "pss_hlog"). Read-only from the device's point of
// view: it never triggers LTE/MQTT and is never included in the MQTT
// payload. See docs/47-history-log-design.md.
//
// Independent from SyncLedger (namespace "pss_sync"): this module owns no
// key that mustPublish()/publishWithRetry() reads or writes, and it never
// includes transport.h/relay.h/sync_ledger.h.

// Loads (or initializes) the pss_hlog namespace. Call once in setup(),
// after initSyncLedger().
void initHistoryLog();

// Appends one entry unconditionally. Call once per cycle, right after
// classifyStatus() produces a valid status — never from a path where the
// sensor read failed (there is no observation to record).
void historyLogRecordCycle(ParkingStatus status, const RawSample& sample,
                            uint32_t bootCount);

// Dumps the whole ring buffer (or config::kHistoryLogDumpMax entries,
// newest first) to Serial. Intended for a non-timer wake (USB reconnect)
// or the 'h' serial command; do not call from the timer-wake steady state.
void historyLogDumpToSerial();

// Diagnostic accessors.
uint32_t historyLogStoredCount();    // valid entries currently held (<= capacity)
uint32_t historyLogLifetimeTotal();  // cumulative cycles recorded (survives wraparound)
