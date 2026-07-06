#include "transport.h"

#define TINY_GSM_MODEM_SIM7080

#include <Arduino.h>
#include <MQTT.h>
#include <TinyGsmClient.h>
#include <WiFi.h>
#include <esp_system.h>
#include <string.h>
#include <time.h>

#include "board.h"
#include "config.h"
#include "device_id.h"

namespace {

WiFiClient wifiClient;
MQTTClient wifiMqtt(1024);

TinyGsm modem(Serial1);
TinyGsmClient lteClient(modem);
MQTTClient lteMqtt(1024);

MQTTClient* activeMqtt = nullptr;
TransportKind activeTransport = TransportKind::kNone;

bool hasText(const char* value) {
  return value != nullptr && value[0] != '\0';
}

String mqttClientId() {
  return String(getDeviceId()) + "-" + String(static_cast<uint32_t>(esp_random()), HEX);
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
    return false;
  }
  prepareLteForPlanD();
  return true;
}

bool connectMqtt(MQTTClient& mqtt, Client& net, TransportMetrics& metrics) {
  mqtt.begin(config::kMqttHost, config::kMqttPort, net);
  mqtt.setOptions(60, true, 2000);

  const uint32_t start = millis();
  const String clientId = mqttClientId();
  while ((millis() - start) < config::kMqttConnectTimeoutMs) {
    const bool connected =
        hasText(config::kMqttUsername)
            ? mqtt.connect(clientId.c_str(), config::kMqttUsername,
                           config::kMqttPassword)
            : mqtt.connect(clientId.c_str());
    if (connected) {
      metrics.mqttConnectMs = millis() - start;
      return true;
    }
    delay(500);
  }

  metrics.mqttConnectMs = millis() - start;
  Serial.printf("MQTT connect failed host=%s port=%u\n", config::kMqttHost,
                config::kMqttPort);
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
  Serial.printf("Wi-Fi connected ip=%s rssi=%ld\n",
                WiFi.localIP().toString().c_str(),
                static_cast<long>(metrics.wifiRssi));

  if (!connectMqtt(wifiMqtt, wifiClient, metrics)) {
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
    return false;
  }

  activeMqtt = &wifiMqtt;
  activeTransport = TransportKind::kWifi;
  return true;
}

bool connectLte(TransportMetrics& metrics) {
  if (!config::kLteEnabled) {
    return false;
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
  Serial.printf("LTE-M connected operator=%s\n", modem.getOperator().c_str());

  if (!connectMqtt(lteMqtt, lteClient, metrics)) {
    modem.gprsDisconnect();
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
    return connectMqtt(wifiMqtt, wifiClient, metrics);
  }

  if (activeTransport == TransportKind::kLte && activeMqtt == &lteMqtt &&
      activeMqtt->connected()) {
    return true;
  }

  disconnectTransport();
  return connectTransport(metrics);
}

}  // namespace

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
  if (activeMqtt != nullptr && activeMqtt->connected()) {
    activeMqtt->disconnect();
  }

  if (activeTransport == TransportKind::kWifi) {
    WiFi.disconnect(true);
    WiFi.mode(WIFI_OFF);
  } else if (activeTransport == TransportKind::kLte) {
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
