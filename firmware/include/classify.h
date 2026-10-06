#pragma once

#include "sensor.h"

enum class ParkingStatus {
  kFull,
  kOpen,
  kUnknown,
};

ParkingStatus classifyStatus(const RawSample& sample, int threshold);
const char* statusToString(ParkingStatus status);
