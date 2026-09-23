import SwiftUI

struct DeviceDetailView: View {
    @StateObject private var viewModel: DeviceDetailViewModel

    init(deviceId: String, auth: CognitoAuthService) {
        _viewModel = StateObject(wrappedValue: DeviceDetailViewModel(deviceId: deviceId, auth: auth))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(Theme.full)
                        .cardStyle()
                }

                if viewModel.logs.isEmpty && !viewModel.isLoading {
                    Text("ログがありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .cardStyle()
                }

                ForEach(viewModel.logs) { entry in
                    LogDetailCard(entry: entry)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(viewModel.deviceId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.isLoading {
                    ProgressView()
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

private struct LogDetailCard: View {
    let entry: LogEntry
    @State private var showRawLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(JSTTime.dateTimeFormatter.string(from: entry.timestamp))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                Spacer()
                if let status = entry.status {
                    StatusBadge(status: status)
                }
            }

            if let telemetry = entry.telemetry {
                TelemetryDetailsView(telemetry: telemetry, style: .full)
            } else {
                Text("色・閾値の情報がないログです")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                withAnimation(.snappy) { showRawLog.toggle() }
            } label: {
                Label(showRawLog ? "生ログを隠す" : "生ログを表示", systemImage: "chevron.forward")
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
                    .rotationEffect(.degrees(showRawLog ? 90 : 0))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showRawLog {
                Text(entry.message)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .cardStyle()
    }
}
