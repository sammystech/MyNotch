import SwiftUI
import AppKit

// MARK: - Now Playing on the lock screen
//
// Like Canopy / iOS: while the Mac is locked and something is playing, a
// glass Now Playing card sits under the system clock. Tap the artwork to
// blow it up into a big cover; tap again to fold it back.
//
// A normal window can't appear over the lock screen. The trick (same one
// other notch apps use) is SkyLight's private API: make a window-server
// "space" at the lock screen's absolute level (400), and move our window
// into it. Looked up with dlsym, so if Apple renames anything the feature
// quietly does nothing instead of crashing.

private enum SkyLight {
    typealias MainConnectionID = @convention(c) () -> Int32
    typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static var connection: Int32 = 0
    private static var space: Int32 = 0

    /// Move `window` into a space that sits above the lock screen.
    static func lift(_ window: NSWindow) -> Bool {
        guard let main = sym("SLSMainConnectionID", MainConnectionID.self),
              let create = sym("SLSSpaceCreate", SpaceCreate.self),
              let level = sym("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self),
              let show = sym("SLSShowSpaces", ShowSpaces.self),
              let add = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self)
        else { return false }
        if space == 0 {
            connection = main()
            space = create(connection, 1, 0)
            _ = level(connection, space, 400)          // 400 = the lock screen's level
            _ = show(connection, [space] as CFArray)
        }
        _ = add(connection, space, [window.windowNumber] as CFArray, 7)
        return true
    }
}

final class LockScreenMusic {
    static let shared = LockScreenMusic()
    private var window: NSPanel?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.show(onLockScreen: true)
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        })
    }

    /// `onLockScreen: false` shows it as an ordinary floating window — the
    /// MYNOTCH_LOCKPREVIEW test hook, so it can be checked without locking.
    func show(onLockScreen: Bool) {
        guard Prefs.shared.lockScreenMusic || !onLockScreen,
              let screen = NSScreen.screens.first else { return }
        let size = NSSize(width: 460, height: 560)
        // Under the system clock, centred: the card's top sits about a third
        // of the way down, where iOS puts its Now Playing.
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.maxY - screen.frame.height * 0.33 - size.height)
        let w = window ?? makeWindow()
        w.setFrame(NSRect(origin: origin, size: size), display: false)
        w.alphaValue = 0
        w.orderFrontRegardless()
        if onLockScreen { _ = SkyLight.lift(w) }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; w.animator().alphaValue = 1 }
    }

    func hide() {
        guard let w = window, w.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; w.animator().alphaValue = 0 },
                                             completionHandler: { w.orderOut(nil) })
    }

    private func makeWindow() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = FirstMouseHostingView(rootView: LockScreenCard(controller: .shared))
        window = p
        return p
    }
}

/// Buttons answer the very first click — the window is never key here.
private final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - The card

struct LockScreenCard: View {
    @ObservedObject var controller: MusicController
    @State private var big = ProcessInfo.processInfo.environment["MYNOTCH_LOCKBIG"] == "1"   // test hook
    @Namespace private var ns

    var body: some View {
        VStack {
            if let np = controller.now {
                card(np)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: controller.now == nil)
    }

    private func card(_ np: NowPlaying) -> some View {
        VStack(spacing: big ? 16 : 12) {
            if big {
                art
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    .scaleEffect(np.isPlaying ? 1 : 0.9)
                    .onTapGesture { toggle() }
                titles(np, centered: true)
            } else {
                HStack(spacing: 12) {
                    art
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onTapGesture { toggle() }
                    titles(np, centered: false)
                    Spacer(minLength: 0)
                }
            }
            LockProgress(np: np)
            controls(np)
        }
        .padding(.horizontal, 20)
        .padding(.top, big ? 22 : 16)
        .padding(.bottom, 14)
        .frame(width: big ? 340 : 380)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .foregroundColor(.white)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: np.isPlaying)
    }

    private var art: some View {
        ArtworkView(image: controller.artwork)
            .matchedGeometryEffect(id: "art", in: ns)
            .contentShape(Rectangle())
    }

    // The cover itself, blurred into the card — so the glass takes on the
    // song's colours (dark enough that white text always reads).
    private var background: some View {
        ZStack {
            Color.black
            if let a = controller.artwork {
                Image(nsImage: a).resizable().scaledToFill()
                    .blur(radius: 40).saturation(1.5).opacity(0.85)
            }
            Color.black.opacity(0.38)
            LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .center)
        }
    }

    private func titles(_ np: NowPlaying, centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 2) {
            Text(np.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(np.artist.isEmpty ? np.album : np.artist)
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func controls(_ np: NowPlaying) -> some View {
        HStack(spacing: 46) {
            glyph("backward.fill", 20) { controller.previous() }
            glyph(np.isPlaying ? "pause.fill" : "play.fill", 28) { controller.playPause() }
            glyph("forward.fill", 20) { controller.next() }
        }
        .frame(height: 40)
    }

    private func glyph(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.82))
    }

    private func toggle() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { big.toggle() }
    }
}

/// Slim iOS lock-screen scrubber with elapsed / remaining times.
private struct LockProgress: View {
    let np: NowPlaying
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = np.position(at: ctx.date)
            let frac = np.duration > 0 ? min(1, pos / np.duration) : 0
            VStack(spacing: 4) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white.opacity(0.9)).frame(width: max(5, g.size.width * frac))
                    }
                }
                .frame(height: 5)
                HStack {
                    Text(mmss(pos))
                    Spacer()
                    Text(np.duration > 0 ? "-" + mmss(max(0, np.duration - pos)) : "")
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(.white.opacity(0.55))
            }
        }
    }
    private func mmss(_ t: Double) -> String {
        let s = max(0, Int(t)); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
