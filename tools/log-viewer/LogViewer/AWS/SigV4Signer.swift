import CryptoKit
import Foundation

/// Minimal AWS Signature Version 4 signer for a single service (CloudWatch Logs).
///
/// Cognito's own APIs (InitiateAuth, GetId, GetCredentialsForIdentity) are public,
/// unsigned operations — only CloudWatch Logs calls need this. Implemented directly
/// against the documented SigV4 algorithm instead of pulling in the full AWS SDK for
/// Swift, which would be a heavy dependency for a single-user PoC tool.
struct SigV4Signer {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    let region: String
    let service: String

    func sign(request: inout URLRequest, payload: Data, date: Date = Date()) {
        guard let url = request.url, let host = url.host else { return }

        let (amzDate, dateStamp) = Self.formattedDates(date)
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        var headersToSign: [String: String] = [
            "host": host,
            "x-amz-date": amzDate,
            "content-type": request.value(forHTTPHeaderField: "Content-Type") ?? "",
            "x-amz-target": request.value(forHTTPHeaderField: "X-Amz-Target") ?? "",
        ]
        if let sessionToken {
            headersToSign["x-amz-security-token"] = sessionToken
        }

        let signedHeaderNames = headersToSign.keys.sorted()
        let canonicalHeaders = signedHeaderNames.map { "\($0):\(headersToSign[$0]!)\n" }.joined()
        let signedHeaders = signedHeaderNames.joined(separator: ";")

        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            Self.sha256Hex(payload),
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secretAccessKey: secretAccessKey, dateStamp: dateStamp, region: region, service: service)
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private static func formattedDates(_ date: Date) -> (amzDate: String, dateStamp: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        return (amzDate, String(amzDate.prefix(8)))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hmacHex(key: Data, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signingKey(secretAccessKey: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }
}
