import AppKit
import SwiftUI

// MARK: - Notch toasts (e.g. "Claude Code — conversation finished")
//
// Anything on the Mac can pop a message out of the notch by opening
//   mynotch://notify?title=…&subtitle=…&icon=claude&sound=Ping[&open=<bundle id>]
// icon is "claude" (drawn burst), "app:<bundle id or /path/to/App.app>" (that
// app's real icon, e.g. app:/Applications/Codex.app), or any SF Symbol name.
// open is a bundle id or an app path. (Codex and ChatGPT share one bundle id,
// com.openai.codex, so Codex is addressed by its path.)
// (`open -g` keeps whatever you're doing in front). The Claude Code Stop hook
// at ~/.claude/hooks/notch-done.sh uses this when a conversation finishes.

struct ToastState: Equatable {
    var title: String
    var subtitle: String
    var icon: String = "claude"        // "claude", "app:<bundle id>", or an SF Symbol
    var openBundle: String?            // app to bring forward when the toast is clicked
    var badge: String? = "check"       // trailing mark; nil = none
    var tall = false                   // notifications: room for a 2-line message
    var opensOnClick = false           // Claude/Codex: a click jumps to the app
    var id = UUID()
}

final class Toasts {
    static let shared = Toasts()
    private var hideWork: DispatchWorkItem?
    // How long a pop-up stays out (user: "stay up too long" at 4.5s).
    private let holdTime: TimeInterval = 3.2
    private let tallHoldTime: TimeInterval = 3.8   // notifications: a beat longer to read the message

    /// Handle mynotch://notify?… — returns true if the URL was ours.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "mynotch", url.host == "notify" else { return false }
        let q = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        // Per-source switches in Settings (source=claude / source=codex).
        switch q["source"] {
        case "claude": if !Prefs.shared.claudePopups { return true }
        case "codex":  if !Prefs.shared.codexPopups { return true }
        default: break
        }
        show(title: q["title"] ?? "Claude Code",
             subtitle: q["subtitle"] ?? "",
             icon: q["icon"] ?? "claude",
             sound: q["sound"] ?? "Ping",
             open: q["open"],
             badge: q["badge"] ?? "check",
             opensOnClick: q["source"] == "claude" || q["source"] == "codex" || q["icon"] == "claude")
        return true
    }

    static let dbg = ProcessInfo.processInfo.environment["MYNOTCH_TOASTLOG"] == "1"

    func show(title: String, subtitle: String, icon: String = "claude",
              sound: String? = "Ping", open: String? = nil, badge: String? = "check",
              tall: Bool = false, opensOnClick: Bool = false) {
        if Self.dbg { FileHandle.standardError.write("TOASTSHOW\n".data(using: .utf8)!) }
        let s = NotchState.shared
        // Default click target: Claude for the Claude icon, the app itself for app: icons.
        let target = open ?? (icon == "claude" ? "com.anthropic.claudefordesktop"
                              : icon.hasPrefix("app:") ? String(icon.dropFirst(4)) : nil)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.66)) {   // a lively pop out of the notch
            s.toast = ToastState(title: title, subtitle: subtitle, icon: icon, openBundle: target,
                                 badge: badge, tall: tall, opensOnClick: opensOnClick)
        }
        if let sound, !sound.isEmpty, let snd = NSSound(named: NSSound.Name(sound)) {
            snd.stop(); snd.play()
        }
        hideWork?.cancel()
        let w = DispatchWorkItem { self.dismiss() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (tall ? tallHoldTime : holdTime), execute: w)
    }

    func dismiss() {
        hideWork?.cancel()
        withAnimation(NotchMotion.collapse) { NotchState.shared.toast = nil }
    }

    /// A click on a pop-up: Claude/Codex open their app; everything else
    /// just tucks away (the next click opens the island).
    func clicked() {
        if NotchState.shared.toast?.opensOnClick == true { activate() } else { dismissQuickly() }
    }

    /// Clicked away: a quick, snappy tuck back into the notch.
    func dismissQuickly() {
        hideWork?.cancel()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) { NotchState.shared.toast = nil }
    }

    /// Clicking the toast jumps to the app it's about (Claude, Codex, …).
    func activate() {
        if let id = NotchState.shared.toast?.openBundle, let app = Self.appURL(id) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
        dismiss()
    }

    /// Real app icons for "app:<bundle id>", cached.
    private static var iconCache: [String: NSImage] = [:]
    static func appIcon(_ ref: String) -> NSImage? {
        if let hit = iconCache[ref] { return hit }
        guard let url = appURL(ref) else { return nil }
        let lazy = NSWorkspace.shared.icon(forFile: url.path)
        // Workspace icons draw lazily, and SwiftUI rendered them blank — so
        // rasterize once into a plain bitmap at a crisp size.
        let px = 96
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        lazy.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: 32, height: 32))
        img.addRepresentation(rep)
        iconCache[ref] = img
        return img
    }

    /// A bundle id, or a path to an .app.
    static func appURL(_ ref: String) -> URL? {
        if ref.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: ref) ? URL(fileURLWithPath: ref) : nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: ref)
    }
}

