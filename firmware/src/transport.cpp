#include "transport.h"

#define TINY_GSM_MODEM_SIM7080

#include <Arduino.h>
#include <MQTT.h>
#include <TinyGsmClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#if PSS_MQTT_USE_TLS && !PSS_LTE_MODEM_TLS
#include <SSLClient.h>
#endif
#if PSS_LTE_MODEM_TLS
#include "lte_modem_tls.h"
#endif
#include <esp_system.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#include "board.h"
#include "config.h"
#include "device_id.h"

RTC_DATA_ATTR static bool ltePlanDReady = false;

namespace {

WiFiClient wifiClient;
WiFiClientSecure wifiSecureClient;
MQTTClient wifiMqtt(1024);

TinyGsm modem(Serial1);
TinyGsmClient lteClient(modem);
#if PSS_LTE_MODEM_TLS
AwsLteSecureClient lteSecureClient(modem);
#elif PSS_MQTT_USE_TLS
SSLClient lteSecureClient(&lteClient);
#endif
MQTTClient lteMqtt(1024);

MQTTClient* activeMqtt = nullptr;
TransportKind activeTransport = TransportKind::kNone;

#if PSS_MQTT_USE_TLS
extern const char awsRootCa[] asm("_binary_certs_AmazonRootCA1_pem_start");
extern const char deviceCert[] asm("_binary_certs_device_pem_crt_start");
extern const char privateKey[] asm("_binary_certs_private_pem_key_start");
#endif

bool hasText(const char* value) {
  return value != nullptr && value[0] != '\0';
}

bool ensureLteClock();

Client& wifiNetworkClient() {
#if PSS_MQTT_USE_TLS
  return wifiSecureClient;
#else
  return wifiClient;
#endif
}

Client& lteNetworkClient() {
#if PSS_LTE_MODEM_TLS || PSS_MQTT_USE_TLS
  return lteSecureClient;
#else
  return lteClient;
#endif
}

void resetMqttSession(MQTTClient& mqtt, Client& net) {
  mqtt.disconnect();
  net.stop();
}

void resetWifiMqttLink() {
  resetMqttSession(wifiMqtt, wifiNetworkClient());
}

void resetLteMqttLink() {
  resetMqttSession(lteMqtt, lteNetworkClient());
}

void configureWifiTlsClient() {
#if PSS_MQTT_USE_TLS
  resetWifiMqttLink();
  wifiSecureClient.setCACert(awsRootCa);
  wifiSecureClient.setCertificate(deviceCert);
  wifiSecureClient.setPrivateKey(privateKey);
  wifiSecureClient.setHandshakeTimeout(30);
  wifiSecureClient.setTimeout(config::kMqttConnectTimeoutMs / 1000);
#endif
}

#if PSS_LTE_MODEM_TLS
void configureLteTlsClient() {
  resetLteMqttLink();
  lteSecureClient.setCaCert(lteModemCaCertName());
  lteSecureClient.setMtlsClientCert(lteModemClientCertName());
  lteSecureClient.setCertificate(lteModemCaCertName());
}

bool ensureLteModemCertificates() {
  if (!ensureLteClock()) {
    Serial.println("WARN: modem clock unavailable before TLS cert upload");
  }
  if (provisionLteModemCertificates(modem)) {
    return true;
  }
  clearLteModemCertificateCache();
  return false;
}
#elif PSS_MQTT_USE_TLS
void configureLteTlsClient() {
  resetLteMqttLink();
  lteSecureClient.setCACert(awsRootCa);
  lteSecureClient.setCertificate(deviceCert);
  lteSecureClient.setPrivateKey(privateKey);
  lteSecureClient.setTimeout(config::kMqttConnectTimeoutMs);
  lteSecureClient.setHandshakeTimeout(60);
}
#endif

String mqttClientId() {
  // AWS IoT policy allows iot:Connect only for client/${iot:Connection.Thing.ThingName}.
  if (config::kMqttUseTls) {
    return String(getDeviceId());
  }
  return String(getDeviceId()) + "-" +
         String(static_cast<uint32_t>(esp_random()), HEX);
}

void logModemAt(const char* cmd) {
  Serial.printf("AT%s\n", cmd);
  modem.sendAT(cmd);
  String response;
  modem.waitResponse(5000L, response);
  if (response.length() > 0) {
    Serial.println(response);
  }
}

void logLteDiagnostics() {
  Serial.println("--- LTE diagnostics ---");
  logModemAt("+CPIN?");
  logModemAt("+CEREG?");
  logModemAt("+CREG?");
  logModemAt("+CMNB?");
  logModemAt("+CBANDCFG?");
  logModemAt("+CPSI?");
}

bool prepareLteForPlanD() {
  Serial.println("configure plan-D (Docomo Cat-M1)...");

  modem.sendAT("+CFUN=0");
  modem.waitResponse(10000L);

  modem.sendAT("+CBANDCFG=\"CAT-M\",1,19");
  if (modem.waitResponse(10000L) != 1) {
    Serial.println("WARN: CBANDCFG 1,19 failed");
  }
  logModemAt("+CBANDCFG?");

  modem.sendAT(String("+CGDCONT=1,\"IP\",\"") + config::kLteApn + "\"");
  modem.waitResponse(10000L);
  modem.sendAT(String("+CNCFG=0,1,\"") + config::kLteApn + "\"");
  modem.waitResponse(10000L);

  modem.sendAT("+CMNB=1");
  if (modem.waitResponse(10000L) != 1) {
    Serial.println("WARN: CMNB=1 failed, trying CMNB=3");
    modem.sendAT("+CMNB=3");
    modem.waitResponse(10000L);
  }
  modem.sendAT("+CNMP=38");
  modem.waitResponse(10000L);
  modem.sendAT("+CEREG=1");
  modem.waitResponse();
  modem.sendAT("+COPS=0");
  modem.waitResponse(10000L);

  modem.sendAT("+CFUN=1");
  modem.waitResponse(15000L);
  delay(3000);

  logModemAt("+CMNB?");
  return true;
}

bool beginLteUartAndModem() {
  Serial1.begin(LTE_UART_BAUD, SERIAL_8N1, LTE_UART_RX, LTE_UART_TX);
  delay(1000);
  if (!modem.init()) {
    ltePlanDReady = false;
    return false;
  }
  if (!ltePlanDReady) {
    Serial.println("LTE plan-D setup (first boot this power cycle)");
    if (!prepareLteForPlanD()) {
      return false;
    }
    ltePlanDReady = true;
  }
  return true;
}

bool connectMqtt(MQTTClient& mqtt, Client& net, TransportMetrics& metrics) {
  mqtt.begin(config::kMqttHost, config::kMqttPort, net);
  mqtt.setOptions(60, true, 10000);

  const String clientId = mqttClientId();
  metrics.tcpTlsConnectMs = 0;
  metrics.mqttHandshakeMs = 0;

  const uint32_t tlsStart = millis();
  bool tcpOk = false;
  while ((millis() - tlsStart) < config::kMqttConnectTimeoutMs) {
    if (net.connect(config::kMqttHost, config::kMqttPort) > 0) {
      tcpOk = true;
      break;
    }
    delay(500);
  }
  metrics.tcpTlsConnectMs = millis() - tlsStart;
  if (!tcpOk) {
    metrics.mqttConnectMs = metrics.tcpTlsConnectMs;
    Serial.printf("MQTT TCP/TLS connect failed after %lu ms\n",
                  static_cast<unsigned long>(metrics.tcpTlsConnectMs));
    return false;
  }

  const uint32_t mqttStart = millis();
  constexpr uint32_t kMqttHandshakeBudgetMs = 15000;
  while ((millis() - mqttStart) < kMqttHandshakeBudgetMs) {
    const uint32_t attemptStart = millis();
    const bool connected =
        hasText(config::kMqttUsername)
            ? mqtt.connect(clientId.c_str(), config::kMqttUsername,
                           config::kMqttPassword, true)
            : mqtt.connect(clientId.c_str(), nullptr, nullptr, true);
    const uint32_t attemptMs = millis() - attemptStart;
    if (connected) {
      metrics.mqttHandshakeMs = millis() - mqttStart;
      metrics.mqttConnectMs = metrics.tcpTlsConnectMs + metrics.mqttHandshakeMs;
      Serial.printf(
          "MQTT connected (tcpTls=%lu mqtt=%lu total=%lu ms)\n",
          static_cast<unsigned long>(metrics.tcpTlsConnectMs),
          static_cast<unsigned long>(metrics.mqttHandshakeMs),
          static_cast<unsigned long>(metrics.mqttConnectMs));
      return true;
    }
    metrics.mqttHandshakeMs = attemptMs;
    delay(500);
  }

  metrics.mqttHandshakeMs = millis() - mqttStart;
  metrics.mqttConnectMs = metrics.tcpTlsConnectMs + metrics.mqttHandshakeMs;
  Serial.printf(
      "MQTT connect failed host=%s port=%u tls=%s clientId=%s tcpTls=%lu "
      "mqtt=%lu err=%d\n",
      config::kMqttHost, config::kMqttPort, config::kMqttUseTls ? "yes" : "no",
      clientId.c_str(), static_cast<unsigned long>(metrics.tcpTlsConnectMs),
      static_cast<unsigned long>(metrics.mqttHandshakeMs), mqtt.lastError());
  resetMqttSession(mqtt, net);
  return false;
}

bool connectWifi(TransportMetrics& metrics) {
  if (!hasText(config::kWifiSsid)) {
    return false;
  }

  Serial.printf("Wi-Fi connecting ssid=%s\n", config::kWifiSsid);
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(config::kWifiSsid, config::kWifiPassword);

  const uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED &&
         (millis() - start) < config::kWifiConnectTimeoutMs) {
    delay(250);
    Serial.print(".");
  }
  Serial.println();

