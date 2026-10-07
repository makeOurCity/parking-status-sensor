#pragma once

#include <stddef.h>
#include <stdint.h>

enum class TransportKind {
  kNone,
  kWifi,
  kLte,
  kLoRaWan,  // #40: Grove Wio-E5
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
  // #87: LTE-M モジュールが AT に一度も応答しなかった（電源が来ていない疑い）。
  // 接続の失敗後に true になる。connectTransportWithRetry() はこのとき再試行しない。
  bool modemSilent = false;
  // #40: LoRaWAN のみ。ACK を受けた RX ウィンドウの RSSI / SNR（hasLoRaRx のとき有効）。
  bool loraAlreadyJoined = false;
  bool hasLoRaRx = false;
  int16_t loraRssi = 0;
  float loraSnr = 0.0f;
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

// #87: 接続の制限時間（hard deadline）。絶対 millis で、0（kNoLimit）は無期限。
// 実行中の AT 待ち・delay・waitForNetwork を、残り時間で縮める。
// 差は int32_t で比較するので、millis() の桁あふれ（約49.7日）に対して安全。
constexpr uint32_t kNoLimit = 0;
inline uint32_t deadlineAfter(uint32_t startMs, uint32_t budgetMs) {
  const uint32_t e = startMs + budgetMs;
  return e == kNoLimit ? 1u : e;  // 0 は無期限と衝突するので 1 に置き換える（1ms のずれは許容）
}
inline uint32_t remainingMsAt(uint32_t endMs, uint32_t nowMs) {
  if (endMs == kNoLimit) {
    return UINT32_MAX;
  }
  const int32_t d = static_cast<int32_t>(endMs - nowMs);
  return d > 0 ? static_cast<uint32_t>(d) : 0;
}

bool connectTransport(TransportMetrics& metrics, uint32_t hardEndMs);
bool connectTransportWithRetry(TransportMetrics& metrics, uint32_t cycleStartMs,
                               uint32_t budgetMs);
bool reconnectActiveTransport(TransportMetrics& metrics, uint32_t hardEndMs);
bool probeLteModem(LteProbeResult& result);
void printLteProbeResult(const LteProbeResult& result);
bool syncClock(uint32_t timeoutMs);
bool publishTelemetryConfirmed(const char* payload, TransportMetrics& metrics);
// #40: LoRaWAN の confirmed アップリンク（バイナリ、fPort はプロビジョニング時に設定）。
// ACK 受信で true。
bool publishUplinkConfirmed(const uint8_t* data, size_t len, TransportMetrics& metrics);
int activeMqttState();
int activeMqttLastError();
TransportKind activeTransportKind();
void disconnectTransport();
// modem poweroff（AT+CPOWD=1）+ UART 後処理 + 無応答確認。bearer の明示的な切断は行わない（#76）。
struct LtePoweroffResult {
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
// #40: 次の LoRaWAN 接続の前に Wio-E5 のプロビジョニングをやり直させる
// （Deep Sleep のタイマー以外で起動したとき）。
void resetLoRaWanCache();
