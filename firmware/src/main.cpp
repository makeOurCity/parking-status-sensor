#include <Arduino.h>
#include <ArduinoJson.h>
#include <esp_sleep.h>
#include <esp_system.h>
#include <esp_task_wdt.h>
#include <esp_timer.h>
#include <string.h>
#include <time.h>

#include "board.h"
#include "classify.h"
#include "config.h"
#include "device_id.h"
#include "history_log.h"
#include "potentiometer.h"
#include "relay.h"
#include "sensor.h"
#include "sync_ledger.h"
#include "transport.h"

namespace {

constexpr uint32_t kSerialWaitMs = 3000;
constexpr size_t kPayloadSize = 1024;

RTC_DATA_ATTR uint32_t bootCount = 0;
RTC_DATA_ATTR uint64_t lastSleepEntryUs = 0;
RTC_DATA_ATTR uint32_t lastActiveMs = 0;
RTC_DATA_ATTR uint32_t consecutiveTimerWakes = 0;

struct WakeDiagnostics {
  bool hasPrevSleep = false;
  int64_t measuredIntervalMs = 0;
  int64_t expectedIntervalMs = 0;
  int64_t oversleepMs = 0;
};

WakeDiagnostics wakeDiag{};

// #47: set from within waitForSerial()'s existing wait window when the
// 'h' command is seen; consumed once in setup() to force a history dump
// outside the usual non-timer-wake trigger.
bool forceHistoryDump = false;

void computeWakeDiagnostics() {
  const uint64_t nowUs = esp_timer_get_time();
  if (lastSleepEntryUs != 0 && nowUs > lastSleepEntryUs) {
    wakeDiag.hasPrevSleep = true;
    wakeDiag.measuredIntervalMs =
        static_cast<int64_t>((nowUs - lastSleepEntryUs) / 1000ULL) +
        lastActiveMs;
    wakeDiag.expectedIntervalMs =
        static_cast<int64_t>(config::kSleepSeconds) * 1000 + lastActiveMs;
    wakeDiag.oversleepMs =
        wakeDiag.measuredIntervalMs - wakeDiag.expectedIntervalMs;
  }
}

void waitForSerial() {
  const uint32_t start = millis();
  while (!Serial && (millis() - start) < kSerialWaitMs) {
    delay(10);
  }
  // #47: non-blocking check within the existing wait window — adds no new
  // delay. 'h' forces a history dump in setup() even on a timer wake (e.g.
  // a bench debug build with Deep Sleep disabled).
  while (Serial.available()) {
    if (Serial.read() == 'h') {
      forceHistoryDump = true;
    }
  }
}

const char* wakeCauseToString(esp_sleep_wakeup_cause_t cause) {
  switch (cause) {
    case ESP_SLEEP_WAKEUP_TIMER:
      return "timer";
    case ESP_SLEEP_WAKEUP_UNDEFINED:
      return "power_on";
    default:
      return "other";
  }
}

const char* resetReasonToString(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON:
      return "power_on";
    case ESP_RST_BROWNOUT:
      return "brownout";
    case ESP_RST_DEEPSLEEP:
      return "deep_sleep";
    case ESP_RST_SW:
      return "software";
    case ESP_RST_PANIC:
      return "panic";
    case ESP_RST_TASK_WDT:
      return "task_wdt";
    case ESP_RST_INT_WDT:
      return "int_wdt";
    case ESP_RST_WDT:
      return "wdt";
    default:
      return "other";
  }
}

bool formatTimestamp(char* out, size_t outSize) {
  time_t now = time(nullptr);
  if (now <= 1700000000) {
    out[0] = '\0';
    return false;
  }

  tm utc{};
  gmtime_r(&now, &utc);
  strftime(out, outSize, "%Y-%m-%dT%H:%M:%SZ", &utc);
  return true;
}