  metrics.networkConnectMs = millis() - start;
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("Wi-Fi connect failed");
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
    return false;
  }

  metrics.transport = TransportKind::kWifi;
  metrics.wifiRssi = WiFi.RSSI();
  Serial.printf("Wi-Fi connected ip=%s rssi=%ld mqtt_tls=%s\n",
                WiFi.localIP().toString().c_str(),
                static_cast<long>(metrics.wifiRssi),
                config::kMqttUseTls ? "yes" : "no");

  if (config::kMqttUseTls) {
    syncClock(config::kTimeSyncTimeoutMs);
  }

  configureWifiTlsClient();
  if (!connectMqtt(wifiMqtt, wifiNetworkClient(), metrics)) {
    resetWifiMqttLink();
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
    return false;
  }

  activeMqtt = &wifiMqtt;
  activeTransport = TransportKind::kWifi;
  return true;
}

// Convert a UTC calendar date to Unix epoch without relying on TZ/mktime
// (Howard Hinnant's days_from_civil algorithm).
time_t epochFromUtc(int y, int mo, int d, int h, int mi, int s) {
  y -= mo <= 2;
  const long era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(y - era * 400);
  const unsigned doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  const long days = era * 146097 + static_cast<long>(doe) - 719468;
  return static_cast<time_t>(days) * 86400 + static_cast<time_t>(h) * 3600 +
         mi * 60 + s;
}

