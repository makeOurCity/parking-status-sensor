#pragma once

#include "config.h"

#if PSS_LTE_MODEM_TLS

#include <TinyGsmClient.h>
#include <stdint.h>

// SIM7080 modem-side TLS (replaces ESP32 SSLClient over UART for LTE).
bool provisionLteModemCertificates(TinyGsm& modem);
void clearLteModemCertificateCache();

const char* lteModemCaCertName();
const char* lteModemClientCertName();

bool modemSslConnectAws(TinyGsm& modem, uint8_t mux, const char* host,
                        uint16_t remotePort, const char* caCertName,
                        const char* clientCertName, int timeout_s);

class AwsLteSecureClient : public TinyGsmClientSecure {
 public:
  explicit AwsLteSecureClient(TinyGsm& modem, uint8_t mux = 0)
      : TinyGsmClientSecure(modem, mux) {}

  void setCaCert(const char* caCertName) { caCertName_ = caCertName; }
  void setMtlsClientCert(const char* clientCertName) {
    clientCertName_ = clientCertName;
  }

  int connect(const char* host, uint16_t port, int timeout_s) override {
    stop();
    TINY_GSM_YIELD();
    rx.clear();
    sock_connected = modemSslConnectAws(*at, mux, host, port, caCertName_,
                                        clientCertName_, timeout_s);
    return sock_connected ? 1 : 0;
  }

 private:
  const char* caCertName_ = nullptr;
  const char* clientCertName_ = nullptr;
};

#endif  // PSS_LTE_MODEM_TLS