void sleepNow(const char* reason, uint32_t activeMs) {
  Serial.printf("sleep reason=%s seconds=%lu active_ms=%lu pending=%d\n", reason,
                static_cast<unsigned long>(config::kSleepSeconds),
                static_cast<unsigned long>(activeMs),
                syncLedger().pendingValid ? 1 : 0);
  Serial.flush();

  disconnectTransport();
  if (config::kLtePowerRelayEnabled) {
    // #46: どの復帰経路でもここを必ず通るため、setup()先頭の安全パルスと
    // 合わせた二重のフェイルセーフになる（無条件でRESET、既にOFFなら無害）。
    relayLteOff();
  }

  lastActiveMs = activeMs;
  lastSleepEntryUs = esp_timer_get_time();

  if (config::kDisableDeepSleep) {
    delay(config::kDebugLoopDelayMs);
    return;
  }

  esp_sleep_enable_timer_wakeup(
      static_cast<uint64_t>(config::kSleepSeconds) * 1000000ULL);
  esp_deep_sleep_start();
}

// #50: boot-mode send metadata, threaded through buildPayload()/publishWithRetry()
// so the outgoing MQTT payload itself (not just Serial logs) lets a remote
// viewer (cloud dashboard/logs) tell boot-mode sends apart from normal cycles.
struct BootModeSendInfo {
  bool active = false;     // true while inside runBootMode()
  uint8_t slot = 0;        // 1-based send index; 0 outside boot mode
  uint8_t totalSlots = 0;  // config::kBootModeSendCount; 0 outside boot mode

  BootModeSendInfo() = default;
  BootModeSendInfo(bool activeIn, uint8_t slotIn, uint8_t totalSlotsIn)
      : active(activeIn), slot(slotIn), totalSlots(totalSlotsIn) {}
};

void buildPayload(const RawSample& sample, ParkingStatus status,
                  const TransportMetrics& transportMetrics, uint32_t activeMs,
                  uint8_t publishAttempts, const BootModeSendInfo& bootModeInfo,
                  const PotReading& potReading, char* out, size_t outSize) {
  JsonDocument doc;

  char timestamp[25]{};
  const bool hasTimestamp = formatTimestamp(timestamp, sizeof(timestamp));

  doc["deviceId"] = getDeviceId();
  doc["status"] = statusToString(status);

  JsonObject raw = doc["raw"].to<JsonObject>();
  raw["red"] = sample.red;
  raw["green"] = sample.green;
  raw["blue"] = sample.blue;
  raw["clear"] = sample.white;

  doc["threshold"] = potReading.threshold;  // #60: 実効閾値(ポット有効時は算出値)
  doc["determinedBy"] = "device";
  if (hasTimestamp) {
    doc["timestamp"] = timestamp;
  } else {
    doc["timestamp"] = nullptr;
  }

  JsonObject power = doc["power"].to<JsonObject>();
  power["bootCount"] = bootCount;
  power["wakeCause"] = wakeCauseToString(esp_sleep_get_wakeup_cause());
  power["resetReason"] = resetReasonToString(esp_reset_reason());
  power["activeMsBeforePublish"] = activeMs;
  power["sleepSeconds"] = config::kSleepSeconds;
  power["timerWakes"] = consecutiveTimerWakes;
  if (wakeDiag.hasPrevSleep) {
    JsonObject wake = power["wakeInterval"].to<JsonObject>();
    wake["measuredMs"] = wakeDiag.measuredIntervalMs;
    wake["expectedMs"] = wakeDiag.expectedIntervalMs;
    wake["oversleepMs"] = wakeDiag.oversleepMs;
  }

  JsonObject network = doc["network"].to<JsonObject>();
  network["transport"] = transportName(transportMetrics.transport);
  network["fallback"] = transportMetrics.usedFallback;
  network["wifiRssi"] = transportMetrics.wifiRssi;
  network["networkConnectMs"] = transportMetrics.networkConnectMs;
  network["mqttConnectMs"] = transportMetrics.mqttConnectMs;
  network["tcpTlsConnectMs"] = transportMetrics.tcpTlsConnectMs;
  network["mqttHandshakeMs"] = transportMetrics.mqttHandshakeMs;
  network["publishMs"] = transportMetrics.publishMs;
  network["transportAttempts"] = transportMetrics.transportAttempts;
  network["mqttQos"] = config::kMqttQos;
  network["publishAttempts"] = publishAttempts;

  // Delivery/diagnostic ledger reflecting state up to the previous cycle.
  // deliveryConfirmed is intentionally omitted: QoS1 cannot rewrite an
  // already-sent message, so confirmation is expressed via sync.prevOutcome.
  const SyncLedger& ledger = syncLedger();
  JsonObject sync = doc["sync"].to<JsonObject>();
  sync["lastConfirmedStatus"] = statusToString(ledger.lastConfirmedStatus);
  sync["lastConfirmedBootCount"] = ledger.lastConfirmedBoot;
  sync["pending"] = ledger.pendingValid;
  sync["prevOutcome"] = cycleOutcomeToString(ledger.prevOutcome);
  sync["prevAttempts"] = ledger.prevAttempts;
  sync["prevMqttError"] = ledger.prevMqttError;
  sync["prevActiveMs"] = ledger.prevActiveMs;

  // #50: always emit the object (active=false outside boot mode) so the
  // payload schema stays constant regardless of which path produced it.
  JsonObject bootMode = doc["bootMode"].to<JsonObject>();
  bootMode["active"] = bootModeInfo.active;
  bootMode["slot"] = bootModeInfo.slot;
  bootMode["totalSlots"] = bootModeInfo.totalSlots;

  // #60: 現地でのポット調整履歴を追跡できるよう、生ADC値も併記する。
  JsonObject pot = doc["pot"].to<JsonObject>();
  pot["enabled"] = config::kPotEnabled;
  pot["adcRaw"] = potReading.raw;

  serializeJson(doc, out, outSize);
}