// Read the modem's network-provided clock (AT+CCLK, populated via NITZ) and set
// the ESP32 system time. Unlike lwIP SNTP (configTime), this works over LTE
// because it never leaves the modem's AT interface.
bool setSystemClockFromModem() {
  int y = 0, mo = 0, d = 0, h = 0, mi = 0, s = 0;
  float tzHours = 0;
  if (!modem.getNetworkTime(&y, &mo, &d, &h, &mi, &s, &tzHours)) {
    return false;
  }
  // Reject modem power-on defaults (e.g. 1980/2004/2080) so we don't set a
  // bogus clock when NITZ has not been delivered yet.
  if (y < 2024 || y > 2035) {
    Serial.printf("modem clock not from network yet (year=%d)\n", y);
    return false;
  }

  const time_t utc =
      epochFromUtc(y, mo, d, h, mi, s) - static_cast<time_t>(tzHours * 3600.0f);
  if (utc < 1700000000) {
    return false;
  }

  timeval tv{};
  tv.tv_sec = utc;
  settimeofday(&tv, nullptr);
  Serial.printf("clock set from modem utc=%ld tz=%.2f\n",
                static_cast<long>(utc), tzHours);
  return true;
}

// Ensure the system clock is valid on the LTE path. Prefers the (free) NITZ
// clock; falls back to the modem's own NTP (+CNTP) over the data bearer.
bool ensureLteClock() {
  if (time(nullptr) > 1700000000) {
    return true;
  }
  if (setSystemClockFromModem()) {
    return true;
  }
  Serial.println("NITZ unavailable; trying modem NTP (+CNTP)");
  modem.NTPServerSync(String(config::kNtpServer), 0);
  return setSystemClockFromModem();
}

