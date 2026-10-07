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
// #43: VEML6040 積分時間を320ms→40ms化(1/8)したため暫定的に同倍率でスケールダウン
// (100/8=12.5→13)。現地設置後の実測で最終調整予定。
#define PSS_STATUS_THRESHOLD 13
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

// #40: Grove Wio-E5（LoRaWAN）。LTE-M と同じ Grove UART ポートを使うため排他。
#ifndef PSS_LORAWAN_ENABLED
#define PSS_LORAWAN_ENABLED 0
#endif

// Debug: Wio-E5 の AT 疎通確認 + USB シリアル素通し（#40 PR1）。
#ifndef PSS_LORAWAN_TEST_MODE
#define PSS_LORAWAN_TEST_MODE 0
#endif

// 1 回の AT+JOIN / AT+CMSGHEX の待ち上限（実測: Join 約6s、ACK 付き送信 約2s。
// docs/40-lorawan-design.md §4）。リトライ回数と予算は PSS_TRANSPORT_MAX_ATTEMPTS 等で。
#ifndef PSS_LORAWAN_JOIN_TIMEOUT_MS
#define PSS_LORAWAN_JOIN_TIMEOUT_MS 12000
#endif

#ifndef PSS_LORAWAN_UPLINK_TIMEOUT_MS
#define PSS_LORAWAN_UPLINK_TIMEOUT_MS 8000
#endif

// OTAA の JoinEUI(AppEUI) / AppKey（16 進文字列、secrets.h で設定）。
// 空なら Wio-E5 に保存済みの値を使う（電源投入時のプロビジョニングで書き込まない）。
#ifndef PSS_LORAWAN_APP_EUI
#define PSS_LORAWAN_APP_EUI ""
#endif

#ifndef PSS_LORAWAN_APP_KEY
#define PSS_LORAWAN_APP_KEY ""
#endif

static_assert(!(PSS_LORAWAN_ENABLED && PSS_LTE_ENABLED),
              "LoRaWAN and LTE-M share the Grove UART port (check PSS_LTE_ENABLED in secrets.h)");
static_assert(!PSS_LORAWAN_TEST_MODE || PSS_LORAWAN_ENABLED,
              "PSS_LORAWAN_TEST_MODE requires PSS_LORAWAN_ENABLED");

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

// #41: hardware task watchdog. Fed once per cycle at runCycle() entry only, so
// any single cycle (sensor + connect + publish) that overruns the budget +
// margin reboots the device instead of hanging silently forever.
#ifndef PSS_WATCHDOG_ENABLED
#define PSS_WATCHDOG_ENABLED 0
#endif

#ifndef PSS_WATCHDOG_MARGIN_MS
#define PSS_WATCHDOG_MARGIN_MS 20000
#endif

// #46: Grove 2-Coil Latching Relay で LTE-M モジュールの5V線を物理遮断する。
// リレー未配線の機体に誤って有効化すると LTE が一切起動しなくなるため、
// 配線済みの env（xiao-s3-aws-lte-relay）でのみ 1 にする。
#ifndef PSS_LTE_POWER_RELAY_ENABLED
#define PSS_LTE_POWER_RELAY_ENABLED 0
#endif

// Set/Reset パルス幅。SIGのレベルを保持する時間で、コイルの通電幅は決めない
// （通電幅は基板側のRC回路で決まる。relay.h の注意を参照）。既定20ms。
#ifndef PSS_RELAY_PULSE_MS
#define PSS_RELAY_PULSE_MS 20
#endif

// リレー投入直後（真のコールド電源投入）からモデムがUART応答可能になるまでの
// 起動待ち時間。transport.cpp の既存値(1.5s)は AT+CPOWD からの復帰用に調整
// されており、VCC断からの完全なコールドブートには短すぎる可能性が高い。
#ifndef PSS_LTE_COLD_BOOT_SETTLE_MS
#define PSS_LTE_COLD_BOOT_SETTLE_MS 5000
#endif

// #25/#46: 状態変化時のみ送信する（heartbeatDue / pendingValid も送信条件に含む）。
// 0 = PoC の全サイクル送信（従来動作）。
#ifndef PSS_CHANGE_ONLY_SEND
#define PSS_CHANGE_ONLY_SEND 0
#endif

