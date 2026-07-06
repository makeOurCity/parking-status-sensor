#pragma once

// Resolves deviceId (MAC-based by default) and MQTT topic once at boot.
void initDeviceIdentity();
const char* getDeviceId();
const char* getMqttTopic();
