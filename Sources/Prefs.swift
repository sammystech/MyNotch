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

    private init() {
        let d = UserDefaults.standard
        // Default everything ON the first time it runs.
        func flag(_ key: String) -> Bool { d.object(forKey: key) == nil ? true : d.bool(forKey: key) }
        haptics       = flag("prefHaptics")
        shelfAutoOpen = flag("prefShelfAutoOpen")
        musicIsland   = flag("prefMusicIsland")
        scratchSound  = flag("prefScratchSound")
        launchAtLogin = LoginItem.isEnabled
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
