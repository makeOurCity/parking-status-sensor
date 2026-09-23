import Foundation

enum CloudWatchLogsError: LocalizedError {
    case malformedResponse
    case apiError(String)
    case queryFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .malformedResponse: return "CloudWatch Logsから予期しない応答がありました。"
        case .apiError(let message): return message
        case .queryFailed(let status): return "クエリが失敗しました（\(status)）。"
        case .timedOut: return "クエリがタイムアウトしました。"
        }
    }
}

/// Reads the parking-status Lambda bridge's CloudWatch Logs via Logs Insights.
///
/// This is the *only* real data source right now — Lambda (`bridge/handler.py`) is
/// still a stub (Issue #7 not yet implemented), so there is no Orion state to read
/// instead. See docs/ios-app-cognito.md and docs/iot-core.md.
struct CloudWatchLogsService {
    let auth: CognitoAuthService

    private static let logRecordFilter = "telemetry received"
    private static let deviceIdParse = #"parse @message /"deviceId":\s*"(?<deviceId>[^"]+)"/"#
    private static let statusParse = #"parse @message /"status":\s*"(?<status>[^"]+)"/"#

    // MARK: - Public queries

    /// Current status + last-received time for every device seen within `lookback`.
    /// One row per device, thanks to `stats ... by deviceId`.
    func fetchDeviceSummaries(lookback: TimeInterval = 3 * 24 * 3600) async throws -> [DeviceSummary] {
        let query = """
        fields @timestamp, @message
        | filter @message like /\(Self.logRecordFilter)/
        | \(Self.deviceIdParse)
        | parse @message /"status":\\s*"(?<rawStatus>[^"]+)"/
        | stats latest(@timestamp) as lastSeen, latest(rawStatus) as currentStatus by deviceId
        """
        let rows = try await runQuery(query, lookback: lookback)
        return rows.compactMap { row -> DeviceSummary? in
            guard let deviceId = row["deviceId"],
                  let lastSeenMs = row["lastSeen"].flatMap(Double.init)
            else { return nil }
            let status = row["currentStatus"].flatMap(DeviceOperationalStatus.init(rawValue:)) ?? .unknown
            return DeviceSummary(deviceId: deviceId, status: status, lastSeen: Date(timeIntervalSince1970: lastSeenMs / 1000))
        }
        .sorted { $0.deviceId < $1.deviceId }
    }

    /// Most recent N telemetry log lines across all devices.
    func fetchRecentLogs(limit: Int = 5, lookback: TimeInterval = 3 * 24 * 3600) async throws -> [LogEntry] {
        let query = """
        fields @timestamp, @message
        | filter @message like /\(Self.logRecordFilter)/
        | \(Self.deviceIdParse)
        | \(Self.statusParse)
        | sort @timestamp desc
        | limit \(limit)
        """
        let rows = try await runQuery(query, lookback: lookback)
        return rows.compactMap(LogEntry.init(row:))
    }

    /// All telemetry log lines for a single device, newest first.
    func fetchDeviceLogs(deviceId: String, limit: Int = 200, lookback: TimeInterval = 14 * 24 * 3600) async throws -> [LogEntry] {
        let safeDeviceId = deviceId.replacingOccurrences(of: "\"", with: "")
        let query = """
        fields @timestamp, @message
        | filter @message like /\(Self.logRecordFilter)/
        | \(Self.deviceIdParse)
        | \(Self.statusParse)
        | filter deviceId = "\(safeDeviceId)"
        | sort @timestamp desc
        | limit \(limit)
        """
        let rows = try await runQuery(query, lookback: lookback)
        return rows.compactMap(LogEntry.init(row:))
    }

    // MARK: - Logs Insights plumbing

    private func runQuery(_ queryString: String, lookback: TimeInterval) async throws -> [[String: String]] {
        let end = Date()
        let start = end.addingTimeInterval(-lookback)
        let credentials = try await auth.credentialsForCloudWatch()

        let queryId = try await startQuery(queryString: queryString, start: start, end: end, credentials: credentials)
        return try await pollResults(queryId: queryId, credentials: credentials)
    }

    private func startQuery(queryString: String, start: Date, end: Date, credentials: AWSTemporaryCredentials) async throws -> String {
        let body: [String: Any] = [
            "logGroupName": AWSConfig.logGroupName,
            "startTime": Int(start.timeIntervalSince1970),
            "endTime": Int(end.timeIntervalSince1970),
            "queryString": queryString,
        ]
        let response = try await call(action: "StartQuery", body: body, credentials: credentials)
        guard let queryId = response["queryId"] as? String else {
            throw CloudWatchLogsError.malformedResponse
        }
        return queryId
    }

    private func pollResults(queryId: String, credentials: AWSTemporaryCredentials) async throws -> [[String: String]] {
        for _ in 0..<20 {
            let response = try await call(action: "GetQueryResults", body: ["queryId": queryId], credentials: credentials)
            let status = response["status"] as? String ?? ""
            switch status {
            case "Complete":
                let rawResults = response["results"] as? [[[String: Any]]] ?? []
                return rawResults.map(Self.flatten(row:))
            case "Failed", "Cancelled", "Timeout":
                throw CloudWatchLogsError.queryFailed(status)
            default:
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw CloudWatchLogsError.timedOut
    }

    private static func flatten(row: [[String: Any]]) -> [String: String] {
        var dict: [String: String] = [:]
        for field in row {
            if let name = field["field"] as? String, let value = field["value"] as? String {
                dict[name] = value
            }
        }
        return dict
    }

    private func call(action: String, body: [String: Any], credentials: AWSTemporaryCredentials) async throws -> [String: Any] {
        let url = URL(string: "https://logs.\(AWSConfig.region).amazonaws.com/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("Logs_20140328.\(action)", forHTTPHeaderField: "X-Amz-Target")

        let payload = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = payload

        let signer = SigV4Signer(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretKey,
            sessionToken: credentials.sessionToken,
            region: AWSConfig.region,
            service: "logs"
        )
        signer.sign(request: &request, payload: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CloudWatchLogsError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (json["message"] as? String) ?? (json["__type"] as? String) ?? "HTTP \(http.statusCode)"
            throw CloudWatchLogsError.apiError(message)
        }
        return json
    }
}