// PoC keeps full transmission (always publish) unless PSS_CHANGE_ONLY_SEND is
// enabled (#25/#46), in which case LTE-M is only powered up on state change,
// undelivered retry, or heartbeat — see docs/25-low-power-phase2-hardware-cutoff.md §2.5.
bool mustPublish(ParkingStatus status) {
  if (!config::kChangeOnlySend) {
    (void)status;
    return true;  // PoC: full transmission every cycle
  }

  const SyncLedger& ledger = syncLedger();
  if (ledger.pendingValid) {
    return true;  // retry the undelivered observation this cycle
  }
  if (status != ledger.lastConfirmedStatus) {
    return true;  // state change
  }
  return ledger.skippedSinceConfirmed >= config::kHeartbeatCycles;
}

// Publish the current observation with bounded retries inside the publish-phase
// budget. Between attempts only the MQTT layer is reconnected (LTE bearer kept,
// modem never powered off here — that happens only at sleep). Returns true on
// PUBACK.
bool publishWithRetry(const RawSample& sample, ParkingStatus status,
                      TransportMetrics& metrics, uint32_t cycleStart,
                      bool faultInject, const BootModeSendInfo& bootModeInfo,
                      const PotReading& potReading, char* payload,
                      size_t payloadSize, PublishResult& result) {
  result = PublishResult{};
  const uint32_t phaseStart = millis();

  for (uint8_t attempt = 1; attempt <= config::kPublishMaxAttempts; ++attempt) {
    if ((millis() - cycleStart) >= config::kCycleMaxActiveMs) {
      Serial.println("publish budget exhausted (cycle)");
      break;
    }
    if ((millis() - phaseStart) >= config::kPublishPhaseMs) {
      Serial.println("publish budget exhausted (phase)");
      break;
    }

    if (attempt > 1) {
      delay(config::kRetryDelayMs);
      if (!reconnectActiveTransport(metrics)) {
        continue;
      }
    }

    result.attempts = attempt;
    Serial.printf("publish attempt %u/%u\n", attempt, config::kPublishMaxAttempts);

    // Build immediately before publish. sync.* reflects the previous cycle,
    // which is the correct state to report alongside this observation.
    buildPayload(sample, status, metrics, millis() - cycleStart, attempt,
                 bootModeInfo, potReading, payload, payloadSize);

    if (faultInject) {
      Serial.println("FAULT INJECT: forcing publish failure");
      continue;
    }

    if (publishTelemetryConfirmed(payload, metrics)) {
      result.confirmed = true;
      return true;
    }
  }

  return false;
}