// MARK: - Claude logo

/// Claude's mark: a coral burst of rounded rays, drawn as vectors so it's
/// crisp at any size.
struct ClaudeBurst: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let rays = 12
        for i in 0..<rays {
            let a = Double(i) / Double(rays) * 2 * .pi + .pi / 12
            let len = r * (i % 2 == 0 ? 1.0 : 0.78)
            let w = r * 0.17
            let tip = CGPoint(x: c.x + CGFloat(cos(a)) * len, y: c.y + CGFloat(sin(a)) * len)
            let base = CGPoint(x: c.x + CGFloat(cos(a)) * r * 0.12, y: c.y + CGFloat(sin(a)) * r * 0.12)
            var ray = Path()
            ray.move(to: base); ray.addLine(to: tip)
            p.addPath(ray.strokedPath(StrokeStyle(lineWidth: w, lineCap: .round)))
        }
        return p
    }
}

private let claudeCoral = Color(red: 0.85, green: 0.47, blue: 0.34)

private struct ToastIcon: View {
    let icon: String
    var body: some View {
        if icon.hasPrefix("device:") {
            // Hardware (AirPods, Beats…): a big, crisp glyph, no tile — like
            // the iPhone's connection pop-up. Optional tint: "device:wifi#34C759".
            let parts = String(icon.dropFirst(7)).split(separator: "#", maxSplits: 1).map(String.init)
            Image(systemName: parts[0])
                .font(.system(size: 26, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(parts.count > 1 ? Color(hex: parts[1]) : .white)
                .frame(width: 38, height: 38)
        } else if icon.hasPrefix("app:"), let img = Toasts.appIcon(String(icon.dropFirst(4))) {
            // The app's own icon already has its shape and depth.
            Image(nsImage: img).resizable().interpolation(.high)
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        } else {
            tile
        }
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
            if icon == "claude" {
                ClaudeBurst().fill(claudeCoral).padding(6)
            } else {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            }
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - The toast as the island

/// Pops out of the notch: the island widens and drops into a pill holding
/// the logo, a title and a subtitle — like an iPhone Live Activity alert.
struct ToastIslandContent: View {
    let toast: ToastState
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)          // the hardware notch
            row
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)
        }
        .overlay(Sheen().id(toast.id).allowsHitTesting(false))
    }

    /// Each element enters on its own beat — logo pops with a twist, title
    /// and message rise out of a blur one after the other, the check bounces
    /// in last. `.id` gives every new pop-up a fresh run of the choreography.
    var row: some View { ToastRowView(toast: toast).id(toast.id) }
}

private struct ToastRowView: View {
    let toast: ToastState
    @StateObject private var go = AppearTrigger()

