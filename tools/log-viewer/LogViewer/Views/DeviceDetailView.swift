import SwiftUI

struct DeviceDetailView: View {
    @StateObject private var viewModel: DeviceDetailViewModel

    init(deviceId: String, auth: CognitoAuthService) {
        _viewModel = StateObject(wrappedValue: DeviceDetailViewModel(deviceId: deviceId, auth: auth))
    }

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if viewModel.logs.isEmpty && !viewModel.isLoading {
                Text("ログがありません")
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.logs) { entry in
                LogDetailRow(entry: entry)
            }
        }
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

private struct LogDetailRow: View {
    let entry: LogEntry
    @State private var showRawLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(JSTTime.dateTimeFormatter.string(from: entry.timestamp))
                    .font(.subheadline.monospacedDigit())
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

            DisclosureGroup("生ログを表示", isExpanded: $showRawLog) {
                Text(entry.message)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }
}
