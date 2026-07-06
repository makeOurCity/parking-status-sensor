#pragma once

#include <stddef.h>
#include <stdint.h>

// Persistent FIFO of undelivered MQTT payloads (survives Deep Sleep / reboot).
void initOutbox();
uint8_t outboxCount();
bool outboxPeek(char* out, size_t outSize);
bool outboxEnqueue(const char* payload);
void outboxDequeue();
