import SwiftUI

enum SignState {
    case full
    case empty

    var bitmap: [[Bool]] {
        switch self {
        case .full: return SignPattern.full
        case .empty: return SignPattern.empty
        }
    }
}

struct ContentView: View {
    @StateObject private var settings = SettingsStore()
    @State private var state: SignState = .empty
    @State private var isShowingSettings = false

    var body: some View {
        GeometryReader { geometry in
            let panelSize = min(geometry.size.width, geometry.size.height) * 0.92

            ZStack {
                Color.black.ignoresSafeArea()

                DotMatrixView(
                    bitmap: state.bitmap,
                    onColor: state == .full ? settings.fullColor : settings.emptyColor,
                    offColor: Color(white: 0.08)
                )
                .frame(width: panelSize, height: panelSize)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                state = (state == .full) ? .empty : .full
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding()
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(settings: settings)
        }
    }
}

#Preview {
    ContentView()
}
