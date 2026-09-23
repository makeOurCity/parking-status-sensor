import SwiftUI

/// Shared visual language for the dashboard — a small "ops console" palette
/// layered on top of system colors so it still adapts to light/dark mode.
enum Theme {
    static let accent = Color(red: 0.36, green: 0.42, blue: 0.98) // indigo
    static let full = Color(red: 1.00, green: 0.36, blue: 0.42) // coral
    static let available = Color(red: 0.20, green: 0.84, blue: 0.60) // mint
    static let unknown = Color(red: 0.62, green: 0.65, blue: 0.71) // slate
    static let warning = Color(red: 0.96, green: 0.62, blue: 0.13) // amber

    static let cardCornerRadius: CGFloat = 18
}

/// A flat, softly-elevated surface used for every card in the app instead of
/// the default List row background — this is what gives the "console" feel
/// instead of a stock Settings-style list.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
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

extension View {
    func cardStyle() -> some View {
        modifier(CardBackground())
    }
}

/// Compact number+label tile used in the dashboard's summary strip
/// (device count / online / offline).
struct StatTile: View {
    let value: String
    let label: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(label)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            Text(value)
                .font(.title2.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.12))
        )
    }
}
