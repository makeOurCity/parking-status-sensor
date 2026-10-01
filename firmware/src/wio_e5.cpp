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

bool wioE5ProvisionOtaa(const char* appEui, const char* appKey, uint8_t fport) {
  if (!wioE5Wake()) {
    return false;
  }
  char cmd[64];
  bool ok = true;
  // EU868 の工場出荷設定から切り替える（送信前に必須）。JP920 は AS923 互換の
  // 日本向けプラン（AT Command Specification §1.1 脚注）。既定チャネル 923.2/923.4MHz は
  // AWS の AS923-1 と同じ。
  ok = wioE5Command("AT+DR=JP920", "+DR:", 1000) && ok;
  ok = wioE5Command("AT+MODE=LWOTAA", "+MODE:", 1000) && ok;
  ok = wioE5Command("AT+CLASS=A", "+CLASS:", 1000) && ok;
  ok = wioE5Command("AT+ADR=ON", "+ADR:", 1000) && ok;
  // 再送はファーム側（publishWithRetry）に一本化する。2 未満なら 1 回だけ送る
  // （AT Command Specification §4.17。このファームでは 0 は ERROR になる）。
  ok = wioE5Command("AT+RETRY=1", "+RETRY:", 1000) && ok;
  snprintf(cmd, sizeof(cmd), "AT+PORT=%u", static_cast<unsigned>(fport));
  ok = wioE5Command(cmd, "+PORT:", 1000) && ok;
  if (appEui != nullptr && appEui[0] != '\0') {
    snprintf(cmd, sizeof(cmd), "AT+ID=AppEui,\"%s\"", appEui);
    ok = wioE5Command(cmd, "+ID:", 1000) && ok;
  }
  if (appKey != nullptr && appKey[0] != '\0') {
    snprintf(cmd, sizeof(cmd), "AT+KEY=APPKEY,\"%s\"", appKey);
    ok = wioE5Command(cmd, "+KEY:", 1000) && ok;
  }
  Serial.printf("wio: provision %s\n", ok ? "OK" : "FAIL");
  return ok;
}

const char* wioE5ResultToString(WioE5Result result) {
  switch (result) {
    case WioE5Result::kOk:
      return "ok";
    case WioE5Result::kNoAck:
      return "no_ack";
    case WioE5Result::kNotJoined:
      return "not_joined";
    case WioE5Result::kJoinFailed:
      return "join_failed";
    case WioE5Result::kBusy:
      return "busy";
    case WioE5Result::kError:
      return "error";
    case WioE5Result::kTimeout:
      return "timeout";
  }
  return "unknown";
}

namespace {

// prefix で始まる応答行を "<prefix> Done" または致命的な行まで読み、classify で
// 1 行ずつ判定する。classify は確定した結果を返せば true。
template <typename Classify>
WioE5Result readUntilDone(const char* prefix, uint32_t timeoutMs, WioE5Result initial,
                          Classify classify) {
  const uint32_t deadline = millis() + timeoutMs;
  const size_t prefixLen = strlen(prefix);
  WioE5Result result = initial;
  char line[kLineSize];
  while (readLine(line, sizeof(line), deadline)) {
    logRx(line);
    if (strncmp(line, prefix, prefixLen) != 0) {
      continue;
    }
    const char* body = line + prefixLen;
    while (*body == ' ') {
      ++body;
    }
    if (strstr(body, "ERROR") != nullptr) {
      return WioE5Result::kError;
    }
    if (strstr(body, "busy") != nullptr || strstr(body, "No free channel") != nullptr ||
        strstr(body, "No band") != nullptr) {
      return WioE5Result::kBusy;
    }
    if (strstr(body, "Please join network first") != nullptr) {
      return WioE5Result::kNotJoined;
    }
    if (strstr(body, "Length error") != nullptr) {
      return WioE5Result::kError;  // 今の DR の最大ペイロードを超えた（dwell time 有効時の DR2 等）
    }
    if (classify(body, result)) {
      return result;
    }
    if (strcmp(body, "Done") == 0) {
      return result;
    }
  }
  return WioE5Result::kTimeout;
}

}  // namespace

WioE5Result wioE5Join(uint32_t timeoutMs, WioE5JoinInfo* info) {
  if (!wioE5Wake()) {
    return WioE5Result::kTimeout;
  }
  const uint32_t start = millis();
  drainUntilQuiet();
  logTx("AT+JOIN");
  wioPort->print("AT+JOIN\r\n");
  bool already = false;
  const WioE5Result result = readUntilDone(
      "+JOIN:", timeoutMs, WioE5Result::kJoinFailed,
      [&already](const char* body, WioE5Result& r) {
        if (strstr(body, "Joined already") != nullptr) {
          already = true;
          r = WioE5Result::kOk;
          return true;
        }
        if (strstr(body, "Network joined") != nullptr) {
          r = WioE5Result::kOk;  // 続く NetID 行と Done まで読む
        } else if (strstr(body, "Join failed") != nullptr) {
          r = WioE5Result::kJoinFailed;
        }
        return false;
      });
  if (info != nullptr) {
    info->alreadyJoined = already;
    info->elapsedMs = millis() - start;
  }
  Serial.printf("wio: join result=%s already=%d elapsed_ms=%lu\n",
                wioE5ResultToString(result), already ? 1 : 0,
                static_cast<unsigned long>(millis() - start));
  return result;
}

WioE5Result wioE5SendConfirmedHex(const char* hex, uint32_t timeoutMs,
                                  WioE5UplinkInfo* info) {
  if (!wioE5Wake()) {
    return WioE5Result::kTimeout;
  }
  const uint32_t start = millis();
  drainUntilQuiet();
  char cmd[96];
  snprintf(cmd, sizeof(cmd), "AT+CMSGHEX=\"%s\"", hex);
  logTx(cmd);
  wioPort->print(cmd);
  wioPort->print("\r\n");
  WioE5UplinkInfo local{};
  const WioE5Result result = readUntilDone(
      "+CMSGHEX:", timeoutMs, WioE5Result::kNoAck,
      [&local](const char* body, WioE5Result& r) {
        if (strstr(body, "ACK Received") != nullptr) {
          r = WioE5Result::kOk;
        }
        int rssi = 0;
        float snr = 0.0f;
        // 例: "RXWIN1, RSSI -40, SNR 10.0"
        const char* p = strstr(body, "RSSI");
        if (p != nullptr && sscanf(p, "RSSI %d, SNR %f", &rssi, &snr) == 2) {
          local.hasRx = true;
          local.rssi = static_cast<int16_t>(rssi);
          local.snr = snr;
        }
        return false;
      });
  local.elapsedMs = millis() - start;
  if (info != nullptr) {
    *info = local;
  }
  Serial.printf("wio: uplink result=%s rssi=%d snr=%.1f elapsed_ms=%lu\n",
                wioE5ResultToString(result), local.hasRx ? local.rssi : 0,
                local.hasRx ? local.snr : 0.0f,
                static_cast<unsigned long>(local.elapsedMs));
  return result;
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
      // LoRaWAN MAC バージョン、LBT しきい値（日本の 920MHz 帯で必須のキャリアセンス）、
      // TX パラメータ（UplinkDwellTime / DownlinkDwellTime / MaxEIRP）。
      {"AT+LW=VER", "+LW:", false},       {"AT+LW=THLD", "+LW:", false},
      {"AT+LW=TPS", "+LW:", false},
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