void runLteTest() {
  Serial.printf("board=%s lte-test boot=%lu reset=%s\n", BOARD_NAME,
                static_cast<unsigned long>(bootCount),
                resetReasonToString(esp_reset_reason()));

  LteProbeResult result{};
  probeLteModem(result);
  printLteProbeResult(result);
  disconnectTransport();

  Serial.println("retry in 30s...");
  delay(30000);
}

void runLtePoweroffTest() {
  static uint8_t cycle = 0;
  ++cycle;

  const bool tryRadioOff = (cycle % 2) == 0;

  Serial.printf("\n=== LTE poweroff test cycle %u (%s) ===\n", cycle,
                tryRadioOff ? "CFUN=0 radioOff" : "CPOWD enhanced");
  Serial.printf("board=%s boot=%lu reset=%s\n", BOARD_NAME,
                static_cast<unsigned long>(bootCount),
                resetReasonToString(esp_reset_reason()));
  Serial.println(
      "Purpose: attach LTE -> shutdown -> observe NETLIGHT -> recover attach");
  Serial.println("Deep Sleep is OFF; Serial stays up for the whole cycle.");

  Serial.println("\n[1/5] attach (network + data bearer)");
  LteProbeResult attach{};
  const bool attachOk = probeLteModem(attach);
  printLteProbeResult(attach);
  if (!attachOk) {
    Serial.println("RESULT: attach FAIL — retry in 30s");
    delay(30000);
    return;
  }
  Serial.println(">> NETLIGHT should blink ~3s while attached");

  Serial.println(tryRadioOff
                     ? "\n[2/5] radioOff (CNACT/CGATT detach + AT+CFUN=0)"
                     : "\n[2/5] poweroff (detach + AT+CPOWD=1 + post-check)");
  const uint32_t shutdownStart = millis();
  LtePoweroffResult detail{};
  const bool shutdownOk =
      tryRadioOff ? radioOffLteModem() : powerOffLteModem(&detail);
  if (tryRadioOff) {
    Serial.printf("radioOffLteModem() => %s (%lu ms)\n",
                  shutdownOk ? "CFUN=0 ok" : "fail",
                  static_cast<unsigned long>(millis() - shutdownStart));
  } else {
    Serial.printf(
        "powerOffLteModem() => %s cpowd=%s silent=%s radioOffFallback=%s "
        "(%lu ms)\n",
        shutdownOk ? "FULL OK" : "partial/fail",
        detail.cpowdAccepted ? "yes" : "no", detail.modemSilent ? "yes" : "no",
        detail.radioOffFallback ? "yes" : "no",
        static_cast<unsigned long>(detail.elapsedMs));
  }

  Serial.println("\n[3/5] post-shutdown AT probe (UART restarted)");
  const bool atAfter = probeLteModemAt(3000);
  Serial.printf(">> modem AT after shutdown: %s (silent = poweroff OK)\n",
                atAfter ? "RESPONSE" : "silent");

  Serial.printf("\n[4/5] observe NETLIGHT for %lu s\n",
                static_cast<unsigned long>(config::kLtePoweroffObserveMs / 1000));
  Serial.println(">> expect OFF if true poweroff/PSM; 3s blink = still registered");
  delay(config::kLtePoweroffObserveMs);

  Serial.println("\n[5/5] recover (cold probe after shutdown)");
  resetLteRadioCache();
  LteProbeResult recover{};
  const bool recoverOk = probeLteModem(recover);
  printLteProbeResult(recover);
  Serial.printf("recover attach => %s\n", recoverOk ? "OK" : "FAIL");

  LtePoweroffResult cleanup{};
  const bool cleanupOk = powerOffLteModem(&cleanup);
  Serial.printf("cleanup powerOffLteModem() => cpowd=%s silent=%s\n",
                cleanup.cpowdAccepted ? "yes" : "no",
                cleanup.modemSilent ? "yes" : "no");

  Serial.println("--- cycle summary ---");
  Serial.printf("mode=%s attach=%s shutdown=%s atAfter=%s recover=%s\n",
                tryRadioOff ? "CFUN=0" : "CPOWD", attachOk ? "ok" : "ng",
                shutdownOk ? "ok" : "ng", atAfter ? "response" : "silent",
                recoverOk ? "ok" : "ng");
  Serial.println("next cycle in 60s...");
  delay(60000);
}