// change-only 送信時、状態変化がなくてもこのサイクル数ごとに強制送信する
// （監視の生存確認用）。既定12サイクル×5分=1時間。
#ifndef PSS_HEARTBEAT_CYCLES
#define PSS_HEARTBEAT_CYCLES 12
#endif

// #47: 毎サイクルのセンサー観測ログ(NVSリングバッファ)。読み取り専用の現地診断用。
// 送信・LTE接続には一切影響しない(docs/47-history-log-design.md)。
#ifndef PSS_HISTORY_LOG_ENABLED
#define PSS_HISTORY_LOG_ENABLED 1
#endif

// 1エントリ16バイト(timestamp+status+flags+bootCountLo8+raw4ch)。
// 候補値。実機のnvs_get_stats()検証(§9.3)を経てから確定する前提の暫定値。
#ifndef PSS_HISTORY_LOG_CAPACITY
#define PSS_HISTORY_LOG_CAPACITY 672
#endif

// capacity はこの値で割り切れる必要がある(static_assertで保証)。
#ifndef PSS_HISTORY_LOG_SEGMENTS
#define PSS_HISTORY_LOG_SEGMENTS 14
#endif

// 起動時ダンプの最大表示件数。0 = 無制限(全件)。
#ifndef PSS_HISTORY_LOG_DUMP_MAX
#define PSS_HISTORY_LOG_DUMP_MAX 0
#endif

// #50: 電源投入(コールドブート)直後のみ、mustPublish()を無視して無条件に
// 短間隔連続送信する「ブートモード」。現地調整時の動作確認用。
// docs/50-boot-mode-design.md 参照。
#ifndef PSS_BOOT_MODE_ENABLED
#define PSS_BOOT_MODE_ENABLED 1
#endif

#ifndef PSS_BOOT_MODE_SEND_COUNT
#define PSS_BOOT_MODE_SEND_COUNT 5
#endif

#ifndef PSS_BOOT_MODE_SLOT_INTERVAL_MS
#define PSS_BOOT_MODE_SLOT_INTERVAL_MS 60000  // 5回 x 60秒 = 総所要時間 約4分
#endif

#ifndef PSS_POT_ENABLED
// #60: 現地調整用ポテンショメーター(Grove - Rotary Angle Sensor、Grove Shield
// for XIAO Analogポート/D1/GPIO2)による判定閾値の可変化。
// リレー(#46)同様、配線済みの機体でのみ1にする。未配線機体でフローティングピンの
// 不定値を閾値として使わないための安全弁。docs/60-potentiometer-threshold-design.md 参照。
#define PSS_POT_ENABLED 0
#endif

#ifndef PSS_POT_SAMPLE_COUNT
#define PSS_POT_SAMPLE_COUNT 8
#endif

#ifndef PSS_POT_THRESHOLD_MIN
// 対数マッピングの下限。複数現場の実測が揃うまでの暫定値(Issue #60時点)。
#define PSS_POT_THRESHOLD_MIN 30
#endif

#ifndef PSS_POT_THRESHOLD_MAX
// 対数マッピングの上限。2026-08-25屋外実測(r-g差分最大-11173)に3割の余裕を持たせた
// 暫定値(Issue #60時点)。#3遮光フード完成後、屋外レンジが変われば再評価する。
#define PSS_POT_THRESHOLD_MAX 15000
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
constexpr bool kLoRaWanEnabled = PSS_LORAWAN_ENABLED;
constexpr uint32_t kLoRaWanJoinTimeoutMs = PSS_LORAWAN_JOIN_TIMEOUT_MS;
constexpr uint32_t kLoRaWanUplinkTimeoutMs = PSS_LORAWAN_UPLINK_TIMEOUT_MS;
constexpr const char* kLoRaWanAppEui = PSS_LORAWAN_APP_EUI;
constexpr const char* kLoRaWanAppKey = PSS_LORAWAN_APP_KEY;
constexpr bool kLteKeepModem = PSS_LTE_KEEP_MODEM;
constexpr bool kLteModemTls = PSS_LTE_MODEM_TLS;

