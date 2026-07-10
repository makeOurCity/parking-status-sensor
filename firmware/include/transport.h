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
  uint32_t tcpTlsConnectMs = 0;
  uint32_t mqttHandshakeMs = 0;
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
bool connectTransportWithRetry(TransportMetrics& metrics, uint32_t cycleStartMs,
                               uint32_t budgetMs);
bool reconnectActiveTransport(TransportMetrics& metrics);
bool probeLteModem(LteProbeResult& result);
void printLteProbeResult(const LteProbeResult& result);
bool syncClock(uint32_t timeoutMs);
bool publishTelemetryConfirmed(const char* payload, TransportMetrics& metrics);
int activeMqttState();
int activeMqttLastError();
void disconnectTransport();
// LTE bearer 切断 + modem poweroff（AT+CPOWD=1）+ UART 後処理 + 無応答確認。
struct LtePoweroffResult {
  bool bearerDetached = false;
  bool cpowdAccepted = false;
  bool modemSilent = false;
  bool radioOffFallback = false;
  uint32_t elapsedMs = 0;
};
bool powerOffLteModem(LtePoweroffResult* detail = nullptr);
// RF 停止のみ（AT+CFUN=0）。完全 poweroff 未成立時のフォールバック検証用。
bool radioOffLteModem();
bool probeLteModemAt(uint32_t timeoutMs = 2000);
const char* transportName(TransportKind transport);
void resetLteRadioCache();