void runCycle() {
  if (config::kWatchdogEnabled) {
    // Fed once here, not inside the connect/publish phases below: a cycle
    // that doesn't return to this point within the timeout (hung LTE attach,
    // unresponsive modem, etc.) reboots instead of stalling forever (#41).
    esp_task_wdt_reset();
  }

  const uint32_t cycleStart = millis();
  static uint32_t cycleIndex = 0;
  ++cycleIndex;

  const SyncLedger& prev = syncLedger();
  Serial.printf("board=%s boot=%lu wake=%s reset=%s prevOutcome=%s pending=%d\n",
                BOARD_NAME, static_cast<unsigned long>(bootCount),
                wakeCauseToString(esp_sleep_get_wakeup_cause()),
                resetReasonToString(esp_reset_reason()),
                cycleOutcomeToString(prev.prevOutcome),
                prev.pendingValid ? 1 : 0);

  if (!initSensor()) {
    Serial.println("ERROR: VEML6040 not found at 0x10");
    scanI2cBus();
    const uint32_t activeMs = millis() - cycleStart;
    ledgerRecordFailure(CycleOutcome::kSensorError, ParkingStatus::kUnknown,
                        bootCount, 0, 0, activeMs);
    sleepNow("sensor-error", activeMs);
    return;
  }

  RawSample sample{};
  readSensor(sample);

  const int rgDiff =
      static_cast<int>(sample.red) - static_cast<int>(sample.green);
  const PotReading potReading = currentPotThreshold();  // #60: NVS永続化済みの値(ADCには触れない)
  const ParkingStatus status = classifyStatus(sample, potReading.threshold);
  Serial.printf(
      "sample r=%u g=%u b=%u w=%u r-g=%d status=%s threshold=%d potRaw=%u\n",
      sample.red, sample.green, sample.blue, sample.white, rgDiff,
      statusToString(status), potReading.threshold, potReading.raw);

  // #47: unconditional, once per cycle, before mustPublish()/the send path
  // branches. Independent of SyncLedger/mustPublish — never triggers LTE.
  historyLogRecordCycle(status, sample, bootCount);

  if (!mustPublish(status)) {
    const uint32_t activeMs = millis() - cycleStart;
    ledgerRecordFailure(CycleOutcome::kSkipped, status, bootCount, 0, 0, activeMs);
    sleepNow("skipped", activeMs);
    return;
  }

  char payload[kPayloadSize]{};
  TransportMetrics metrics{};

  if (config::kLtePowerRelayEnabled) {
    // #46: LTE-Mへの通電はここから publish 完了/失敗後の sleepNow() までの
    // 間だけ。変化なしでmustPublish()がfalseの間は、この行に到達しないため
    // リレーに一切触れない（LTE-Mは通電されない）。
    relayLteOn();
  }

  if (!connectTransportWithRetry(metrics, cycleStart, config::kConnectPhaseMs)) {
    const uint32_t activeMs = millis() - cycleStart;
    const int16_t mqttErr = static_cast<int16_t>(activeMqttLastError());
    Serial.println("ERROR: connect phase failed");
    ledgerRecordFailure(CycleOutcome::kConnectFailed, status, bootCount, 0,
                        mqttErr, activeMs);
    sleepNow("connect-failed", activeMs);
    return;
  }

  // LTE clock is synced inside connect (ensureLteClock via NITZ/+CNTP).
  // syncClock() only does work on the Wi-Fi path; no-op on LTE-only builds.
  syncClock(config::kTimeSyncTimeoutMs);

  const bool faultInject =
      config::kFaultInjectPublishFails > 0 &&
      cycleIndex <= config::kFaultInjectPublishFails;

  PublishResult pub{};
  const bool ok = publishWithRetry(sample, status, metrics, cycleStart,
                                   faultInject, BootModeSendInfo{}, potReading,
                                   payload, sizeof(payload), pub);
  const uint32_t activeMs = millis() - cycleStart;
  const int16_t mqttErr = static_cast<int16_t>(activeMqttLastError());

  if (ok) {
    ledgerRecordConfirmed(status, bootCount, pub.attempts, mqttErr, activeMs);
    Serial.println(payload);
    Serial.printf(
        "cycle active_ms=%lu net=%lu tcpTls=%lu mqtt=%lu publish_ms=%lu "
        "confirmed=true attempts=%u\n",
        static_cast<unsigned long>(activeMs),
        static_cast<unsigned long>(metrics.networkConnectMs),
        static_cast<unsigned long>(metrics.tcpTlsConnectMs),
        static_cast<unsigned long>(metrics.mqttHandshakeMs),
        static_cast<unsigned long>(metrics.publishMs), pub.attempts);
    sleepNow("confirmed", activeMs);
    return;
  }

  const CycleOutcome outcome = (activeMs >= config::kCycleMaxActiveMs)
                                   ? CycleOutcome::kBudgetExhausted
                                   : CycleOutcome::kPublishFailed;
  ledgerRecordFailure(outcome, status, bootCount, pub.attempts, mqttErr, activeMs);
  Serial.println(payload);
  Serial.printf(
      "cycle active_ms=%lu publish_ms=%lu confirmed=false outcome=%s "
      "attempts=%u\n",
      static_cast<unsigned long>(activeMs),
      static_cast<unsigned long>(metrics.publishMs),
      cycleOutcomeToString(outcome), pub.attempts);
  sleepNow(cycleOutcomeToString(outcome), activeMs);
}

