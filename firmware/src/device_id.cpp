#include "device_id.h"

#include <Arduino.h>
#include <cstdio>
#include <esp_mac.h>

#include "config.h"

namespace {

char s_deviceId[32];
char s_mqttTopic[128];
bool s_initialized = false;

void formatMacDeviceId(uint8_t mac[6]) {
  snprintf(s_deviceId, sizeof(s_deviceId),
           "xiao-%02x%02x%02x%02x%02x%02x", mac[0], mac[1], mac[2], mac[3],
           mac[4], mac[5]);
}

}  // namespace

void initDeviceIdentity() {
  if (s_initialized) {
    return;
  }

  if (PSS_DEVICE_ID[0] != '\0') {
    snprintf(s_deviceId, sizeof(s_deviceId), "%s", PSS_DEVICE_ID);
  } else {
    uint8_t mac[6]{};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    formatMacDeviceId(mac);
  }

  if (PSS_MQTT_TOPIC[0] != '\0') {
    snprintf(s_mqttTopic, sizeof(s_mqttTopic), "%s", PSS_MQTT_TOPIC);
  } else if (PSS_MQTT_BASIC_INGEST_RULE[0] != '\0') {
    snprintf(s_mqttTopic, sizeof(s_mqttTopic),
             "$aws/rules/%s/parking-status/%s/telemetry",
             PSS_MQTT_BASIC_INGEST_RULE, s_deviceId);
  } else {
    snprintf(s_mqttTopic, sizeof(s_mqttTopic), "parking-status/%s/telemetry",
             s_deviceId);
  }

  s_initialized = true;
}

const char* getDeviceId() {
  if (!s_initialized) {
    initDeviceIdentity();
  }
  return s_deviceId;
}

const char* getMqttTopic() {
  if (!s_initialized) {
    initDeviceIdentity();
  }
  return s_mqttTopic;
}
