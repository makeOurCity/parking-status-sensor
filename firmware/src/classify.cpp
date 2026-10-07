#include "classify.h"

ParkingStatus classifyStatus(const RawSample& sample, int threshold) {
  const int rgDiff =
      static_cast<int>(sample.red) - static_cast<int>(sample.green);

  if (rgDiff >= threshold) {
    return ParkingStatus::kFull;
  }
  if (-rgDiff >= threshold) {
    return ParkingStatus::kOpen;
  }
  return ParkingStatus::kUnknown;
}

const char* statusToString(ParkingStatus status) {
  switch (status) {
    case ParkingStatus::kFull:
      return "full";
    case ParkingStatus::kOpen:
      return "open";
    case ParkingStatus::kUnknown:
    default:
      return "unknown";
  }
}