// #50: waits until (sendIndex+1)*kBootModeSlotIntervalMs has elapsed since
// bootModeStart, feeding the watchdog every chunk. Returns immediately after
// the final slot (no trailing wait) or if this slot's own processing already
// overran the next slot's target time (no backwards delay).
void waitUntilNextBootSlot(uint32_t bootModeStart, uint8_t sendIndex) {
  if (sendIndex + 1 >= config::kBootModeSendCount) {
    return;
  }

  const uint32_t targetElapsed =
      static_cast<uint32_t>(sendIndex + 1) * config::kBootModeSlotIntervalMs;
  const uint32_t elapsed = millis() - bootModeStart;
  if (elapsed >= targetElapsed) {
    return;
  }

  uint32_t remaining = targetElapsed - elapsed;
  constexpr uint32_t kChunkMs = 1000;
  while (remaining > 0) {
    const uint32_t chunk = (remaining < kChunkMs) ? remaining : kChunkMs;
    delay(chunk);
    if (config::kWatchdogEnabled) {
      esp_task_wdt_reset();
    }
    remaining -= chunk;
  }
}

// #50: runs once, only from setup(), on a cold boot (power-on reset). Sends
// unconditionally (mustPublish() is never consulted) kBootModeSendCount times
// at kBootModeSlotIntervalMs spacing, keeping the LTE/MQTT connection up
// across sends instead of the per-cycle connect/disconnect that runCycle()
// does — see docs/50-boot-mode-design.md for the full design rationale.
void runBootMode() {
  const uint32_t bootModeStart = millis();
  Serial.printf(
      "=== boot mode start (power-on) sends=%u interval=%lums ===\n",
      config::kBootModeSendCount,
      static_cast<unsigned long>(config::kBootModeSlotIntervalMs));

  if (config::kLtePowerRelayEnabled) {
    // Kept outside the loop: boot mode never disconnects between sends, so
    // this is the only SET pulse for the whole boot-mode session.
    relayLteOn();
  }

  // Declared once outside the loop (not `TransportMetrics metrics{};` per
  // slot): a slot that reuses the existing connection (Stage 2/3 below)
  // never calls connectTransport()/connectLte(), the only places that set
  // metrics.transport, so a fresh per-slot instance would stay at its
  // TransportKind::kNone default and misreport network.transport in the
  // payload even though LTE is genuinely still up.
  TransportMetrics metrics{};
  bool transportReady = false;

  for (uint8_t sendIndex = 0; sendIndex < config::kBootModeSendCount;
       ++sendIndex) {
    if (config::kWatchdogEnabled) {
      esp_task_wdt_reset();
    }
    const uint32_t slotStart = millis();

    if (!initSensor()) {
      Serial.println("boot-mode: ERROR VEML6040 not found at 0x10");
      scanI2cBus();
      const uint32_t activeMs = millis() - slotStart;
      ledgerRecordFailure(CycleOutcome::kSensorError, ParkingStatus::kUnknown,
                          bootCount, 0, 0, activeMs);
      waitUntilNextBootSlot(bootModeStart, sendIndex);
      continue;
    }

    RawSample sample{};
    readSensor(sample);
    const PotReading potReading = readPotentiometerThresholdLive();  // #60: スロットごとに生読み+NVS永続化
    const ParkingStatus status = classifyStatus(sample, potReading.threshold);
    Serial.printf(
        "boot-mode slot=%u/%u sample r=%u g=%u b=%u w=%u status=%s "
        "threshold=%d potRaw=%u\n",
        sendIndex + 1, config::kBootModeSendCount, sample.red, sample.green,
        sample.blue, sample.white, statusToString(status),
        potReading.threshold, potReading.raw);

    // #47: unconditional, once per slot, same contract as runCycle().
    historyLogRecordCycle(status, sample, bootCount);

    // Three-stage connection reuse (docs/50-boot-mode-design.md §2.3):
    // Stage 1 (first slot) does a full connect; later slots first check
    // whether MQTT is still connected (Stage 2), and only fall back to a
    // lightweight MQTT-only reconnect (Stage 3) or, failing that, a full
    // reconnect, keeping the LTE bearer up as long as possible (req. 3).
    if (sendIndex == 0) {
      transportReady =
          connectTransportWithRetry(metrics, slotStart, config::kConnectPhaseMs);
    } else if (activeMqttState() == 0) {
      transportReady = true;
      metrics.transport = activeTransportKind();
    } else {
      transportReady = reconnectActiveTransport(metrics);
      if (transportReady) {
        metrics.transport = activeTransportKind();
      } else {
        // req. 4: same retry policy as normal operation.
        transportReady = connectTransportWithRetry(metrics, slotStart,
                                                    config::kConnectPhaseMs);
      }
    }

    if (!transportReady) {
      const uint32_t activeMs = millis() - slotStart;
      const int16_t mqttErr = static_cast<int16_t>(activeMqttLastError());
      Serial.println("boot-mode: ERROR connect phase failed");
      ledgerRecordFailure(CycleOutcome::kConnectFailed, status, bootCount, 0,
                          mqttErr, activeMs);
      waitUntilNextBootSlot(bootModeStart, sendIndex);
      continue;
    }

    syncClock(config::kTimeSyncTimeoutMs);

    const BootModeSendInfo bootInfo{
        /*active=*/true, /*slot=*/static_cast<uint8_t>(sendIndex + 1),
        /*totalSlots=*/config::kBootModeSendCount};

    char payload[kPayloadSize]{};
    PublishResult pub{};
    const bool ok = publishWithRetry(sample, status, metrics, slotStart,
                                     /*faultInject=*/false, bootInfo, potReading,
                                     payload, sizeof(payload), pub);
    // activeMs is slot-scoped (millis() - slotStart), matching runCycle()'s
    // own per-cycle semantics — not bootModeStart-relative, which would
    // make prevActiveMs balloon to several minutes by the last slot and
    // make the kBudgetExhausted-vs-kPublishFailed split below spuriously
    // always pick kBudgetExhausted from slot 2 onward.
    const uint32_t activeMs = millis() - slotStart;
    const int16_t mqttErr = static_cast<int16_t>(activeMqttLastError());

    if (ok) {
      ledgerRecordConfirmed(status, bootCount, pub.attempts, mqttErr, activeMs);
      Serial.println(payload);
      Serial.printf("boot-mode: send %u/%u confirmed\n", sendIndex + 1,
                    config::kBootModeSendCount);
    } else {
      const CycleOutcome outcome = (activeMs >= config::kCycleMaxActiveMs)
                                       ? CycleOutcome::kBudgetExhausted
                                       : CycleOutcome::kPublishFailed;
      ledgerRecordFailure(outcome, status, bootCount, pub.attempts, mqttErr,
                          activeMs);
      Serial.println(payload);
      Serial.printf("boot-mode: send %u/%u FAILED outcome=%s\n", sendIndex + 1,
                    config::kBootModeSendCount, cycleOutcomeToString(outcome));
    }

    waitUntilNextBootSlot(bootModeStart, sendIndex);
  }

  Serial.println("=== boot mode complete, resuming normal cadence ===");
  // sleepNow() unconditionally calls disconnectTransport()/relayLteOff(), so
  // boot mode does not need to disconnect separately here.
  sleepNow("boot-mode-done", millis() - bootModeStart);
}

}  // namespace

