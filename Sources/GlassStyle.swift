import SwiftUI
import AppKit

// MARK: - Motion

// One motion language for the whole notch, tuned to feel like the iPhone's
// Dynamic Island: a soft spring with just a hint of overshoot on the morph,
// quicker and tighter for small feedback.
enum NotchMotion {
    /// Open / close / resize morph of the black shape.
    static let morph = Animation.spring(response: 0.44, dampingFraction: 0.78)
    /// Closing back into the notch: no overshoot.
    static let collapse = Animation.spring(response: 0.38, dampingFraction: 0.9)
    /// Hover "peek" and other small nudges.
    static let nudge = Animation.spring(response: 0.3, dampingFraction: 0.7)
    /// Switching tabs, sliding the selection pill.
    static let tab = Animation.spring(response: 0.34, dampingFraction: 0.84)
    /// Button presses.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.62)
}

// Content blooms out of the island: it scales up from the top edge and
// sharpens from a blur, the way the iPhone island's content materializes as
// the shape grows. Leaves quickly so the shape's collapse reads first.
struct BloomModifier: ViewModifier {
    let progress: CGFloat   // 0 = hidden, 1 = shown
    func body(content: Content) -> some View {
        content
            .opacity(Double(progress))
            .scaleEffect(0.9 + 0.1 * progress, anchor: .top)
            .blur(radius: (1 - progress) * 8)
    }
}

extension AnyTransition {
    static var bloom: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BloomModifier(progress: 0), identity: BloomModifier(progress: 1))
                .animation(NotchMotion.morph.delay(0.05)),
            removal: .modifier(active: BloomModifier(progress: 0), identity: BloomModifier(progress: 1))
                .animation(.easeOut(duration: 0.14))
        )
    }
    /// Tab-to-tab swap: a short blur cross-dissolve.
    static var swap: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SwapModifier(progress: 0), identity: SwapModifier(progress: 1)),
            removal: .modifier(active: SwapModifier(progress: 0), identity: SwapModifier(progress: 1))
        )
    }
}

struct SwapModifier: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(Double(progress))
            .scaleEffect(0.97 + 0.03 * progress)
            .blur(radius: (1 - progress) * 6)
    }
}

// MARK: - Dark liquid glass

// A charcoal-glass look built from plain fills and gradient strokes only —
// NO backdrop materials (they go see-through on this transparent panel) and
// no see-through; everything stays dark. Layers, bottom to top:
//   body tint → top sheen → inner bottom glow (light bouncing back up) →
//   two-tone rim (bright top edge, faint lower edge) → soft drop shadow.
extension View {
    func darkGlass<S: InsettableShape>(_ shape: S, intensity: CGFloat = 1) -> some View {
        background(
            ZStack {
                shape.fill(Color.white.opacity(0.075 * intensity))
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.17 * intensity), location: 0),
                            .init(color: .white.opacity(0.035 * intensity), location: 0.42),
                            .init(color: .clear, location: 0.7),
                            .init(color: .white.opacity(0.05 * intensity), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        )
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.42 * intensity), location: 0),
                        .init(color: .white.opacity(0.09 * intensity), location: 0.45),
                        .init(color: .white.opacity(0.04 * intensity), location: 0.75),
                        .init(color: .white.opacity(0.14 * intensity), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.8
            )
        )
        .shadow(color: .black.opacity(0.4 * intensity), radius: 6, x: 0, y: 3)
    }

    /// A barely-there dark card for grouping rows (iOS inset-grouped, but black).
    func glassCard(radius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(
            ZStack {
                shape.fill(Color.white.opacity(0.045))
                shape.fill(LinearGradient(colors: [.white.opacity(0.04), .clear],
                                          startPoint: .top, endPoint: .center))
            }
        )
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.7)
        )
    }
}

// MARK: - Buttons

/// Press feedback that feels physical: squish + brighten, springs back.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.86
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(NotchMotion.press, value: configuration.isPressed)
    }
}

/// Small glass capsule button ("Check for Updates", "Clear", …).
struct GlassPillButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
                Text(title).font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundColor(prominent ? .black : .white.opacity(0.92))
            .padding(.horizontal, 11).padding(.vertical, 5.5)
            .background(prominent ? Capsule().fill(Color.white) : nil)
            .modifier(OptionalGlass(on: !prominent))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.93))
    }
}

private struct OptionalGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.darkGlass(Capsule(), intensity: 0.85) } else { content }
    }
}

// MARK: - iOS switch

/// An iOS-style switch: green track, white knob with a soft shadow, springy
/// throw. Replaces AppKit's mini switch, which looked out of place on black.
struct IslandSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Color(red: 0.2, green: 0.78, blue: 0.35) : Color.white.opacity(0.14))
                .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.12 : 0.08), lineWidth: 0.6))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                .padding(2)
        }
        .frame(width: 34, height: 20)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { configuration.isOn.toggle() }
        }
    }
}

// MARK: - Album colour

extension NSImage {
    /// A vivid-but-readable accent sampled from the artwork, for tinting the
    /// island's EQ bars the way the iPhone tints them to the album.
    func accentColor() -> Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 12
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)

        // Pick the most saturated reasonably-bright pixels, weighted — so a
        // mostly-beige cover with a red title still yields red, not beige.
        var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
        for i in 0..<(n * n) {
            let pr = Double(px[i * 4]) / 255, pg = Double(px[i * 4 + 1]) / 255, pb = Double(px[i * 4 + 2]) / 255
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let sat = mx > 0 ? (mx - mn) / mx : 0
            let w = pow(sat, 2) * (mx > 0.25 ? 1 : 0.1) + 0.002
            r += pr * w; g += pg * w; b += pb * w; wsum += w
        }
        guard wsum > 0 else { return nil }
        let c = NSColor(srgbRed: r / wsum, green: g / wsum, blue: b / wsum, alpha: 1)
        // Lift it so it reads on pure black: keep the hue, push brightness up.
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        if s < 0.12 { return Color.white }   // monochrome cover → white bars
        return Color(hue: Double(h), saturation: Double(min(0.75, max(0.4, s))),
                     brightness: Double(max(0.82, v)))
    }
}
