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
#include "outbox.h"
#include "sensor.h"
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
  Serial.printf("sleep reason=%s seconds=%lu active_ms=%lu outbox=%u\n", reason,
                static_cast<unsigned long>(config::kSleepSeconds),
                static_cast<unsigned long>(activeMs), outboxCount());
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
                  bool deliveryConfirmed, uint8_t publishAttempts,
                  uint8_t outboxPending, char* out, size_t outSize) {
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
  network["deliveryConfirmed"] = deliveryConfirmed;
  network["publishAttempts"] = publishAttempts;
  network["outboxPending"] = outboxPending;

  serializeJson(doc, out, outSize);
}

bool publishCurrentWithRetry(const RawSample& sample, ParkingStatus status,
                             TransportMetrics& metrics, uint32_t cycleStart,
                             uint8_t outboxPending, char* payload,
                             size_t payloadSize, PublishResult& result) {
  result = PublishResult{};

  for (uint8_t attempt = 1; attempt <= config::kPublishMaxAttempts; ++attempt) {
    if ((millis() - cycleStart) >= config::kCycleMaxActiveMs) {
      Serial.println("publish retry budget exhausted (active time)");
      break;
    }

    if (attempt > 1) {
      delay(config::kRetryDelayMs);
      if (!reconnectActiveTransport(metrics)) {
        disconnectTransport();
        if (!connectTransport(metrics)) {
          continue;
        }
      }
    }

    result.attempts = attempt;
    Serial.printf("publish attempt %u/%u\n", attempt, config::kPublishMaxAttempts);

    // Build immediately before publish so broker JSON matches PUBACK result.
    buildPayload(sample, status, metrics, millis() - cycleStart, true, attempt,
                 outboxPending, payload, payloadSize);

    if (publishTelemetryConfirmed(payload, metrics)) {
      buildPayload(sample, status, metrics, millis() - cycleStart, true, attempt,
                   outboxPending, payload, payloadSize);
      result.confirmed = true;
      return true;
    }

    disconnectTransport();
    if (!connectTransport(metrics)) {
      continue;
    }
  }

  return false;
}

bool flushOutbox(TransportMetrics& metrics, uint32_t cycleStart) {
  char pending[kPayloadSize];
  char patched[kPayloadSize];

  while (outboxCount() > 0) {
    if ((millis() - cycleStart) >= config::kCycleMaxActiveMs) {
      Serial.println("outbox flush budget exhausted");
      return false;
    }

    if (!outboxPeek(pending, sizeof(pending))) {
      Serial.println("outbox peek failed");
      return false;
    }

    Serial.printf("outbox flush (%u pending)\n", outboxCount());
    PublishResult result{};

    for (uint8_t attempt = 1; attempt <= config::kPublishMaxAttempts; ++attempt) {
      if ((millis() - cycleStart) >= config::kCycleMaxActiveMs) {
        break;
      }

      if (attempt > 1) {
        delay(config::kRetryDelayMs);
        if (!reconnectActiveTransport(metrics)) {
          disconnectTransport();
          if (!connectTransport(metrics)) {
            continue;
          }
        }
      }

      JsonDocument doc;
      if (deserializeJson(doc, pending) != DeserializationError::Ok) {
        Serial.println("outbox: invalid JSON, dropping");
        outboxDequeue();
        break;
      }

      // Preserve the enqueue-time network metadata (transport, connect timings)
      // instead of replacing the object, so outbox replays stay diagnosable.
      JsonObject network = doc["network"].is<JsonObject>()
                               ? doc["network"].as<JsonObject>()
                               : doc["network"].to<JsonObject>();
      network["deliveryConfirmed"] = true;
      network["publishAttempts"] = attempt;
      network["mqttQos"] = config::kMqttQos;

      if (serializeJson(doc, patched, sizeof(patched)) == 0) {
        Serial.println("outbox: serialize failed");
        return false;
      }

      result.attempts = attempt;
      if (publishTelemetryConfirmed(patched, metrics)) {
        result.confirmed = true;
        outboxDequeue();
        Serial.println(patched);
        break;
      }

      disconnectTransport();
      if (!connectTransport(metrics)) {
        continue;
      }
    }

    if (!result.confirmed) {
      Serial.println("outbox flush failed, keeping oldest entry");
      return false;
    }
  }

  return true;
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
  const uint8_t outboxAtStart = outboxCount();

  Serial.printf("board=%s boot=%lu wake=%s reset=%s outbox=%u\n", BOARD_NAME,
                static_cast<unsigned long>(bootCount),
                wakeCauseToString(esp_sleep_get_wakeup_cause()),
                resetReasonToString(esp_reset_reason()), outboxAtStart);

  if (!initSensor()) {
    Serial.println("ERROR: VEML6040 not found at 0x10");
    scanI2cBus();
    sleepNow("sensor-error", millis() - cycleStart);
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

  char payload[kPayloadSize]{};
  TransportMetrics transportMetrics{};
  buildPayload(sample, status, transportMetrics, millis() - cycleStart, false,
               0, outboxAtStart, payload, sizeof(payload));

  if (!connectTransportWithRetry(transportMetrics, cycleStart)) {
    Serial.println("ERROR: no transport available, saving to outbox");
    outboxEnqueue(payload);
    sleepNow("transport-error-outbox", millis() - cycleStart);
    return;
  }

  syncClock(config::kTimeSyncTimeoutMs);

  if (!flushOutbox(transportMetrics, cycleStart)) {
    Serial.println("outbox not fully flushed");
  }

  PublishResult publishResult{};
  if (publishCurrentWithRetry(sample, status, transportMetrics, cycleStart,
                              outboxCount(), payload, sizeof(payload),
                              publishResult)) {
    Serial.println(payload);
    Serial.printf(
        "cycle active_ms=%lu net=%lu tcpTls=%lu mqtt=%lu publish_ms=%lu "
        "confirmed=true attempts=%u outbox=%u\n",
        static_cast<unsigned long>(millis() - cycleStart),
        static_cast<unsigned long>(transportMetrics.networkConnectMs),
        static_cast<unsigned long>(transportMetrics.tcpTlsConnectMs),
        static_cast<unsigned long>(transportMetrics.mqttHandshakeMs),
        static_cast<unsigned long>(transportMetrics.publishMs),
        publishResult.attempts, outboxCount());
    sleepNow("confirmed", millis() - cycleStart);
    return;
  }

  buildPayload(sample, status, transportMetrics, millis() - cycleStart, false,
               publishResult.attempts, outboxCount(), payload, sizeof(payload));
  outboxEnqueue(payload);
  Serial.println(payload);
  Serial.printf(
      "cycle active_ms=%lu publish_ms=%lu confirmed=false attempts=%u "
      "outbox=%u\n",
      static_cast<unsigned long>(millis() - cycleStart),
      static_cast<unsigned long>(transportMetrics.publishMs),
      publishResult.attempts, outboxCount());
  sleepNow("outbox-saved", millis() - cycleStart);
}

}  // namespace

void setup() {
  Serial.begin(115200);
  waitForSerial();
  initDeviceIdentity();
  initOutbox();
  Serial.printf("deviceId=%s mqttTopic=%s outbox=%u\n", getDeviceId(),
                getMqttTopic(), outboxCount());
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
