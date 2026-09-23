import SwiftUI

struct DashboardView: View {
    @ObservedObject private var auth: CognitoAuthService
    @StateObject private var viewModel: DashboardViewModel

    init(auth: CognitoAuthService) {
        self.auth = auth
        _viewModel = StateObject(wrappedValue: DashboardViewModel(auth: auth))
    }

    private var onlineCount: Int { viewModel.devices.filter { !$0.isOffline }.count }
    private var offlineCount: Int { viewModel.devices.filter(\.isOffline).count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(Theme.full)
                            .cardStyle()
                    }

                    HStack(spacing: 12) {
                        StatTile(value: "\(viewModel.devices.count)", label: "デバイス", color: Theme.accent, icon: "sensor.fill")
                        StatTile(value: "\(onlineCount)", label: "稼働中", color: Theme.available, icon: "antenna.radiowaves.left.and.right")
                        StatTile(value: "\(offlineCount)", label: "オフライン", color: offlineCount > 0 ? Theme.warning : Theme.unknown, icon: "wifi.slash")
                    }

                    SectionHeader(title: "デバイス")
                    if viewModel.devices.isEmpty && !viewModel.isLoading {
                        EmptyStateCard(text: "データがありません")
                    }
                    VStack(spacing: 12) {
                        ForEach(viewModel.devices) { device in
                            NavigationLink(value: device.deviceId) {
                                DeviceCard(device: device)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    SectionHeader(title: "直近のログ")
                    if viewModel.recentLogs.isEmpty && !viewModel.isLoading {
                        EmptyStateCard(text: "データがありません")
                    }
                    VStack(spacing: 12) {
                        ForEach(viewModel.recentLogs) { entry in
                            LogCard(entry: entry)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ダッシュボード")
            .navigationDestination(for: String.self) { deviceId in
                DeviceDetailView(deviceId: deviceId, auth: auth)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Button(role: .destructive) {
                            auth.signOut()
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
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
        .tint(Theme.accent)
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .fontDesign(.rounded)
    }
}

private struct EmptyStateCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .cardStyle()
    }
}

private struct DeviceCard: View {
    let device: DeviceSummary

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(device.status.color.opacity(0.15))
                Image(systemName: device.status.icon)
                    .foregroundStyle(device.status.color)
                    .font(.title3)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.deviceId)
                    .font(.callout.weight(.semibold).monospaced())
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if device.isOffline {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .font(.caption2)
                    }
                    Text("最終受信 \(JSTTime.shortDateTimeFormatter.string(from: device.lastSeen))（\(RelativeTime.string(from: device.lastSeen))）")
                        .font(.caption)
                        .foregroundStyle(device.isOffline ? Theme.warning : .secondary)
                }
            }

            Spacer()

            StatusBadge(status: device.status)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }
}

private struct LogCard: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill((entry.status?.color ?? Theme.unknown).opacity(0.7))
                .frame(width: 3)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.deviceId ?? "unknown")
                        .font(.caption.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(JSTTime.shortDateTimeFormatter.string(from: entry.timestamp))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    if let status = entry.status {
                        StatusBadge(status: status)
                    }
                    if let telemetry = entry.telemetry {
                        TelemetryDetailsView(telemetry: telemetry, style: .compact)
                    } else {
                        Text(entry.message)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.trailing, 14)
        .padding(.leading, 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct StatusBadge: View {
    let status: DeviceOperationalStatus

    var body: some View {
        Label(status.label, systemImage: status.icon)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.16))
            .foregroundStyle(status.color)
            .clipShape(Capsule())
    }
}