bool connectLte(TransportMetrics& metrics) {
  if (!config::kLteEnabled) {
    return false;
  }

  if (config::kLteOnly) {
    WiFi.mode(WIFI_OFF);
  }

  Serial.println("LTE-M connecting");
  const uint32_t start = millis();

  if (!beginLteUartAndModem()) {
    Serial.println("LTE modem init failed");
    return false;
  }

  if (!modem.waitForNetwork(config::kLteNetworkTimeoutMs)) {
    Serial.println("LTE network failed");
    logLteDiagnostics();
    return false;
  }

  if (!modem.gprsConnect(config::kLteApn, config::kLteUser,
                         config::kLtePassword)) {
    Serial.println("LTE data attach failed");
    return false;
  }

  metrics.transport = TransportKind::kLte;
  metrics.networkConnectMs = millis() - start;
  Serial.printf("LTE-M connected operator=%s csq=%d\n",
                modem.getOperator().c_str(), modem.getSignalQuality());

  if (config::kMqttUseTls) {
#if PSS_LTE_MODEM_TLS
    if (!ensureLteModemCertificates()) {
      Serial.println("LTE modem TLS cert setup failed");
      return false;
    }
#else
    if (!ensureLteClock()) {
      Serial.println("WARN: modem clock unavailable before TLS; continuing");
    }
#endif
    configureLteTlsClient();
  }

  if (!connectMqtt(lteMqtt, lteNetworkClient(), metrics)) {
    resetLteMqttLink();
    modem.gprsDisconnect();
    modem.poweroff();
    return false;
  }

  activeMqtt = &lteMqtt;
  activeTransport = TransportKind::kLte;
  return true;
}

bool reconnectTransport(TransportMetrics& metrics) {
  if (activeTransport == TransportKind::kWifi &&
      WiFi.status() == WL_CONNECTED && activeMqtt == &wifiMqtt) {
    if (activeMqtt->connected()) {
      return true;
    }
    Serial.println("MQTT reconnect (Wi-Fi still up)");
    configureWifiTlsClient();
    return connectMqtt(wifiMqtt, wifiNetworkClient(), metrics);
  }

  if (activeTransport == TransportKind::kLte && activeMqtt == &lteMqtt) {
    if (activeMqtt->connected()) {
      return true;
    }
    if (!modem.isGprsConnected()) {
      disconnectTransport();
      return connectTransport(metrics);
    }
    Serial.println("MQTT reconnect (LTE still up)");
    if (config::kMqttUseTls) {
      configureLteTlsClient();
    }
    return connectMqtt(lteMqtt, lteNetworkClient(), metrics);
  }

  disconnectTransport();
  return connectTransport(metrics);
}

}  // namespace

