#define TINY_GSM_MODEM_SIM7080

#include "lte_modem_tls.h"

#include <Arduino.h>
#include <Preferences.h>
#include <string.h>

#include "config.h"

#if PSS_LTE_MODEM_TLS && PSS_MQTT_USE_TLS

extern const char awsRootCa[] asm("_binary_certs_AmazonRootCA1_pem_start");
extern const char deviceCert[] asm("_binary_certs_device_pem_crt_start");
extern const char privateKey[] asm("_binary_certs_private_pem_key_start");

constexpr char kPrefsNamespace[] = "pss_lte";
constexpr char kCertsOkKey[] = "certs_ok";
constexpr char kCaFileName[] = "aws_ca.pem";
constexpr char kClientCertFileName[] = "aws_dev.pem";
constexpr char kClientKeyFileName[] = "aws_dev.key";

namespace {

void drainModemStream(TinyGsm& modem) {
  while (modem.stream.available()) {
    modem.stream.read();
  }
}

bool writeModemFile(TinyGsm& modem, const char* name, const char* data,
                    size_t len) {
  Serial.printf("modem FS write %s (%u bytes)\n", name,
                static_cast<unsigned>(len));

  drainModemStream(modem);
  modem.sendAT(GF("+CFSTERM"));
  modem.waitResponse(5000L);
  modem.sendAT(GF("+CFSINIT"));
  if (modem.waitResponse(10000L) != 1) {
    Serial.println("modem CFSINIT failed before write");
    return false;
  }

  // SIM7080 FS note: CFSWFILE responds with DOWNLOAD (not OK first).
  // Timeout must be <= 10000 ms per AT manual.
  modem.sendAT(GF("+CFSWFILE=3,\""), name, GF("\",0,"), static_cast<uint16_t>(len),
               GF(",10000"));

  String response;
  const int8_t ready = modem.waitResponse(10000L, response, GF("DOWNLOAD"),
                                          GFP(GSM_ERROR), GF("+CME ERROR"));
  if (ready != 1) {
    Serial.printf("modem FS write no DOWNLOAD (ready=%d): %s\n", ready,
                  response.c_str());
    modem.sendAT(GF("+CFSTERM"));
    modem.waitResponse(5000L);
    return false;
  }

  modem.stream.write(reinterpret_cast<const uint8_t*>(data), len);
  modem.stream.flush();

  if (modem.waitResponse(10000L) != 1) {
    Serial.println("modem FS write failed (no OK after data)");
    modem.sendAT(GF("+CFSTERM"));
    modem.waitResponse(5000L);
    return false;
  }

  modem.sendAT(GF("+CFSTERM"));
  modem.waitResponse(5000L);
  return true;
}

bool convertRootCa(TinyGsm& modem) {
  Serial.printf("modem CA convert %s\n", kCaFileName);
  modem.sendAT(GF("+CSSLCFG=\"convert\",2,\""), kCaFileName, '"');
  if (modem.waitResponse(30000L) != 1) {
    Serial.println("modem CA convert failed");
    return false;
  }
  return true;
}

bool convertClientCert(TinyGsm& modem) {
  Serial.printf("modem client cert convert %s + %s\n", kClientCertFileName,
                kClientKeyFileName);
  modem.sendAT(GF("+CSSLCFG=\"convert\",1,\""), kClientCertFileName, GF("\",\""),
               kClientKeyFileName, '"');
  if (modem.waitResponse(30000L) != 1) {
    Serial.println(
        "modem client cert convert failed "
        "(try: openssl rsa -in private.pem.key -traditional -out aws_dev.key)");
    return false;
  }
  return true;
}

void deleteModemFile(TinyGsm& modem, const char* name) {
  modem.sendAT(GF("+CFSDFILE=3,\""), name, '"');
  modem.waitResponse(10000L);
}

}  // namespace

void clearLteModemCertificateCache() {
  Preferences prefs;
  prefs.begin(kPrefsNamespace, false);
  if (prefs.isKey(kCertsOkKey)) {
    prefs.remove(kCertsOkKey);
  }
  prefs.end();
}

