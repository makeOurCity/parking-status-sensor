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
                if let power = telemetry.power {
                    if let bootCount = power.bootCount {
                        Text("#\(bootCount)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let label = power.shortResetReasonLabel {
                        Text(label)
                            .font(.caption2.weight(power.isNotableReset ? .bold : .regular))
                            .foregroundStyle(power.isNotableReset ? Theme.warning : .secondary)
                    }
                }
            }
        case .full:
            HStack(alignment: .top, spacing: 14) {
                if let raw = telemetry.raw {
                    ColorSwatch(color: raw.previewColor, size: 40, glow: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let raw = telemetry.raw {
                        HStack(spacing: 6) {
                            ValueChip(label: "R", value: "\(raw.red)")
                            ValueChip(label: "G", value: "\(raw.green)")
                            ValueChip(label: "B", value: "\(raw.blue)")
                            ValueChip(label: "Clear", value: "\(raw.clear)")
                        }
                    }
                    HStack(spacing: 10) {
                        if let threshold = telemetry.threshold {
                            Label("閾値 \(threshold)", systemImage: "slider.horizontal.3")
                        }
                        if let determinedBy = telemetry.determinedBy {
                            Label(determinedBy, systemImage: "cpu")
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                    if let power = telemetry.power {
                        HStack(spacing: 10) {
                            if let bootCount = power.bootCount {
                                Label("ブート \(bootCount)回", systemImage: "arrow.clockwise")
                                    .foregroundStyle(.secondary)
                            }
                            if let label = power.resetReasonLabel {
                                Label(label, systemImage: "bolt.fill")
                                    .foregroundStyle(power.isNotableReset ? Theme.warning : .secondary)
                                    .fontWeight(power.isNotableReset ? .bold : .regular)
                            }
                        }
                        .font(.caption2.weight(.medium))
                    }

                    if let network = telemetry.network, network.hasLinkMetrics {
                        HStack(spacing: 10) {
                            if let rssi = network.rssi {
                                Label("RSSI \(rssi)", systemImage: "antenna.radiowaves.left.and.right")
                            }
                            if let snr = network.snr {
                                Text("SNR \(snr, specifier: "%.1f")")
                            }
                            if let dataRate = network.dataRate {
                                Text("DR\(dataRate)")
                            }
                            if let fCnt = network.fCnt {
                                Text("FCnt \(fCnt)")
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct ColorSwatch: View {
    let color: Color
    let size: CGFloat
    var glow: Bool = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0.75)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 1.4
                )
            )
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
            .shadow(color: glow ? color.opacity(0.5) : .clear, radius: glow ? 8 : 0)
    }
}

private struct ValueChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.caption2.monospaced().weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}
