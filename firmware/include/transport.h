#pragma once

#include <stdint.h>

enum class TransportKind {
  kNone,
  kWifi,
  kLte,
};

struct TransportMetrics {
  TransportKind transport = TransportKind::kNone;
  bool usedFallback = false;
  int32_t wifiRssi = 0;
  uint32_t networkConnectMs = 0;
  uint32_t mqttConnectMs = 0;
  uint32_t publishMs = 0;
  uint8_t transportAttempts = 0;
};

struct PublishResult {
  bool confirmed = false;
  uint8_t attempts = 0;
};

struct LteProbeResult {
  bool uartOk = false;
  bool initOk = false;
  bool networkOk = false;
  bool gprsOk = false;
  int signalQuality = 99;
  char modemInfo[64]{};
  char imei[20]{};
  char operatorName[32]{};
  uint32_t elapsedMs = 0;
};

bool connectTransport(TransportMetrics& metrics);
bool connectTransportWithRetry(TransportMetrics& metrics, uint32_t cycleStartMs);
bool reconnectActiveTransport(TransportMetrics& metrics);
bool probeLteModem(LteProbeResult& result);
void printLteProbeResult(const LteProbeResult& result);
bool syncClock(uint32_t timeoutMs);
bool publishTelemetryConfirmed(const char* payload, TransportMetrics& metrics);
int activeMqttState();
void disconnectTransport();
const char* transportName(TransportKind transport);