constexpr uint8_t kTransportMaxAttempts = PSS_TRANSPORT_MAX_ATTEMPTS;
constexpr uint8_t kPublishMaxAttempts = PSS_PUBLISH_MAX_ATTEMPTS;
constexpr uint32_t kRetryDelayMs = PSS_RETRY_DELAY_MS;
constexpr uint32_t kCycleMaxActiveMs = PSS_CYCLE_MAX_ACTIVE_MS;
constexpr uint32_t kConnectPhaseMs = PSS_CONNECT_PHASE_MS;
// #87: 接続の hard deadline。soft（kConnectPhaseMs）は「新しい試行を始めるか」の判断だけに
// 使い、hard は実行中の AT 待ちと waitForNetwork を縮める上限。cycle = connect 45 +
// publish 20 + マージン 10（docs/sync-delivery-design.md §4.1）。接続が hard で終わっても
// publish 20s が残る。PSS_CYCLE_MAX_ACTIVE_MS を超えない。
constexpr uint32_t kConnectHardMs =
    (PSS_CONNECT_PHASE_MS + 10000 < PSS_CYCLE_MAX_ACTIVE_MS)
        ? PSS_CONNECT_PHASE_MS + 10000
        : PSS_CYCLE_MAX_ACTIVE_MS;
constexpr uint32_t kPublishPhaseMs = PSS_PUBLISH_PHASE_MS;
constexpr uint8_t kFaultInjectPublishFails = PSS_FAULT_INJECT_PUBLISH_FAILS;

constexpr bool kWatchdogEnabled = PSS_WATCHDOG_ENABLED;
constexpr uint32_t kWatchdogTimeoutMs =
    PSS_CYCLE_MAX_ACTIVE_MS + PSS_WATCHDOG_MARGIN_MS;

constexpr bool kLtePowerRelayEnabled = PSS_LTE_POWER_RELAY_ENABLED;
constexpr uint32_t kRelayPulseMs = PSS_RELAY_PULSE_MS;
constexpr uint32_t kLteColdBootSettleMs = PSS_LTE_COLD_BOOT_SETTLE_MS;
constexpr bool kChangeOnlySend = PSS_CHANGE_ONLY_SEND;
constexpr uint32_t kHeartbeatCycles = PSS_HEARTBEAT_CYCLES;

constexpr bool kHistoryLogEnabled = PSS_HISTORY_LOG_ENABLED;
constexpr uint16_t kHistoryLogCapacity = PSS_HISTORY_LOG_CAPACITY;
constexpr uint16_t kHistoryLogSegments = PSS_HISTORY_LOG_SEGMENTS;
constexpr uint16_t kHistoryLogDumpMax = PSS_HISTORY_LOG_DUMP_MAX;

constexpr bool kBootModeEnabled = PSS_BOOT_MODE_ENABLED;
constexpr uint8_t kBootModeSendCount = PSS_BOOT_MODE_SEND_COUNT;
constexpr uint32_t kBootModeSlotIntervalMs = PSS_BOOT_MODE_SLOT_INTERVAL_MS;

constexpr bool kPotEnabled = PSS_POT_ENABLED;
constexpr uint8_t kPotSampleCount = PSS_POT_SAMPLE_COUNT;
constexpr int kPotThresholdMin = PSS_POT_THRESHOLD_MIN;
constexpr int kPotThresholdMax = PSS_POT_THRESHOLD_MAX;

}  // namespace config

static_assert(PSS_POT_THRESHOLD_MIN > 0 && PSS_POT_THRESHOLD_MAX > PSS_POT_THRESHOLD_MIN,
              "PSS_POT_THRESHOLD_MIN/MAX must form a positive, increasing range for the "
              "logarithmic mapping (powf(MAX/MIN, ratio)) to stay well-defined");
static_assert(PSS_HISTORY_LOG_CAPACITY % PSS_HISTORY_LOG_SEGMENTS == 0,
              "PSS_HISTORY_LOG_CAPACITY must divide evenly into PSS_HISTORY_LOG_SEGMENTS");
static_assert((PSS_HISTORY_LOG_CAPACITY / PSS_HISTORY_LOG_SEGMENTS) * 16 % 32 == 0,
              "history log segment body must be a multiple of 32B to avoid NVS padding waste");
