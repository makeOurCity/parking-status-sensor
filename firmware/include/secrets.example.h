#pragma once

// Copy this file to firmware/include/secrets.h per device.
// secrets.h is ignored by git and may contain site/device-specific values.

// Empty → derive from chip Wi-Fi MAC at boot (e.g. xiao-e83dc1fb05fc).
#define PSS_DEVICE_ID ""
#define PSS_STATUS_THRESHOLD 100
#define PSS_SLEEP_SECONDS 300

#define PSS_WIFI_SSID "your-wifi-ssid"
#define PSS_WIFI_PASSWORD "your-wifi-password"

// --- MQTT ---
//
// Local Mosquitto (dev):
//   PSS_MQTT_HOST = Mac LAN IP, PSS_MQTT_PORT = 1883, no certs
// AWS IoT Core (PoC):
//   PSS_MQTT_HOST = xxx-ats.iot.ap-northeast-1.amazonaws.com
//   PSS_MQTT_PORT = 8883
//   PSS_MQTT_TOPIC = $aws/rules/parking_status_telemetry/parking-status/{deviceId}/telemetry
//   Certs in firmware/certs/ (see infra/provision-device.sh)
// Empty PSS_MQTT_TOPIC → parking-status/{deviceId}/telemetry (Mosquitto default)
//
#define PSS_MQTT_HOST "192.168.1.10"
#define PSS_MQTT_PORT 1883
#define PSS_MQTT_TOPIC ""
#define PSS_MQTT_USERNAME ""
#define PSS_MQTT_PASSWORD ""

// Set to 1 to allow LTE-M fallback when Wi-Fi is not configured or fails.
#define PSS_LTE_ENABLED 0
#define PSS_LTE_APN "soracom.io"
#define PSS_LTE_USER "sora"
#define PSS_LTE_PASSWORD "sora"

// MQTT publish / transport retry (optional overrides)
// #define PSS_TRANSPORT_MAX_ATTEMPTS 3
// #define PSS_PUBLISH_MAX_ATTEMPTS 3
// #define PSS_RETRY_DELAY_MS 1000
// #define PSS_CYCLE_MAX_ACTIVE_MS 45000
