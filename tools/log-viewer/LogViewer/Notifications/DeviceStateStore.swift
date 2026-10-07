import Foundation

/// What we remember about a device between checks, to detect changes.
struct DeviceStateSnapshot: Codable, Equatable {
    let status: String
    let isOffline: Bool
}

/// Pure diffing logic, kept separate from persistence so it's easy to verify
/// in isolation (no UserDefaults/Keychain involved).
enum DeviceStateDiff {
    /// Human-readable change descriptions. A device with no prior snapshot
    /// entry (first time we've ever seen it) is skipped — otherwise every
    /// device would "change" on the very first background check.
    static func changes(previous: [String: DeviceStateSnapshot], current: [DeviceSummary]) -> [String] {
        var messages: [String] = []
        for device in current {
            guard let prev = previous[device.deviceId] else { continue }

            // `available` saved by an older app version is the same state as `open` (#99).
            let prevStatus = DeviceOperationalStatus.parse(prev.status)
            if prevStatus != device.status {
                let prevLabel = prevStatus?.label ?? prev.status
                messages.append("\(device.title): \(prevLabel) → \(device.status.label)")
            }
            if !prev.isOffline && device.isOffline {
                messages.append("\(device.title): オフラインになりました")
            } else if prev.isOffline && !device.isOffline {
                messages.append("\(device.title): オンラインに復帰しました")
            }
        }
        return messages
    }

    static func snapshot(from devices: [DeviceSummary]) -> [String: DeviceStateSnapshot] {
        Dictionary(uniqueKeysWithValues: devices.map {
            ($0.deviceId, DeviceStateSnapshot(status: $0.status.rawValue, isOffline: $0.isOffline))
        })
    }
}

/// UserDefaults-backed persistence of the last-known device states, used to
/// detect changes across background refreshes (and app relaunches).
enum DeviceStateStore {
    private static let defaultsKey = "backgroundRefresh.lastKnownDeviceStates"

    static func loadSnapshot() -> [String: DeviceStateSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode([String: DeviceStateSnapshot].self, from: data)
        else { return [:] }
        return snapshot
    }

    static func save(_ snapshot: [String: DeviceStateSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Compares freshly-fetched devices against the last known snapshot,
    /// persists the new snapshot, and returns change descriptions (empty if
    /// nothing changed or this is the first-ever check).
    @discardableResult
    static func detectChangesAndUpdate(devices: [DeviceSummary]) -> [String] {
        let previous = loadSnapshot()
        let changes = DeviceStateDiff.changes(previous: previous, current: devices)
        save(DeviceStateDiff.snapshot(from: devices))
        return changes
    }

    /// Same as `detectChangesAndUpdate`, but also posts a local notification
    /// when something changed. Shared by both the foreground auto-refresh
    /// loop and the background refresh task, so a status flip is caught
    /// (and reported the same way) regardless of which one happens to run.
    static func detectChangesAndNotify(devices: [DeviceSummary]) async {
        let changes = detectChangesAndUpdate(devices: devices)
        guard !changes.isEmpty else { return }
        await NotificationSender.send(
            title: "駐車場センサ: 状態が変化しました",
            body: changes.joined(separator: "\n")
        )
    }
}
