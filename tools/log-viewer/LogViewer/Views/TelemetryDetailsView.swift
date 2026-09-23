import SwiftUI

/// Shows the color reading + threshold from a telemetry payload. Used both as
/// a compact one-line summary (dashboard log rows) and a bigger card (device
/// detail rows).
struct TelemetryDetailsView: View {
    enum Style {
        case compact
        case full
    }

    let telemetry: TelemetryPayload
    var style: Style = .full

    var body: some View {
        switch style {
        case .compact:
            HStack(spacing: 6) {
                if let raw = telemetry.raw {
                    ColorSwatch(color: raw.previewColor, size: 12)
                    Text("R\(raw.red) G\(raw.green) B\(raw.blue) C\(raw.clear)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let threshold = telemetry.threshold {
                    Text("閾値\(threshold)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .full:
            HStack(alignment: .top, spacing: 12) {
                if let raw = telemetry.raw {
                    ColorSwatch(color: raw.previewColor, size: 28)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let raw = telemetry.raw {
                        Text("R \(raw.red)　G \(raw.green)　B \(raw.blue)　Clear \(raw.clear)")
                            .font(.caption.monospaced())
                    }
                    HStack(spacing: 12) {
                        if let threshold = telemetry.threshold {
                            Label("閾値 \(threshold)", systemImage: "slider.horizontal.3")
                        }
                        if let determinedBy = telemetry.determinedBy {
                            Label(determinedBy, systemImage: "cpu")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ColorSwatch: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 0.5))
    }
}
