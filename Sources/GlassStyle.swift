import SwiftUI

// Dark "liquid glass": a charcoal-glass look built from plain fills and
// gradient strokes only — NO blur/blendMode (they break compositing on the
// transparent panel) and no see-through; everything stays dark.
extension View {
    func darkGlass<S: InsettableShape>(_ shape: S, intensity: CGFloat = 1) -> some View {
        background(
            ZStack {
                shape.fill(Color.white.opacity(0.085 * intensity))
                // Top sheen: light catches the upper curve.
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.16 * intensity), location: 0),
                            .init(color: .white.opacity(0.03 * intensity), location: 0.45),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        )
        .overlay(
            // Rim light: bright top edge fading down the sides.
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.38 * intensity),
                             .white.opacity(0.10 * intensity),
                             .white.opacity(0.05 * intensity)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.35 * intensity), radius: 5, x: 0, y: 3)
    }
}