    var body: some View {
        HStack(spacing: 11) {
            ToastIcon(icon: toast.icon)
                .keyframeAnimator(initialValue: Pop(), trigger: go.fired) { v, p in
                    v.scaleEffect(go.fired ? p.scale : 0.25)
                        .rotationEffect(.degrees(go.fired ? p.angle : -14))
                        .opacity(go.fired ? p.opacity : 0)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(0.25, duration: 0.06)
                        SpringKeyframe(1.18, duration: 0.24, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                    }
                    KeyframeTrack(\.angle) {
                        LinearKeyframe(-14, duration: 0.06)
                        SpringKeyframe(4, duration: 0.24)
                        SpringKeyframe(0, duration: 0.3)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0, duration: 0.06)
                        LinearKeyframe(1, duration: 0.14)
                    }
                }
            VStack(alignment: .leading, spacing: 1.5) {
                Text(toast.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .modifier(Rise(delay: 0.12, go: go.fired))
                if !toast.subtitle.isEmpty {
                    Text(toast.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(toast.tall ? 0.72 : 0.55))
                        .lineLimit(toast.tall ? 2 : 1)
                        .truncationMode(.middle)
                        .modifier(Rise(delay: 0.2, go: go.fired))
                }
            }
            Spacer(minLength: 6)
            if toast.badge == "check" {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, Color(red: 0.2, green: 0.82, blue: 0.4))
                    .keyframeAnimator(initialValue: Pop(scale: 0, angle: 0), trigger: go.fired) { v, p in
                        v.scaleEffect(go.fired ? p.scale : 0).opacity(go.fired ? p.opacity : 0)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0, duration: 0.3)
                            SpringKeyframe(1.3, duration: 0.2, spring: .snappy)
                            SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: 0.3)
                            LinearKeyframe(1, duration: 0.1)
                        }
                    }
            }
        }
        .onAppear { DispatchQueue.main.async { go.fired = true } }
    }
}

/// Fires once, right after the view appears — keyframe animations are
/// started by a trigger change (a "play once" without one never runs).
final class AppearTrigger: ObservableObject { @Published var fired = false }

private struct Pop {
    var scale: CGFloat = 0.25
    var angle: Double = -14
    var opacity: Double = 0
}

/// Rise out of a blur after `delay`.
private struct Rise: ViewModifier {
    let delay: Double
    let go: Bool
    struct V { var y: CGFloat = 9; var blur: CGFloat = 6; var opacity: Double = 0 }
    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: V(), trigger: go) { v, p in
            v.offset(y: go ? p.y : 9).blur(radius: go ? p.blur : 6).opacity(go ? p.opacity : 0)
        } keyframes: { _ in
            KeyframeTrack(\.y) {
                LinearKeyframe(9, duration: delay)
                SpringKeyframe(0, duration: 0.42, spring: .smooth)
            }
            KeyframeTrack(\.blur) {
                LinearKeyframe(6, duration: delay)
                CubicKeyframe(0, duration: 0.3)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(0, duration: delay)
                CubicKeyframe(1, duration: 0.25)
            }
        }
    }
}

/// One soft highlight that sweeps across the pill as it lands.
private struct Sheen: View {
    @StateObject private var go = AppearTrigger()
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.11), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.35)
                .rotationEffect(.degrees(14))
                .keyframeAnimator(initialValue: CGFloat(-0.5), trigger: go.fired) { v, x in
                    v.offset(x: (go.fired ? x : -0.5) * g.size.width)
                } keyframes: { _ in
                    LinearKeyframe(-0.5, duration: 0.18)
                    CubicKeyframe(1.3, duration: 0.75)
                }
        }
        .clipped()
        .onAppear { DispatchQueue.main.async { go.fired = true } }
    }
}

extension Color {
    /// "34C759" → Color.
    init(hex: String) {
        let v = UInt64(hex, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