void resetLteRadioCache() {
  ltePlanDReady = false;
}

bool connectTransport(TransportMetrics& metrics) {
  const uint8_t savedAttempts = metrics.transportAttempts;
  metrics = TransportMetrics{};
  metrics.transportAttempts = savedAttempts;
  activeMqtt = nullptr;
  activeTransport = TransportKind::kNone;

  const bool wifiConfigured = hasText(config::kWifiSsid);
  if (!config::kLteOnly && wifiConfigured && connectWifi(metrics)) {
    return true;
  }

  if (wifiConfigured && config::kLteEnabled && !config::kLteOnly) {
    metrics.usedFallback = true;
    Serial.println("Wi-Fi failed; falling back to LTE-M");
  }

  return connectLte(metrics);
}

bool connectTransportWithRetry(TransportMetrics& metrics, uint32_t cycleStartMs) {
  metrics = TransportMetrics{};
  metrics.transportAttempts = 0;

  for (uint8_t attempt = 1; attempt <= config::kTransportMaxAttempts; ++attempt) {
    if ((millis() - cycleStartMs) >= config::kCycleMaxActiveMs) {
      Serial.println("transport retry budget exhausted (active time)");
      break;
    }

    if (attempt > 1) {
      disconnectTransport();
      delay(config::kRetryDelayMs);
    }

    metrics.transportAttempts = attempt;
    Serial.printf("transport attempt %u/%u\n", attempt,
                  config::kTransportMaxAttempts);

    if (connectTransport(metrics)) {
      metrics.transportAttempts = attempt;
      return true;
    }
  }

  return false;
}

bool reconnectActiveTransport(TransportMetrics& metrics) {
  return reconnectTransport(metrics);
}

bool probeLteModem(LteProbeResult& result) {
  result = LteProbeResult{};
  const uint32_t start = millis();

  Serial.println("=== LTE-M probe ===");
  Serial.printf("uart rx=%d tx=%d baud=%d\n", LTE_UART_RX, LTE_UART_TX,
                LTE_UART_BAUD);

  result.uartOk = true;

  Serial.println("[1/5] modem init (AT) + plan-D setup...");
  result.initOk = beginLteUartAndModem();
  if (!result.initOk) {
    Serial.println("FAIL: no AT response (check UART cable, power, TX/RX)");
    result.elapsedMs = millis() - start;
    return false;
  }
  Serial.println("OK");

  strncpy(result.modemInfo, modem.getModemInfo().c_str(),
          sizeof(result.modemInfo) - 1);
  strncpy(result.imei, modem.getIMEI().c_str(), sizeof(result.imei) - 1);
  result.signalQuality = modem.getSignalQuality();

  Serial.printf("modem=%s\n", result.modemInfo);
  Serial.printf("imei=%s\n", result.imei);
  Serial.printf("csq=%d (0-31 valid, 99=unknown)\n", result.signalQuality);

  Serial.println("[2/5] SIM check...");
  logModemAt("+CPIN?");

  Serial.println("[3/5] network registration (plan-D Cat-M1)...");
  result.networkOk =
      modem.waitForNetwork(config::kLteNetworkTimeoutMs);
  if (!result.networkOk) {
    Serial.println("FAIL: not registered (check SIM, antenna, Cat-M1 coverage)");
    logLteDiagnostics();
    strncpy(result.operatorName, modem.getOperator().c_str(),
            sizeof(result.operatorName) - 1);
    Serial.printf("operator=%s\n", result.operatorName);
    result.elapsedMs = millis() - start;
    return false;
  }
  strncpy(result.operatorName, modem.getOperator().c_str(),
          sizeof(result.operatorName) - 1);
  Serial.printf("OK operator=%s\n", result.operatorName);

  Serial.printf("[4/5] data attach apn=%s user=%s...\n", config::kLteApn,
                config::kLteUser);
  result.gprsOk = modem.gprsConnect(config::kLteApn, config::kLteUser,
                                    config::kLtePassword);
  if (!result.gprsOk) {
    Serial.println("FAIL: GPRS attach failed (check APN / SIM plan)");
    result.elapsedMs = millis() - start;
    return false;
  }
  Serial.println("OK");

  result.signalQuality = modem.getSignalQuality();
  Serial.printf("[5/5] done csq=%d elapsed_ms=%lu\n", result.signalQuality,
                static_cast<unsigned long>(millis() - start));
  result.elapsedMs = millis() - start;
  activeTransport = TransportKind::kLte;
  return true;
}

