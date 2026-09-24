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
/// Card width is always "1/3 of the screen", regardless of how many devices
/// actually exist — 1 device is one small chip at its natural size, not a
/// stretched-out full-width card. Fewer than 3 devices pads out the row
/// with empty chip slots so it always reads as "3 fit here", and 4+ scrolls
/// horizontally at that same fixed width.
private struct DeviceCarousel: View {
    let devices: [DeviceSummary]

    private let spacing: CGFloat = 12
    private let cardHeight: CGFloat = 148
    private let visibleColumns: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = (geometry.size.width - spacing * (visibleColumns - 1)) / visibleColumns
            let emptySlots = max(0, Int(visibleColumns) - devices.count)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(devices) { device in
                        NavigationLink(value: device.deviceId) {
                            DeviceCard(device: device)
                                .frame(width: cardWidth, height: cardHeight)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(0..<emptySlots, id: \.self) { _ in
                        EmptyDeviceSlot()
                            .frame(width: cardWidth, height: cardHeight)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(height: cardHeight)
    }
}

/// Each device renders as a small "circuit board" tile — modeled on the
/// actual XIAO ESP32-S3 module this project uses: a gently gradient board
/// body with real castellated pads (gold-plated half-vias) down the left
/// and right edges, the way SMD modules are actually manufactured, instead
/// of a flat-color placeholder shape.
private struct DeviceCard: View {
    let device: DeviceSummary

    var body: some View {
        ZStack {
            ZStack {
                BoardBodyShape()
                    .fill(
                        LinearGradient(
                            colors: [device.status.color.opacity(0.20), device.status.color.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                CastellatedEdges(tone: .gold)
            }
            .clipShape(BoardBodyShape())
            .compositingGroup()

            BoardBodyShape()
                .stroke(device.status.color.opacity(0.75), lineWidth: 1.25)
            BoardBodyShape()
                .inset(by: 1.25)
                .stroke(.white.opacity(0.35), lineWidth: 0.75)

            VStack(spacing: 6) {
                Text(device.deviceId)
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                StatusBadge(status: device.status)

                Text(RelativeTime.string(from: device.lastSeen))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(device.isOffline ? Theme.warning : .secondary)

                if let bootStatus = device.bootStatus {
                    VStack(spacing: 1) {
                        Text("ブート \(bootStatus.bootCount)回")
                        Text("稼働 \(bootStatus.uptimeLabel)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 15)
        }
        .shadow(color: .black.opacity(0.14), radius: 7, x: 0, y: 4)
        .overlay(alignment: .topTrailing) {
            if device.isOffline {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(Theme.warning))
                    .offset(x: -2, y: 6)
            }
        }
    }
}

/// A dimmed, contentless board — fills out the row to 3 slots when there
/// aren't yet 3 devices, so it's visually obvious more fit here.
private struct EmptyDeviceSlot: View {
    var body: some View {
        ZStack {
            BoardBodyShape().fill(Color.primary.opacity(0.03))
            CastellatedEdges(tone: .muted)
        }
        .clipShape(BoardBodyShape())
        .compositingGroup()
        .overlay(
            BoardBodyShape().stroke(Color.primary.opacity(0.15), lineWidth: 1.25)
        )
        .opacity(0.6)
    }
}

/// The board's rounded-rectangle body — a plain, unbroken silhouette. Pins
/// protruding past this edge read as a bug's legs rather than a circuit
/// board (see `CastellatedEdges`'s doc comment), so the outline stays whole
/// and the pads live just inside it.
private struct BoardBodyShape: InsettableShape {
    var cornerRadius: CGFloat = 16
    private var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect.insetBy(dx: insetAmount, dy: insetAmount), cornerRadius: max(0, cornerRadius - insetAmount))
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// Realistic castellated pads (7 per side, matching the XIAO module) along
/// the left/right edges of `BoardBodyShape`: a gold-plated pad with a round
/// notch punched right at the board edge — the actual look of an SMD
/// module's half-plated-through-hole pins, not just a colored tab. The
/// notch is cut with `.destinationOut`, so it genuinely reveals whatever is
/// behind this view (the tile's own gradient background) rather than
/// painting a guessed background color over it.
private struct CastellatedEdges: View {
    var pinCount: Int = 7
    var cornerRadius: CGFloat = 16
    var tone: Tone = .gold

    enum Tone {
        case gold, muted

        var gradient: Gradient {
            switch self {
            case .gold:
                Gradient(colors: [Color(red: 0.97, green: 0.84, blue: 0.53), Color(red: 0.75, green: 0.57, blue: 0.20)])
            case .muted:
                Gradient(colors: [Color(white: 0.78), Color(white: 0.58)])
            }
        }
    }

    var body: some View {
        Canvas { context, size in
            let padWidth: CGFloat = 10
            let padHeight: CGFloat = 6.5
            let holeRadius: CGFloat = 3.2
            let cornerInset = min(cornerRadius, size.height / 2 - 1)
            let usableHeight = size.height - cornerInset * 2
            let spacing = usableHeight / CGFloat(pinCount)

            for index in 0..<pinCount {
                let centerY = cornerInset + spacing * (CGFloat(index) + 0.5)

                for isLeftEdge in [true, false] {
                    let padRect = isLeftEdge
                        ? CGRect(x: 0, y: centerY - padHeight / 2, width: padWidth, height: padHeight)
                        : CGRect(x: size.width - padWidth, y: centerY - padHeight / 2, width: padWidth, height: padHeight)
                    let padPath = Path(roundedRect: padRect, cornerRadius: 1.5)

                    context.fill(
                        padPath,
                        with: .linearGradient(
                            tone.gradient,
                            startPoint: CGPoint(x: padRect.midX, y: padRect.minY),
                            endPoint: CGPoint(x: padRect.midX, y: padRect.maxY)
                        )
                    )
                    context.stroke(padPath, with: .color(.black.opacity(0.2)), lineWidth: 0.5)

                    let edgeX = isLeftEdge ? 0 : size.width
                    let holeRect = CGRect(x: edgeX - holeRadius, y: centerY - holeRadius, width: holeRadius * 2, height: holeRadius * 2)
                    context.blendMode = .destinationOut
                    context.fill(Path(ellipseIn: holeRect), with: .color(.black))
                    context.blendMode = .normal
                }
            }
        }
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