void setup() {
  // #46: 他のどの処理よりも前に呼ぶ。ウォッチドッグリセット等でSET後・RESET前に
  // 再起動しても、ここで確実にLTE-Mを一度OFFへ倒す（フェイルセーフ）。
  initRelay();
  // #60: initRelay()のような安全上の緊急性はなく、単にハードウェア初期化群として
  // まとめて記述する便宜上ここに置いている(Serial.begin()の前後どちらでも動作に
  // 差はない。docs/60-potentiometer-threshold-design.md §4.2参照)。
  initPotentiometer();

  Serial.begin(115200);
  waitForSerial();

  if (config::kLtePowerRelayEnabled) {
    // initRelay()（RESETパルス送信）は Serial.begin() より前に実行済み。
    // 実際に送信されたのは t=0ms 付近（このprintより前）。
    Serial.printf(
        "relay: startup safety RESET already sent before Serial.begin() "
        "(t=~0 ms); waitForSerial took %lu ms\n",
        static_cast<unsigned long>(millis()));
  }

  if (config::kWatchdogEnabled) {
    esp_task_wdt_init(config::kWatchdogTimeoutMs / 1000, true);
    esp_task_wdt_add(nullptr);
    Serial.printf("watchdog enabled timeout_s=%lu\n",
                  static_cast<unsigned long>(config::kWatchdogTimeoutMs / 1000));
  }

  initDeviceIdentity();
  initSyncLedger();
  initHistoryLog();
  Serial.printf("deviceId=%s mqttTopic=%s pending=%d\n", getDeviceId(),
                getMqttTopic(), syncLedger().pendingValid ? 1 : 0);
  bootCount++;

  const esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  if (cause == ESP_SLEEP_WAKEUP_TIMER) {
    consecutiveTimerWakes++;
  } else {
    consecutiveTimerWakes = 0;
    lastSleepEntryUs = 0;
    resetLteRadioCache();
  }
  // #47: dump on a non-timer wake (power-on / USB reset) — the moment
  // someone is plugged in via USB during normal (timer-wake) deep-sleep
  // operation — or on the explicit 'h' serial command from waitForSerial().
  if (cause != ESP_SLEEP_WAKEUP_TIMER || forceHistoryDump) {
    historyLogDumpToSerial();
    forceHistoryDump = false;
  }
  computeWakeDiagnostics();
  if (wakeDiag.hasPrevSleep) {
    Serial.printf("wake interval measured=%lldms expected=%lldms oversleep=%lldms\n",
                  (long long)wakeDiag.measuredIntervalMs,
                  (long long)wakeDiag.expectedIntervalMs,
                  (long long)wakeDiag.oversleepMs);
  }

#if !PSS_LTE_POWEROFF_TEST_MODE && !PSS_LTE_TEST_MODE
  // #50: fires at most once per physical reset — setup() itself is only
  // ever called once per reset by the Arduino/ESP32 framework (loop() is
  // what repeats, including in the PSS_DISABLE_DEEP_SLEEP debug build where
  // sleepNow() never actually resets the chip), so no extra one-shot latch
  // is needed here. Deep-sleep timer wakes report ESP_RST_DEEPSLEEP, not
  // ESP_RST_POWERON, so normal operation never re-enters this branch.
  if (config::kBootModeEnabled && esp_reset_reason() == ESP_RST_POWERON) {
    runBootMode();
  }
#endif
}

void loop() {
#if PSS_LTE_POWEROFF_TEST_MODE
  runLtePoweroffTest();
#elif PSS_LTE_TEST_MODE
  runLteTest();
#else
  runCycle();
#endif
}
