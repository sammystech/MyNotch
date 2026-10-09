import AppKit
import ApplicationServices

// MARK: - All notifications → the notch
//
// macOS has no API to redirect other apps' notifications, but Notification
// Center draws each banner as an accessibility element:
//   AXGroup (subrole AXNotificationCenterBanner, identifier = a UUID,
//            description "App, Title, Subtitle, Body")
//     AXStaticText id=title / id=subtitle / id=body
//   actions: AXPress (open), Show, Close
// With the Accessibility permission My Notch already has (for volume and
// brightness), we read each new banner, show it in the notch with the app's
// real icon, and press the banner's own Close so it doesn't also sit in the
// corner. Read-only otherwise; nothing is stored or sent anywhere.
//
// Trade-offs: the corner banner can flash for a moment before it's closed,
// and a banner closed this way is cleared from Notification Center's list.

final class NotificationMirror {
    static let shared = NotificationMirror()

    private static let ncBundleID = "com.apple.notificationcenterui"
    private var timer: Timer?
    private var observer: AXObserver?
    private var ncPid: pid_t = 0
    private var seen = Set<String>()
    private var queue: [Item] = []

    struct Item {
        let app: String
        let title: String
        let body: String
    }

    func sync() {
        if Prefs.shared.notificationsInNotch { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        attach()
        scan(announce: false)               // don't replay banners already up
        // Safety net + queue pump. Scanning one small window is cheap.
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.scan(announce: true)
            self?.pump()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        detach()
        queue.removeAll()
    }

    // MARK: Observe Notification Center

    private func attach() {
        guard AXIsProcessTrusted(),
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: Self.ncBundleID).first
        else { return }
        ncPid = nc.processIdentifier
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<NotificationMirror>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.scan(announce: true); me.pump() }
        }
        guard AXObserverCreate(ncPid, cb, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(ncPid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
    }

    private func scan(announce: Bool) {
        guard AXIsProcessTrusted() else { return }
        // Notification Center restarts occasionally — follow it.
        if let nc = NSRunningApplication.runningApplications(withBundleIdentifier: Self.ncBundleID).first,
           nc.processIdentifier != ncPid {
            detach(); attach()
        }
        guard ncPid != 0 else { return }
        let app = AXUIElementCreateApplication(ncPid)
        for window in Self.children(app) where Self.string(window, kAXTitleAttribute) == "Notification Center" {
            for banner in Self.banners(in: window, depth: 0) {
                let id = Self.string(banner, kAXIdentifierAttribute) ?? Self.string(banner, kAXDescriptionAttribute) ?? ""
                guard !id.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                if seen.count > 500 { seen.removeAll(); seen.insert(id) }
                guard announce, let item = Self.read(banner) else { continue }
                queue.append(item)
                if Prefs.shared.hideSystemBanners { Self.close(banner) }
            }
        }
    }

    /// Show queued notifications one at a time.
    private func pump() {
        guard !queue.isEmpty, NotchState.shared.toast == nil, NotchState.shared.hud == nil else { return }
        let item = queue.removeFirst()
        let iconRef = Self.appPath(named: item.app).map { "app:" + $0 } ?? "device:bell.badge.fill"
        Toasts.shared.show(title: item.title.isEmpty ? item.app : item.title,
                           subtitle: item.body.isEmpty ? item.app : item.body,
                           icon: iconRef, sound: nil,
                           open: Self.appPath(named: item.app), badge: nil, tall: true)
    }

    // MARK: AX helpers

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
        return (v as? [AXUIElement]) ?? []
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        return v as? String
    }

    private static func banners(in e: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < 8 else { return [] }
        if string(e, kAXSubroleAttribute) == "AXNotificationCenterBanner" { return [e] }
        return children(e).flatMap { banners(in: $0, depth: depth + 1) }
    }

    private static func read(_ banner: AXUIElement) -> Item? {
        var fields: [String: String] = [:]
        for c in children(banner) {
            if let id = string(c, kAXIdentifierAttribute), let v = string(c, kAXValueAttribute) { fields[id] = v }
        }
        let desc = string(banner, kAXDescriptionAttribute) ?? ""
        let app = desc.components(separatedBy: ", ").first ?? ""
        let title = fields["title"] ?? ""
        let body = [fields["subtitle"], fields["body"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        guard !(title.isEmpty && body.isEmpty) else { return nil }
        return Item(app: app, title: title, body: body)
    }

    private static func close(_ banner: AXUIElement) {
        var names: CFArray?
        AXUIElementCopyActionNames(banner, &names)
        // Custom actions are named "Name:Close\nTarget:…"; match by the Name.
        for name in (names as? [String]) ?? [] where name.hasPrefix("Name:Close") || name == "Close" {
            AXUIElementPerformAction(banner, name as CFString)
            return
        }
    }

    /// The app that posted it, by display name → its bundle path (for the icon).
    private static var pathCache: [String: String] = [:]
    private static func appPath(named name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if let hit = pathCache[name] { return hit }
        var found: String?
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let url = running.bundleURL {
            found = url.path
        } else {
            for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                        NSHomeDirectory() + "/Applications"] {
                let p = "\(dir)/\(name).app"
                if FileManager.default.fileExists(atPath: p) { found = p; break }
            }
        }
        if let found { pathCache[name] = found }
        return found
    }
}
