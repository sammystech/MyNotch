import SwiftUI
import ServiceManagement

/// User-facing preferences, persisted in UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()

    @Published var haptics: Bool { didSet { set(haptics, "prefHaptics") } }
    @Published var shelfAutoOpen: Bool { didSet { set(shelfAutoOpen, "prefShelfAutoOpen") } }
    @Published var musicIsland: Bool { didSet { set(musicIsland, "prefMusicIsland") } }
    @Published var scratchSound: Bool { didSet { set(scratchSound, "prefScratchSound") } }
    @Published var launchAtLogin: Bool { didSet { LoginItem.set(launchAtLogin) } }
    @Published var systemHUD: Bool { didSet { set(systemHUD, "prefSystemHUD"); SystemHUD.shared.sync() } }
    @Published var autoUpdate: Bool { didSet { set(autoUpdate, "prefAutoUpdate") } }
    @Published var claudePopups: Bool { didSet { set(claudePopups, "prefClaudePopups") } }
    @Published var codexPopups: Bool { didSet { set(codexPopups, "prefCodexPopups") } }
    @Published var deviceAlerts: Bool { didSet { set(deviceAlerts, "prefDeviceAlerts"); SystemEvents.shared.sync() } }
    @Published var notificationsInNotch: Bool { didSet { set(notificationsInNotch, "prefNotifInNotch"); NotificationMirror.shared.sync() } }
    @Published var hideSystemBanners: Bool { didSet { set(hideSystemBanners, "prefHideBanners") } }
    @Published var lockScreenMusic: Bool { didSet { set(lockScreenMusic, "prefLockScreenMusic") } }
    /// Spinning record in the Music tab; off = Apple Music-style album art.
    @Published var vinyl: Bool { didSet { set(vinyl, "prefVinyl") } }

    private init() {
        let d = UserDefaults.standard
        // Default everything ON the first time it runs.
        func flag(_ key: String) -> Bool { d.object(forKey: key) == nil ? true : d.bool(forKey: key) }
        haptics       = flag("prefHaptics")
        shelfAutoOpen = flag("prefShelfAutoOpen")
        musicIsland   = flag("prefMusicIsland")
        scratchSound  = flag("prefScratchSound")
        // SMAppService.status is a synchronous XPC call — slow right after a
        // reboot, exactly when a login item launches — so start from the last
        // known value and refresh it off the main thread.
        launchAtLogin = d.object(forKey: "launchAtLogin") == nil ? true : d.bool(forKey: "launchAtLogin")
        DispatchQueue.global(qos: .utility).async {
            let actual = LoginItem.isEnabled
            DispatchQueue.main.async {
                if Prefs.shared.launchAtLogin != actual { Prefs.shared.launchAtLogin = actual }
            }
        }
        systemHUD     = flag("prefSystemHUD")
        claudePopups  = flag("prefClaudePopups")
        codexPopups   = flag("prefCodexPopups")
        deviceAlerts  = flag("prefDeviceAlerts")
        notificationsInNotch = flag("prefNotifInNotch")
        hideSystemBanners    = flag("prefHideBanners")
        lockScreenMusic      = flag("prefLockScreenMusic")
        vinyl                = d.bool(forKey: "prefVinyl")      // new look by default
        // Auto-update is ON for every new install, and forced on ONCE for
        // everyone moving to this version (even if they'd turned it off) —
        // after that, their choice sticks.
        if !d.bool(forKey: "autoUpdateForcedOn1") {
            d.set(true, forKey: "autoUpdateForcedOn1")
            d.set(true, forKey: "prefAutoUpdate")
        }
        autoUpdate    = flag("prefAutoUpdate")
    }

    private func set(_ v: Bool, _ key: String) { UserDefaults.standard.set(v, forKey: key) }
}

/// Launch-at-login, shared by the menu bar item and the in-notch settings.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// SMAppService calls are synchronous XPC — always off the main thread.
    static func set(_ on: Bool) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let s = SMAppService.mainApp
                if on, s.status != .enabled { try s.register() }
                else if !on, s.status == .enabled { try s.unregister() }
            } catch {
                NSLog("MyNotch login-item error: \(error.localizedDescription)")
            }
        }
    }
}