void printLteProbeResult(const LteProbeResult& result) {
  Serial.println("--- LTE probe summary ---");
  Serial.printf("uart=%s init=%s network=%s gprs=%s\n",
                result.uartOk ? "ok" : "ng", result.initOk ? "ok" : "ng",
                result.networkOk ? "ok" : "ng", result.gprsOk ? "ok" : "ng");
  Serial.printf("modem=%s imei=%s operator=%s csq=%d elapsed_ms=%lu\n",
                result.modemInfo, result.imei, result.operatorName,
                result.signalQuality,
                static_cast<unsigned long>(result.elapsedMs));
  Serial.println(result.initOk && result.networkOk && result.gprsOk
                     ? "RESULT: PASS"
                     : "RESULT: FAIL");
}

bool syncClock(uint32_t timeoutMs) {
  time_t now = time(nullptr);
  if (now > 1700000000) {
    return true;
  }

  // lwIP SNTP (configTime) only reaches the network via the Wi-Fi netif. On the
  // LTE path the modem clock is set separately (ensureLteClock), so skip here to
  // avoid a guaranteed timeout that would burn the whole budget for nothing.
  if (WiFi.status() != WL_CONNECTED) {
    return false;
  }

  configTime(0, 0, config::kNtpServer);

  const uint32_t start = millis();
  while ((millis() - start) < timeoutMs) {
    time_t now = time(nullptr);
    if (now > 1700000000) {
      Serial.println("Time synchronized");
      return true;
    }
    delay(250);
  }

  Serial.println("Time sync timed out");
  return false;
}

bool publishTelemetryConfirmed(const char* payload, TransportMetrics& metrics) {
  if (activeMqtt == nullptr || !activeMqtt->connected()) {
    Serial.println("MQTT is not connected");
    return false;
  }

  const char* topic = getMqttTopic();
  const size_t len = strlen(payload);
  const uint32_t start = millis();

  // 256dpi/MQTT: QoS>0 publish blocks until PUBACK or timeout.
  activeMqtt->setTimeout(config::kMqttPublishTimeoutMs);
  const bool confirmed =
      activeMqtt->publish(topic, payload, len, false, config::kMqttQos);

  metrics.publishMs = millis() - start;
  Serial.printf(
      "MQTT publish topic=%s confirmed=%s qos=%u bytes=%u ms=%lu err=%d\n",
      topic, confirmed ? "yes" : "no", config::kMqttQos,
      static_cast<unsigned>(len), static_cast<unsigned long>(metrics.publishMs),
      activeMqtt->lastError());
  return confirmed;
}

int activeMqttState() {
  if (activeMqtt == nullptr) {
    return -1;
  }
  return activeMqtt->connected() ? 0 : -2;
}

void disconnectTransport() {
  wifiMqtt.disconnect();
  lteMqtt.disconnect();

  if (activeTransport == TransportKind::kWifi) {
    wifiClient.stop();
    wifiSecureClient.stop();
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
  } else if (activeTransport == TransportKind::kLte) {
    resetLteMqttLink();
    modem.gprsDisconnect();
    modem.poweroff();
  }

  activeMqtt = nullptr;
  activeTransport = TransportKind::kNone;
}

const char* transportName(TransportKind transport) {
  switch (transport) {
    case TransportKind::kWifi:
      return "wifi";
    case TransportKind::kLte:
      return "lte";
    case TransportKind::kNone:
    default:
      return "none";
  }
}
