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

/// `bootCount` lives in ESP32 RTC memory (firmware/src/main.cpp): it survives
/// deep sleep and increments by 1 on every boot — including plain deep-sleep
/// timer wakes, not just power-on resets — but resets to 0 (so the next boot
/// reports 1) on a genuine power-on/brownout/hard reset. So "bootCount == 1"
/// always marks the first telemetry send after the device's most recent hard
/// reset, and `resetReason`/`wakeCause` at that same entry explain why it
/// happened (power_on, brownout, panic, watchdog, ...).
struct PowerInfo: Decodable {
    let bootCount: Int?
    let wakeCause: String?
    let resetReason: String?
}

/// The JSON telemetry payload embedded in each log line (docs/data-model.md).
/// Only the fields the dashboard/detail views actually show are decoded;
/// `network` / `sync` / `bootMode` / `pot` are ignored here.
struct TelemetryPayload: Decodable {
    let raw: RawColorReading?
    let threshold: Int?
    let determinedBy: String?
    let power: PowerInfo?
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
