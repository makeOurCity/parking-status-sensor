#pragma once

#include <stdint.h>

struct RawSample {
  uint16_t red;
  uint16_t green;
  uint16_t blue;
  uint16_t white;
};

bool initSensor();
bool readSensor(RawSample& out);
