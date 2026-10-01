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

    /// True for reset reasons that mean the device just came back from a
    /// real reset — not a routine deep-sleep wake. These are the entries
    /// worth a second look (e.g. `brownout`), so views can call them out.
    var isNotableReset: Bool {
        resetReason != nil && resetReason != "deep_sleep"
    }

    /// Full-length label for contexts with room to spare (device detail).
    /// firmware/src/main.cpp: resetReasonToString(esp_reset_reason_t).
    var resetReasonLabel: String? {
        guard let resetReason else { return nil }
        switch resetReason {
        case "power_on": return "電源投入"
        case "brownout": return "電圧低下（ブラウンアウト）"
        case "deep_sleep": return "ディープスリープ復帰"
        case "software": return "ソフトウェアリセット"
        case "panic": return "パニック（クラッシュ）"
        case "task_wdt": return "タスクウォッチドッグ"
        case "int_wdt": return "割り込みウォッチドッグ"
        case "wdt": return "ウォッチドッグ"
        case "other": return "その他"
        default: return resetReason
        }
    }

    /// Compact label for space-constrained contexts (dashboard recent logs).
    var shortResetReasonLabel: String? {
        guard let resetReason else { return nil }
        switch resetReason {
        case "power_on": return "電源"
        case "brownout": return "電圧低下"
        case "deep_sleep": return "スリープ"
        case "software": return "SW"
        case "panic": return "パニック"
        case "task_wdt", "int_wdt", "wdt": return "WDT"
        case "other": return "他"
        default: return resetReason
        }
    }
}

/// LoRaWAN-only link quality, from `network` in the bridge-normalized JSON
/// (bridge/lorawan.py). LTE-M / Wi-Fi payloads carry none of these keys, so
/// every field is optional and `hasLinkMetrics` is false for them.
struct NetworkInfo: Decodable {
    let transport: String?
    let rssi: Int?
    let snr: Double?
    let dataRate: Int?
    let fCnt: Int?

    var hasLinkMetrics: Bool {
        rssi != nil || snr != nil || dataRate != nil || fCnt != nil
    }
}

/// The JSON telemetry payload embedded in each log line (docs/data-model.md).
/// Only the fields the dashboard/detail views actually show are decoded;
/// `sync` / `bootMode` / `pot` / `lorawan` are ignored here.
struct TelemetryPayload: Decodable {
    let raw: RawColorReading?
    let threshold: Int?
    let determinedBy: String?
    let power: PowerInfo?
    let network: NetworkInfo?

    private enum CodingKeys: String, CodingKey {
        case raw, threshold, determinedBy, power, network
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        raw = try container.decodeIfPresent(RawColorReading.self, forKey: .raw)
        threshold = try container.decodeIfPresent(Int.self, forKey: .threshold)
        determinedBy = try container.decodeIfPresent(String.self, forKey: .determinedBy)
        power = try container.decodeIfPresent(PowerInfo.self, forKey: .power)
        // `network` is purely additive: a shape this app doesn't expect must
        // not take down the color / power rows that already worked.
        network = try? container.decodeIfPresent(NetworkInfo.self, forKey: .network)
    }
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
