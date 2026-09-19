import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("表示色") {
                    ColorPicker("満（赤）", selection: $settings.fullColor, supportsOpacity: false)
                    ColorPicker("空（緑）", selection: $settings.emptyColor, supportsOpacity: false)
                }
                Section {
                    Button("初期値に戻す", role: .destructive) {
                        settings.resetToDefaults()
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView(settings: SettingsStore())
}
