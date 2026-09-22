import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - App entry

@main
struct NotchNookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        // No real window scene — the notch lives in its own borderless panel.
        Settings { EmptyView() }
    }
}

// MARK: - Shared UI state

final class NotchState: ObservableObject {
    static let shared = NotchState()
    @Published var expanded = false           // fully open (opened by a CLICK)
    @Published var extended = false           // taller view (e.g. more calendar)
    @Published var peeking = false            // hover: slightly enlarged "contact" state
    @Published var musicActive = false        // something is playing → island mode
    @Published var interacting = false        // dragging inside (scrub) → don't auto-close
    @Published var hoveringArt = false        // cursor precisely on the island's album art
    @Published var dragActive = false         // a file drag is hovering the notch
    var debugPinned = false                   // MYNOTCH_PIN=1: never auto-close (testing)
    @Published var selected: WidgetKind = .mirror

    // notchSize is measured from the hardware notch at launch.
    @Published var notchSize = CGSize(width: 220, height: 32)

    // The window is always the largest (extended) size, so animating between
    // states never resizes the window — only the SwiftUI content moves.
    let openWidth: CGFloat = 380
    let compactHeight: CGFloat = 220
    let extendedHeight: CGFloat = 400

    // Dynamic-island wings: extra width each side for album art + EQ bars.
    // Kept tight on purpose: this black area extends past the hardware notch
    // into macOS's translucent menu bar, so every extra point here is extra
    // opaque-black-vs-frosted-glass mismatch. Just enough for art + EQ bars.
    let islandWing: CGFloat = 34
    // Peek growth: subtle, just enough to read as "you're touching it".
    let peekGrowW: CGFloat = 16
    let peekGrowH: CGFloat = 5

    var windowSize: CGSize { CGSize(width: openWidth, height: extendedHeight) }
    var openSize: CGSize { CGSize(width: openWidth, height: extended ? extendedHeight : compactHeight) }

    // What the collapsed notch actually shows right now: bare notch, or the
    // music island (wings), grown slightly while peeking.
    var collapsedVisibleSize: CGSize {
        var w = notchSize.width + (musicActive ? islandWing * 2 : 0)
        var h = notchSize.height
        if peeking { w += peekGrowW; h += peekGrowH }
        return CGSize(width: w, height: h)
    }

    // The hover/click target when closed — exactly the visible black shape,
    // so menu-bar icons next to it never trigger it.
    var collapsedHitSize: CGSize { collapsedVisibleSize }
}

// MARK: - App delegate / lifecycle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController!
    private var statusItem: NSStatusItem!
    private var loginMenuItem: NSMenuItem!
    private let launchKey = "launchAtLogin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon
        controller = NotchController()
        controller.show()
        setupStatusItem()
        // SMAppService register/status are synchronous XPC round trips to the
        // launch-services daemon — slow right after a reboot, which is exactly
        // when a launch-at-login app starts. Keep them off the launch path.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.syncLoginItem() }
        Updater.shared.checkInBackgroundIfDue()   // silent; speaks up only if there is news

        // Debug hook for screenshot verification (MYNOTCH_EXPAND=1 [MYNOTCH_TAB=…]).
        let env = ProcessInfo.processInfo.environment
        if env["MYNOTCH_PIN"] == "1" { NotchState.shared.debugPinned = true }
        if env["MYNOTCH_EXPAND"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let tab = env["MYNOTCH_TAB"], let kind = WidgetKind(rawValue: tab) {
                    NotchState.shared.selected = kind
                }
                NotchState.shared.expanded = true
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                   accessibilityDescription: "MyNotch")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Notch", action: #selector(toggleNotch), keyEquivalent: "t"))
        loginMenuItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        menu.addItem(loginMenuItem)
        menu.addItem(NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkUpdates), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit My Notch", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    // MARK: Launch at login

    private func syncLoginItem() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: launchKey) == nil {
            defaults.set(true, forKey: launchKey)   // on by default
        }
        applyLoginItem(defaults.bool(forKey: launchKey))
        updateLoginMenuItem()
    }

    private func applyLoginItem(_ on: Bool) {
        do {
            let service = SMAppService.mainApp
            if on, service.status != .enabled {
                try service.register()
            } else if !on, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("MyNotch login-item error: \(error.localizedDescription)")
        }
        NSLog("MyNotch login-item status: \(SMAppService.mainApp.status.rawValue)")
    }

    // Reads status off-main (sync XPC), applies the checkmark on main (AppKit).
    private func updateLoginMenuItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        DispatchQueue.main.async { [weak self] in
            self?.loginMenuItem?.state = enabled ? .on : .off
        }
    }

    @objc private func toggleLoginItem() {
        let defaults = UserDefaults.standard
        let newValue = !defaults.bool(forKey: launchKey)
        defaults.set(newValue, forKey: launchKey)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.applyLoginItem(newValue)
            self.updateLoginMenuItem()
        }
    }

    @objc private func checkUpdates() { Updater.shared.checkNow() }

    @objc private func toggleNotch() {
        NotchState.shared.expanded.toggle()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
