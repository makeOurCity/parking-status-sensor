import SwiftUI

struct DashboardView: View {
    @ObservedObject private var auth: CognitoAuthService
    @StateObject private var viewModel: DashboardViewModel

    init(auth: CognitoAuthService) {
        self.auth = auth
        _viewModel = StateObject(wrappedValue: DashboardViewModel(auth: auth))
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("デバイス（\(viewModel.devices.count)台）") {
                    if viewModel.devices.isEmpty && !viewModel.isLoading {
                        Text("データがありません")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.devices) { device in
                        NavigationLink(value: device.deviceId) {
                            DeviceRow(device: device)
                        }
                    }
                }

                Section("直近のログ") {
                    if viewModel.recentLogs.isEmpty && !viewModel.isLoading {
                        Text("データがありません")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.recentLogs) { entry in
                        LogRow(entry: entry)
                    }
                }
            }
            .navigationTitle("ダッシュボード")
            .navigationDestination(for: String.self) { deviceId in
                DeviceDetailView(deviceId: deviceId, auth: auth)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Button("サインアウト", role: .destructive) {
                            auth.signOut()
                        }
                    }
                }
            }
            .refreshable {
                await viewModel.load()
            }
            .task {
                await viewModel.load()
            }
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.deviceId)
                    .font(.body.monospaced())
                Text("最終受信: \(RelativeTime.string(from: device.lastSeen))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if device.isOffline {
                Label("オフライン", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
            }

            StatusBadge(status: device.status)
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.deviceId ?? "unknown")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(RelativeTime.string(from: entry.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let status = entry.status {
                    StatusBadge(status: status)
                }
                Text(entry.message)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: DeviceOperationalStatus

    var body: some View {
        Text(status.label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.2))
            .foregroundStyle(status.color)
            .clipShape(Capsule())
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}
