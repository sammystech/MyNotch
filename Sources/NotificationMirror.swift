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
        // Build the app index in the background, hand it over on main.
        DispatchQueue.global(qos: .utility).async {
            let built = Self.makeIndex()
            DispatchQueue.main.async { Self.index = built; Self.indexBuilt = true }
        }
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
    /// Banners only carry the app's display name, which often differs from its
    /// file name ("Discord" vs "Discord.app" in a subfolder, "WhatsApp" vs
    /// "WhatsApp Desktop.app"…), so look it up in an index of every installed
    /// app keyed by ALL its names.
    private static var pathCache: [String: String] = [:]
    private static var index: [String: String] = [:]
    private static var indexBuilt = false

    static func appPath(named name: String) -> String? {
        guard !name.isEmpty else { return nil }
        let key = name.lowercased()
        if let hit = pathCache[key] { return hit }
        var found: String?
        // Only real apps — not helper extensions running under the same name
        // (Messages' assistant .appex lives inside Messages.app).
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == key
                && $0.bundleURL?.pathExtension == "app"
                && !($0.bundleURL?.path.contains(".app/") ?? true) }), let url = running.bundleURL {
            found = url.path
        }
        if found == nil {
            if !indexBuilt { index = makeIndex(); indexBuilt = true }
            found = index[key]
                ?? index.first(where: { $0.key.hasPrefix(key) || key.hasPrefix($0.key) })?.value
        }
        if let found { pathCache[key] = found }
        return found
    }

    /// Every .app (two levels deep, so suites in folders count) by display
    /// name, bundle name and file name. ~1 ms per app; built once, lazily.
    static func makeIndex() -> [String: String] {
        var index: [String: String] = [:]
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/System/Library/CoreServices", "/System/Library/CoreServices/Applications",
                     NSHomeDirectory() + "/Applications", "/Applications/Utilities"]
        func add(_ appPath: String) {
            let file = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            var names = [file]
            if let info = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") {
                for k in ["CFBundleDisplayName", "CFBundleName"] {
                    if let v = info[k] as? String { names.append(v) }
                }
            }
            for n in names where !n.isEmpty {
                let k = n.lowercased()
                if index[k] == nil { index[k] = appPath }
            }
        }
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let path = root + "/" + item
                if item.hasSuffix(".app") { add(path); continue }
                // One level into folders (e.g. /Applications/Microsoft Office/…).
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                   let sub = try? fm.contentsOfDirectory(atPath: path) {
                    for s in sub where s.hasSuffix(".app") { add(path + "/" + s) }
                }
            }
        }
        return index
    }
}
