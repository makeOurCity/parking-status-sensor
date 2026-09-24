import SwiftUI

struct DashboardView: View {
    @ObservedObject private var auth: CognitoAuthService
    @StateObject private var viewModel: DashboardViewModel
    @Environment(\.scenePhase) private var scenePhase

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
                    } else {
                        DeviceCarousel(devices: viewModel.devices)
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
            .autoRefreshing(scenePhase: scenePhase) {
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

/// Horizontal, swipeable row of device cards. Sized so up to 3 devices fill
/// exactly one screen width with no scrolling — a 4th+ device scrolls in at
/// that same width instead of the section growing taller, so "デバイス"
/// stays a fixed height regardless of fleet size and "直近のログ" below it
/// never gets pushed further down.
private struct DeviceCarousel: View {
    let devices: [DeviceSummary]

    private let spacing: CGFloat = 12
    private let cardHeight: CGFloat = 148

    var body: some View {
        GeometryReader { geometry in
            let columns = CGFloat(min(max(devices.count, 1), 3))
            let cardWidth = (geometry.size.width - spacing * (columns - 1)) / columns

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(devices) { device in
                        NavigationLink(value: device.deviceId) {
                            DeviceCard(device: device)
                                .frame(width: cardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(height: cardHeight)
    }
}

private struct DeviceCard: View {
    let device: DeviceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZStack {
                    Circle().fill(device.status.color.opacity(0.15))
                    Image(systemName: device.status.icon)
                        .foregroundStyle(device.status.color)
                        .font(.callout)
                }
                .frame(width: 30, height: 30)

                Spacer()

                if device.isOffline {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.caption2)
                }
            }

            Text(device.deviceId)
                .font(.caption.weight(.semibold).monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.primary)

            StatusBadge(status: device.status)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(RelativeTime.string(from: device.lastSeen))
                    .font(.caption2)
                    .foregroundStyle(device.isOffline ? Theme.warning : .secondary)

                if let bootStatus = device.bootStatus {
                    Label("\(bootStatus.bootCount)回・\(bootStatus.uptimeLabel)", systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
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

private struct LogCard: View {
    let entry: LogEntry
    @State private var showRawLog = false

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
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showRawLog ? 0 : -90))
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
                if showRawLog {
                    Text(entry.formattedRawLog)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) { showRawLog.toggle() }
        }
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
