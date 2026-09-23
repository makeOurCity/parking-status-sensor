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

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.absoluteFormatter.string(from: entry.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = entry.status {
                    StatusBadge(status: status)
                }
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