bool provisionLteModemCertificates(TinyGsm& modem) {
#if PSS_LTE_FORCE_CERT_UPLOAD
  clearLteModemCertificateCache();
#endif

  Preferences prefs;
  prefs.begin(kPrefsNamespace, true);
  const bool cached = prefs.getBool(kCertsOkKey, false);
  prefs.end();
  if (cached) {
    Serial.println("modem TLS certs: skip upload (cached in NVS)");
    return true;
  }

  Serial.println("modem TLS certs: uploading to SIM7080 FS...");

  const size_t caLen = strlen(awsRootCa);
  const size_t certLen = strlen(deviceCert);
  const size_t keyLen = strlen(privateKey);
  if (caLen == 0 || certLen == 0 || keyLen == 0) {
    Serial.println("embedded TLS certs missing");
    return false;
  }

  if (!writeModemFile(modem, kCaFileName, awsRootCa, caLen) ||
      !writeModemFile(modem, kClientCertFileName, deviceCert, certLen) ||
      !writeModemFile(modem, kClientKeyFileName, privateKey, keyLen) ||
      !convertRootCa(modem) || !convertClientCert(modem)) {
    return false;
  }

  deleteModemFile(modem, kCaFileName);
  deleteModemFile(modem, kClientCertFileName);
  deleteModemFile(modem, kClientKeyFileName);

  prefs.begin(kPrefsNamespace, false);
  prefs.putBool(kCertsOkKey, true);
  prefs.end();

  Serial.println("modem TLS certs: provisioned");
  return true;
}

bool modemSslConnectAws(TinyGsm& modem, uint8_t mux, const char* host,
                        uint16_t remotePort, const char* caCertName,
                        const char* clientCertName, int timeout_s) {
  const uint32_t timeout_ms = static_cast<uint32_t>(timeout_s) * 1000U;

  modem.sendAT(GF("+CACID="), mux);
  if (modem.waitResponse(timeout_ms) != 1) {
    return false;
  }

  modem.sendAT(GF("+CSSLCFG=\"sslversion\",0,3"));
  if (modem.waitResponse(5000L) != 1) {
    return false;
  }

  modem.sendAT(GF("+CASSLCFG="), mux, ',', GF("\"SSL\","), 1);
  modem.waitResponse();

  modem.sendAT(GF("+CSSLCFG=\"ctxindex\",0"));
  if (modem.waitResponse(5000L, GF("+CSSLCFG:")) != 1) {
    return false;
  }
  while (modem.stream.available()) {
    const char c = static_cast<char>(modem.stream.read());
    if (c == '\n') {
      break;
    }
  }
  modem.waitResponse();

  if (caCertName != nullptr && caCertName[0] != '\0') {
    modem.sendAT(GF("+CASSLCFG="), mux, GF(",\"CACERT\",\""), caCertName, '"');
    if (modem.waitResponse(5000L) != 1) {
      return false;
    }
  }

  if (clientCertName != nullptr && clientCertName[0] != '\0') {
    modem.sendAT(GF("+CASSLCFG="), mux, GF(",\"CERT\",\""), clientCertName, '"');
    if (modem.waitResponse(5000L) != 1) {
      Serial.println("modem CERT config failed");
      return false;
    }
  }

  modem.sendAT(GF("+CSSLCFG=\"sni\",0,\""), host, '"');
  modem.waitResponse();

  modem.sendAT(GF("+CAOPEN="), mux, GF(",0,\"TCP\",\""), host, GF("\","),
               remotePort);
  if (modem.waitResponse(timeout_ms, GF("+CAOPEN:")) != 1) {
    return false;
  }

  while (modem.stream.available()) {
    const char c = static_cast<char>(modem.stream.peek());
    if (c == ',') {
      modem.stream.read();
      break;
    }
    modem.stream.read();
  }
  const int8_t result = static_cast<int8_t>(modem.stream.parseInt());
  while (modem.stream.available()) {
    const char c = static_cast<char>(modem.stream.read());
    if (c == '\n') {
      break;
    }
  }
  modem.waitResponse();
  if (result != 0) {
    Serial.printf("modem CAOPEN failed result=%d\n", result);
    return false;
  }
  return true;
}

const char* lteModemCaCertName() { return kCaFileName; }
const char* lteModemClientCertName() { return kClientCertFileName; }

#endif  // PSS_LTE_MODEM_TLS && PSS_MQTT_USE_TLS
