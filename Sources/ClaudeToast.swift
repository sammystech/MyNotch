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
    var id = UUID()
}

final class Toasts {
    static let shared = Toasts()
    private var hideWork: DispatchWorkItem?
    private let holdTime: TimeInterval = 4.5

    /// Handle mynotch://notify?… — returns true if the URL was ours.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "mynotch", url.host == "notify" else { return false }
        let q = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        show(title: q["title"] ?? "Claude Code",
             subtitle: q["subtitle"] ?? "",
             icon: q["icon"] ?? "claude",
             sound: q["sound"] ?? "Ping",
             open: q["open"])
        return true
    }

    func show(title: String, subtitle: String, icon: String = "claude",
              sound: String? = "Ping", open: String? = nil) {
        let s = NotchState.shared
        // Default click target: Claude for the Claude icon, the app itself for app: icons.
        let target = open ?? (icon == "claude" ? "com.anthropic.claudefordesktop"
                              : icon.hasPrefix("app:") ? String(icon.dropFirst(4)) : nil)
        withAnimation(NotchMotion.morph) {
            s.toast = ToastState(title: title, subtitle: subtitle, icon: icon, openBundle: target)
        }
        if let sound, !sound.isEmpty, let snd = NSSound(named: NSSound.Name(sound)) {
            snd.stop(); snd.play()
        }
        hideWork?.cancel()
        let w = DispatchWorkItem { self.dismiss() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + holdTime, execute: w)
    }

    func dismiss() {
        hideWork?.cancel()
        withAnimation(NotchMotion.collapse) { NotchState.shared.toast = nil }
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
        if icon.hasPrefix("app:"), let img = Toasts.appIcon(String(icon.dropFirst(4))) {
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
    }

    var row: some View {
        HStack(spacing: 11) {
            ToastIcon(icon: toast.icon)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(toast.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if !toast.subtitle.isEmpty {
                    Text(toast.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, Color(red: 0.2, green: 0.82, blue: 0.4))
        }
    }
}
