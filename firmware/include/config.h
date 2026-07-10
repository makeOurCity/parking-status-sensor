#pragma once

#include <stdint.h>

#if __has_include("secrets.h")
#include "secrets.h"
#define PSS_HAS_SECRETS 1
#else
#define PSS_HAS_SECRETS 0
#endif

// Empty PSS_DEVICE_ID → derive from chip Wi-Fi MAC (see device_id.cpp).
#ifndef PSS_DEVICE_ID
#define PSS_DEVICE_ID ""
#endif

#ifndef PSS_STATUS_THRESHOLD
#define PSS_STATUS_THRESHOLD 100
#endif

#ifndef PSS_SLEEP_SECONDS
#define PSS_SLEEP_SECONDS 300
#endif

#ifndef PSS_WIFI_SSID
#define PSS_WIFI_SSID ""
#endif

#ifndef PSS_WIFI_PASSWORD
#define PSS_WIFI_PASSWORD ""
#endif

#ifndef PSS_WIFI_CONNECT_TIMEOUT_MS
#define PSS_WIFI_CONNECT_TIMEOUT_MS 20000
#endif

#ifndef PSS_MQTT_HOST
#define PSS_MQTT_HOST "192.168.1.10"
#endif

#ifndef PSS_MQTT_PORT
#define PSS_MQTT_PORT 1883
#endif

#ifndef PSS_MQTT_USE_TLS
#define PSS_MQTT_USE_TLS 0
#endif

// Empty PSS_MQTT_TOPIC → parking-status/{deviceId}/telemetry
#ifndef PSS_MQTT_TOPIC
#define PSS_MQTT_TOPIC ""
#endif

// Empty by default. If set, firmware builds:
// $aws/rules/{rule}/parking-status/{deviceId}/telemetry
#ifndef PSS_MQTT_BASIC_INGEST_RULE
#define PSS_MQTT_BASIC_INGEST_RULE ""
#endif

#ifndef PSS_MQTT_USERNAME
#define PSS_MQTT_USERNAME ""
#endif

#ifndef PSS_MQTT_PASSWORD
#define PSS_MQTT_PASSWORD ""
#endif

#ifndef PSS_MQTT_CONNECT_TIMEOUT_MS
#define PSS_MQTT_CONNECT_TIMEOUT_MS 10000
#endif

#ifndef PSS_MQTT_QOS
#define PSS_MQTT_QOS 1
#endif

#ifndef PSS_MQTT_PUBLISH_TIMEOUT_MS
#define PSS_MQTT_PUBLISH_TIMEOUT_MS 5000
#endif

#ifndef PSS_NTP_SERVER
#define PSS_NTP_SERVER "pool.ntp.org"
#endif

#ifndef PSS_TIME_SYNC_TIMEOUT_MS
#define PSS_TIME_SYNC_TIMEOUT_MS 5000
#endif

#ifndef PSS_LTE_ENABLED
#define PSS_LTE_ENABLED 0
#endif

#ifndef PSS_LTE_APN
#define PSS_LTE_APN "soracom.io"
#endif

#ifndef PSS_LTE_USER
#define PSS_LTE_USER "sora"
#endif

#ifndef PSS_LTE_PASSWORD
#define PSS_LTE_PASSWORD "sora"
#endif

#ifndef PSS_LTE_NETWORK_TIMEOUT_MS
#define PSS_LTE_NETWORK_TIMEOUT_MS 60000
#endif

#ifndef PSS_DEBUG_LOOP_DELAY_MS
#define PSS_DEBUG_LOOP_DELAY_MS 5000
#endif

#ifndef PSS_DISABLE_DEEP_SLEEP
#define PSS_DISABLE_DEEP_SLEEP 0
#endif

#ifndef PSS_LTE_TEST_MODE
#define PSS_LTE_TEST_MODE 0
#endif

// Debug: LTE attach → poweroff → recover loop (#25 Phase 0 poweroff spike).
#ifndef PSS_LTE_POWEROFF_TEST_MODE
#define PSS_LTE_POWEROFF_TEST_MODE 0
#endif

#ifndef PSS_LTE_POWEROFF_OBSERVE_MS
#define PSS_LTE_POWEROFF_OBSERVE_MS 30000
#endif

#ifndef PSS_LTE_ONLY
#define PSS_LTE_ONLY 0
#endif

// Debug: skip modem poweroff between cycles (measure warm reconnect only).
#ifndef PSS_LTE_KEEP_MODEM
#define PSS_LTE_KEEP_MODEM 0
#endif

// LTE: TLS on SIM7080 modem (not ESP32 SSLClient over UART).
#ifndef PSS_LTE_MODEM_TLS
#define PSS_LTE_MODEM_TLS 0
#endif

