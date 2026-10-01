#include "wio_e5.h"

#include <string.h>

namespace {

HardwareSerial* wioPort = nullptr;
constexpr size_t kLineSize = 160;

bool startsWith(const char* s, const char* prefix) {
  return strncmp(s, prefix, strlen(prefix)) == 0;
}

void logTx(const char* cmd) {
  if (startsWith(cmd, "AT+KEY")) {
    Serial.println("wio> AT+KEY=********");
    return;
  }
  Serial.printf("wio> %s\n", cmd);
}

void logRx(const char* line) {
  if (startsWith(line, "+KEY:")) {
    Serial.println("wio< +KEY: ********");
    return;
  }
  Serial.printf("wio< %s\n", line);
}

void drainInput() {
  while (wioPort->available() > 0) {
    wioPort->read();
  }
}

// 前のコマンドの複数行応答（例: AT+DR の一覧）が続いている間は捨てる。
// 9600bps では行が途切れなく届くため、quietMs 無受信で区切りとみなす。
void drainUntilQuiet(uint32_t quietMs = 50, uint32_t maxMs = 1000) {
  const uint32_t start = millis();
  uint32_t lastRx = millis();
  while (millis() - lastRx < quietMs && millis() - start < maxMs) {
    if (wioPort->available() > 0) {
      wioPort->read();
      lastRx = millis();
    } else {
      delay(1);
    }
  }
}

// 1 行（'\n' 区切り、'\r' は除去）を読む。空行は読み飛ばす。
bool readLine(char* out, size_t outSize, uint32_t deadlineMs) {
  size_t len = 0;
  while (static_cast<int32_t>(deadlineMs - millis()) > 0) {
    if (wioPort->available() <= 0) {
      delay(1);
      continue;
    }
    const int c = wioPort->read();
    if (c == '\r') {
      continue;
    }
    if (c == '\n') {
      if (len == 0) {
        continue;
      }
      out[len] = '\0';
      return true;
    }
    if (len + 1 < outSize) {
      out[len++] = static_cast<char>(c);
    }
  }
  return false;
}

}  // namespace

void wioE5Begin(HardwareSerial& port, int rxPin, int txPin, uint32_t baud) {
  wioPort = &port;
  wioPort->begin(baud, SERIAL_8N1, rxPin, txPin);
  delay(20);
  drainInput();
}

void wioE5End() {
  if (wioPort == nullptr) {
    return;
  }
  wioPort->flush();
  wioPort->end();
  wioPort = nullptr;
}

bool wioE5Started() { return wioPort != nullptr; }

bool wioE5Command(const char* cmd, const char* expectPrefix, uint32_t timeoutMs,
                  char* resp, size_t respSize) {
  if (wioPort == nullptr) {
    return false;
  }
  drainUntilQuiet();
  logTx(cmd);
  wioPort->print(cmd);
  wioPort->print("\r\n");

  const uint32_t deadline = millis() + timeoutMs;
  char line[kLineSize];
  while (readLine(line, sizeof(line), deadline)) {
    logRx(line);
    if (!startsWith(line, expectPrefix)) {
      continue;
    }
    if (resp != nullptr && respSize > 0) {
      strncpy(resp, line, respSize - 1);
      resp[respSize - 1] = '\0';
    }
    return strstr(line, "ERROR") == nullptr;
  }
  Serial.printf("wio: timeout waiting for %s\n", expectPrefix);
  return false;
}

bool wioE5Wake(uint8_t attempts, uint32_t perAttemptMs) {
  if (wioPort == nullptr) {
    return false;
  }
  for (uint8_t i = 0; i < attempts; ++i) {
    drainInput();
    char resp[kLineSize];
    if (wioE5Command("AT", "+AT:", perAttemptMs, resp, sizeof(resp)) &&
        strcmp(resp, "+AT: OK") == 0) {
      return true;
    }
  }
  return false;
}

bool wioE5Sleep() {
  return wioE5Command("AT+LOWPOWER", "+LOWPOWER:", 1000);
}

bool wioE5RunProbe() {
  Serial.println("=== Wio-E5 probe ===");
  const bool atOk = wioE5Wake();
  Serial.printf("at=%s\n", atOk ? "OK" : "FAIL");
  if (!atOk) {
    Serial.println("RESULT: FAIL no AT response");
    return false;
  }

  struct Query {
    const char* cmd;
    const char* prefix;
    bool required;
  };
  // 必須: VER / DevEui。他は現在の設定を記録するための情報取得。
  const Query queries[] = {
      {"AT+VER", "+VER:", true},          {"AT+ID=DevEui", "+ID:", true},
      {"AT+ID=AppEui", "+ID:", false},    {"AT+MODE", "+MODE:", false},
      {"AT+DR=SCHEME", "+DR:", false},    {"AT+DR", "+DR:", false},
      {"AT+ADR", "+ADR:", false},         {"AT+CLASS", "+CLASS:", false},
      {"AT+RETRY", "+RETRY:", false},     {"AT+PORT", "+PORT:", false},
  };

  bool ok = true;
  for (const Query& q : queries) {
    const bool r = wioE5Command(q.cmd, q.prefix, 1000);
    if (!r && q.required) {
      ok = false;
    }
  }

  const bool slept = wioE5Sleep();
  delay(1000);
  const bool woke = wioE5Wake();
  Serial.printf("lowpower sleep=%s wake=%s\n", slept ? "OK" : "FAIL",
                woke ? "OK" : "FAIL");
  ok = ok && slept && woke;

  Serial.printf("RESULT: %s\n", ok ? "PASS" : "FAIL");
  return ok;
}

void wioE5PassthroughPoll() {
  if (wioPort == nullptr) {
    return;
  }
  while (Serial.available() > 0) {
    wioPort->write(static_cast<uint8_t>(Serial.read()));
  }
  while (wioPort->available() > 0) {
    Serial.write(static_cast<uint8_t>(wioPort->read()));
  }
}
