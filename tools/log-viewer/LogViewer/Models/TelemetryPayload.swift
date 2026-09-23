import SwiftUI

struct RawColorReading: Decodable {
    let red: Int
    let green: Int
    let blue: Int
    let clear: Int

    /// Rough hue preview normalized by the brightest channel. Not colorimetrically
    /// accurate — just enough to eyeball red(満)/green(空) at a glance.
    var previewColor: Color {
        let maxComponent = Double(max(red, max(green, blue), 1))
        return Color(
            red: Double(red) / maxComponent,
            green: Double(green) / maxComponent,
            blue: Double(blue) / maxComponent
        )
    }
}

/// The JSON telemetry payload embedded in each log line (docs/data-model.md).
/// Only the fields the dashboard/detail views actually show are decoded;
/// `power` / `network` / `sync` / `bootMode` / `pot` are ignored here.
struct TelemetryPayload: Decodable {
    let raw: RawColorReading?
    let threshold: Int?
    let determinedBy: String?
}

extension LogEntry {
    /// Best-effort parse of the JSON payload embedded in the raw log line
    /// (everything from the first `{` onward — the Lambda log line prefixes
    /// it with `[INFO]\t<timestamp>\t<requestId>\t...`). Returns nil for log
    /// lines that don't carry the usual telemetry shape (e.g. early test
    /// payloads without `raw`/`threshold`).
    var telemetry: TelemetryPayload? {
        guard let braceIndex = message.firstIndex(of: "{"),
              let data = message[braceIndex...].data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(TelemetryPayload.self, from: data)
    }

    /// A readable rendering of the raw log line for the "show raw log"
    /// disclosure: the Lambda-added prefix (timestamp/request id) on its own
    /// de-emphasized line, then the JSON payload indented and key-sorted
    /// instead of the single unbroken line CloudWatch stores. Falls back to
    /// the untouched message if the payload isn't parseable JSON.
    var formattedRawLog: String {
        guard let braceIndex = message.firstIndex(of: "{") else { return message }

        let prefix = message[..<braceIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\t", with: "  ")
        let jsonPart = message[braceIndex...]

        guard let data = jsonPart.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let prettyJSON = String(data: prettyData, encoding: .utf8)
        else {
            return message
        }

        return prefix.isEmpty ? prettyJSON : "\(prefix)\n\n\(prettyJSON)"
    }
}
