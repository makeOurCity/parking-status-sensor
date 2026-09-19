import Foundation

/// A dot-matrix bitmap for one sign state, extracted mechanically from a
/// photo of the real parking sign (Issue #54, plan A) via
/// `scripts/extract_pattern.py`. See that script and
/// `reference/` for how these were derived.
enum SignPattern {
    static let resolution = 16

    static let full: [[Bool]] = [
        [false, true, false, false, false, false, true, true, false, false, false, true, true, false, false, false],
        [false, true, true, false, false, false, true, true, false, false, false, true, true, false, false, false],
        [false, false, true, true, false, true, true, true, true, true, true, true, true, true, true, false],
        [false, false, false, false, false, false, true, true, false, false, false, true, true, false, false, false],
        [true, false, false, false, false, false, true, true, false, false, false, true, true, false, false, false],
        [true, true, false, false, false, false, true, true, false, false, false, true, true, false, true, false],
        [false, true, true, false, true, true, true, true, true, true, true, true, true, true, true, true],
        [false, false, false, false, false, false, false, false, false, true, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, true, false, false, false, false, false, false],
        [false, false, false, false, true, true, true, true, true, true, true, true, true, true, true, false],
        [false, false, true, false, true, true, false, false, false, true, false, false, false, true, true, false],
        [false, true, true, false, true, true, false, true, false, true, false, true, false, true, true, false],
        [false, true, true, false, true, true, false, true, false, true, false, true, false, true, true, false],
        [true, true, false, false, true, true, false, true, true, true, true, true, false, true, true, false],
        [true, true, false, false, true, true, false, false, false, false, false, false, false, true, true, false],
        [true, false, false, false, true, true, false, false, false, false, false, false, true, true, true, false],
    ]

    static let empty: [[Bool]] = [
        [false, false, false, false, false, false, false, true, true, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, true, true, false, false, false, false, false, false, false],
        [true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true],
        [true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true],
        [true, true, false, false, true, true, true, false, false, true, false, false, false, false, true, true],
        [true, true, false, false, true, true, true, false, false, true, true, false, false, false, true, true],
        [false, false, false, false, true, true, false, false, false, true, true, false, false, false, false, false],
        [false, false, false, true, true, false, false, false, false, true, true, true, true, true, true, false],
        [false, false, true, true, true, false, false, false, false, false, true, true, true, true, false, false],
        [false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, true, true, true, true, true, true, true, true, true, true, true, false, false],
        [false, false, false, true, true, true, true, true, true, true, true, true, true, true, false, false],
        [false, false, false, false, false, false, false, true, true, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, true, true, false, false, false, false, false, false, false],
        [true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true],
        [true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true],
    ]
}
