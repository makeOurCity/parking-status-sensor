import SwiftUI

/// Persists the user-customizable 満/空 colors across launches (UserDefaults).
@MainActor
final class SettingsStore: ObservableObject {
    static let defaultFullColor = Color.red
    static let defaultEmptyColor = Color.green

    @Published var fullColor: Color {
        didSet { Self.save(fullColor, forKey: Keys.fullColor) }
    }
    @Published var emptyColor: Color {
        didSet { Self.save(emptyColor, forKey: Keys.emptyColor) }
    }

    private enum Keys {
        static let fullColor = "signsimulator.fullColor"
        static let emptyColor = "signsimulator.emptyColor"
    }

    init() {
        fullColor = Self.load(forKey: Keys.fullColor) ?? Self.defaultFullColor
        emptyColor = Self.load(forKey: Keys.emptyColor) ?? Self.defaultEmptyColor
    }

    func resetToDefaults() {
        fullColor = Self.defaultFullColor
        emptyColor = Self.defaultEmptyColor
    }

    private static func save(_ color: Color, forKey key: String) {
        let resolved = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        UserDefaults.standard.set([Double(r), Double(g), Double(b), Double(a)], forKey: key)
    }

    private static func load(forKey key: String) -> Color? {
        guard let components = UserDefaults.standard.array(forKey: key) as? [Double],
              components.count == 4 else { return nil }
        return Color(
            red: components[0],
            green: components[1],
            blue: components[2],
            opacity: components[3]
        )
    }
}