#ifndef PSS_LTE_FORCE_CERT_UPLOAD
#define PSS_LTE_FORCE_CERT_UPLOAD 0
#endif

#ifndef PSS_TRANSPORT_MAX_ATTEMPTS
#define PSS_TRANSPORT_MAX_ATTEMPTS 3
#endif

#ifndef PSS_PUBLISH_MAX_ATTEMPTS
#define PSS_PUBLISH_MAX_ATTEMPTS 3
#endif

#ifndef PSS_RETRY_DELAY_MS
#define PSS_RETRY_DELAY_MS 1000
#endif

#ifndef PSS_CYCLE_MAX_ACTIVE_MS
#define PSS_CYCLE_MAX_ACTIVE_MS 60000
#endif

// Phase budgets (subsets of the whole-cycle budget). See docs/sync-delivery-design.md §4.1.
#ifndef PSS_CONNECT_PHASE_MS
#define PSS_CONNECT_PHASE_MS 45000
#endif

#ifndef PSS_PUBLISH_PHASE_MS
#define PSS_PUBLISH_PHASE_MS 20000
#endif

// Debug: force publish failures to exercise the failure path (§5.1).
// 0 = disabled. N > 0 = fail the direct publish for the first N cycles per power cycle.
#ifndef PSS_FAULT_INJECT_PUBLISH_FAILS
#define PSS_FAULT_INJECT_PUBLISH_FAILS 0
#endif

namespace config {

constexpr int kStatusThreshold = PSS_STATUS_THRESHOLD;
constexpr uint32_t kSleepSeconds = PSS_SLEEP_SECONDS;

constexpr const char* kWifiSsid = PSS_WIFI_SSID;
constexpr const char* kWifiPassword = PSS_WIFI_PASSWORD;
constexpr uint32_t kWifiConnectTimeoutMs = PSS_WIFI_CONNECT_TIMEOUT_MS;

constexpr const char* kMqttHost = PSS_MQTT_HOST;
constexpr uint16_t kMqttPort = PSS_MQTT_PORT;
constexpr bool kMqttUseTls = PSS_MQTT_USE_TLS;
constexpr const char* kMqttUsername = PSS_MQTT_USERNAME;
constexpr const char* kMqttPassword = PSS_MQTT_PASSWORD;
constexpr uint32_t kMqttConnectTimeoutMs = PSS_MQTT_CONNECT_TIMEOUT_MS;
constexpr uint8_t kMqttQos = PSS_MQTT_QOS;
constexpr uint32_t kMqttPublishTimeoutMs = PSS_MQTT_PUBLISH_TIMEOUT_MS;

constexpr const char* kNtpServer = PSS_NTP_SERVER;
constexpr uint32_t kTimeSyncTimeoutMs = PSS_TIME_SYNC_TIMEOUT_MS;

constexpr bool kLteEnabled = PSS_LTE_ENABLED;
constexpr const char* kLteApn = PSS_LTE_APN;
constexpr const char* kLteUser = PSS_LTE_USER;
constexpr const char* kLtePassword = PSS_LTE_PASSWORD;
constexpr uint32_t kLteNetworkTimeoutMs = PSS_LTE_NETWORK_TIMEOUT_MS;

constexpr uint32_t kDebugLoopDelayMs = PSS_DEBUG_LOOP_DELAY_MS;
constexpr bool kDisableDeepSleep = PSS_DISABLE_DEEP_SLEEP;
constexpr bool kLteTestMode = PSS_LTE_TEST_MODE;
constexpr bool kLtePoweroffTestMode = PSS_LTE_POWEROFF_TEST_MODE;
constexpr uint32_t kLtePoweroffObserveMs = PSS_LTE_POWEROFF_OBSERVE_MS;
constexpr bool kLteOnly = PSS_LTE_ONLY;
constexpr bool kLteKeepModem = PSS_LTE_KEEP_MODEM;
constexpr bool kLteModemTls = PSS_LTE_MODEM_TLS;

constexpr uint8_t kTransportMaxAttempts = PSS_TRANSPORT_MAX_ATTEMPTS;
constexpr uint8_t kPublishMaxAttempts = PSS_PUBLISH_MAX_ATTEMPTS;
constexpr uint32_t kRetryDelayMs = PSS_RETRY_DELAY_MS;
constexpr uint32_t kCycleMaxActiveMs = PSS_CYCLE_MAX_ACTIVE_MS;
constexpr uint32_t kConnectPhaseMs = PSS_CONNECT_PHASE_MS;
constexpr uint32_t kPublishPhaseMs = PSS_PUBLISH_PHASE_MS;
constexpr uint8_t kFaultInjectPublishFails = PSS_FAULT_INJECT_PUBLISH_FAILS;

}  // namespace config
