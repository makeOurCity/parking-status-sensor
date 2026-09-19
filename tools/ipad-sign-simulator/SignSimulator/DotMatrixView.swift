import SwiftUI

/// Renders an N x N dot-matrix bitmap as flat, evenly-spaced circles —
/// no glow/blur, matching the real LED sign's look (Issue #54).
struct DotMatrixView: View {
    let bitmap: [[Bool]]
    let onColor: Color
    let offColor: Color

    var body: some View {
        Canvas { context, size in
            let rows = bitmap.count
            guard rows > 0 else { return }
            let cols = bitmap[0].count
            guard cols > 0 else { return }

            let cellWidth = size.width / CGFloat(cols)
            let cellHeight = size.height / CGFloat(rows)
            let cell = min(cellWidth, cellHeight)
            let dotDiameter = cell * 0.72

            for row in 0..<rows {
                for col in 0..<cols {
                    let centerX = (CGFloat(col) + 0.5) * cellWidth
                    let centerY = (CGFloat(row) + 0.5) * cellHeight
                    let rect = CGRect(
                        x: centerX - dotDiameter / 2,
                        y: centerY - dotDiameter / 2,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    let color = bitmap[row][col] ? onColor : offColor
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .background(Color.black)
    }
}

#Preview {
    DotMatrixView(bitmap: SignPattern.full, onColor: .red, offColor: Color(white: 0.1))
        .frame(width: 400, height: 400)
}
