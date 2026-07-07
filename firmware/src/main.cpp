#include <Arduino.h>
#include <ArduinoJson.h>
#include <esp_sleep.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <string.h>
#include <time.h>

#include "board.h"
#include "classify.h"
#include "config.h"
#include "device_id.h"
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

void buildPayload(const RawSample& sample, ParkingStatus status,
                  const TransportMetrics& transportMetrics, uint32_t activeMs,
                  uint8_t publishAttempts, char* out, size_t outSize) {
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

  doc["threshold"] = config::kStatusThreshold;
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

  serializeJson(doc, out, outSize);
}

// PoC keeps full transmission (always publish). The change-only path (#25) is
// present as a skeleton but disabled unless PSS_CHANGE_ONLY_SEND is defined.
bool mustPublish(ParkingStatus status) {
#if defined(PSS_CHANGE_ONLY_SEND) && PSS_CHANGE_ONLY_SEND
  const SyncLedger& ledger = syncLedger();
  if (ledger.pendingValid) {
    return true;  // retry the undelivered observation this cycle
  }
  return status != ledger.lastConfirmedStatus;  // heartbeat added in #25
#else
  (void)status;
  return true;  // PoC: full transmission every cycle
#endif
}

// Publish the current observation with bounded retries inside the publish-phase
// budget. Between attempts only the MQTT layer is reconnected (LTE bearer kept,
// modem never powered off here — that happens only at sleep). Returns true on
// PUBACK.
bool publishWithRetry(const RawSample& sample, ParkingStatus status,
                      TransportMetrics& metrics, uint32_t cycleStart,
                      bool faultInject, char* payload, size_t payloadSize,
                      PublishResult& result) {
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
    buildPayload(sample, status, metrics, millis() - cycleStart, attempt, payload,
                 payloadSize);

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

void runCycle() {
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
  const ParkingStatus status = classifyStatus(sample, config::kStatusThreshold);
  Serial.printf("sample r=%u g=%u b=%u w=%u r-g=%d status=%s\n", sample.red,
                sample.green, sample.blue, sample.white, rgDiff,
                statusToString(status));

  if (!mustPublish(status)) {
    const uint32_t activeMs = millis() - cycleStart;
    ledgerRecordFailure(CycleOutcome::kSkipped, status, bootCount, 0, 0, activeMs);
    sleepNow("skipped", activeMs);
    return;
  }

  char payload[kPayloadSize]{};
  TransportMetrics metrics{};

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
                                   faultInject, payload, sizeof(payload), pub);
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

}  // namespace

void setup() {
  Serial.begin(115200);
  waitForSerial();
  initDeviceIdentity();
  initSyncLedger();
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
  computeWakeDiagnostics();
  if (wakeDiag.hasPrevSleep) {
    Serial.printf("wake interval measured=%lldms expected=%lldms oversleep=%lldms\n",
                  (long long)wakeDiag.measuredIntervalMs,
                  (long long)wakeDiag.expectedIntervalMs,
                  (long long)wakeDiag.oversleepMs);
  }
}

void loop() {
#if PSS_LTE_TEST_MODE
  runLteTest();
#else
  runCycle();
#endif
}
