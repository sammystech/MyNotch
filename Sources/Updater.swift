import AppKit

// MARK: - Auto update (GitHub Releases)
//
// Sparkle would be the usual choice, but it needs a framework embedded and
// signed, which is painful without Xcode. This does the same job against the
// GitHub Releases API: compare the latest tag to our bundle version, download
// the .dmg asset, swap the app in place, relaunch.

final class Updater {
    static let shared = Updater()

    static let repo = "sammystech/MyNotch"
    private let lastCheckKey = "lastUpdateCheck"
    private let skipKey = "skipVersion"
    private var checking = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Entry points

    /// Silent check on launch, then once a day. Only speaks up if there's news.
    func checkInBackgroundIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let day: TimeInterval = 60 * 60 * 24
        guard Date().timeIntervalSince1970 - last > day else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.check(interactive: false)
        }
    }

    /// From the menu: always reports the outcome, even "you're up to date".
    func checkNow() { check(interactive: true) }

    // MARK: Check

    private func check(interactive: Bool) {
        guard !checking else { return }
        checking = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
            checking = false; return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            defer { self.checking = false }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if interactive {
                    self.alert("Couldn't check for updates",
                               error?.localizedDescription ?? "No release information came back from GitHub.")
                }
                return
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = (json["body"] as? String) ?? ""
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            let dmgURL = (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:))

            guard Self.isNewer(latest, than: self.currentVersion) else {
                if interactive {
                    self.alert("You're up to date", "MyNotch \(self.currentVersion) is the latest version.")
                }
                return
            }
            guard let dmgURL else {
                if interactive {
                    self.alert("Update available", "Version \(latest) is out, but it has no .dmg attached yet.")
                }
                return
            }
            // Respect a previous "Skip this version" unless they asked explicitly.
            if !interactive, UserDefaults.standard.string(forKey: self.skipKey) == latest { return }
            self.offer(version: latest, notes: notes, dmg: dmgURL)
        }.resume()
    }

    /// Numeric, component-wise compare so 1.10 > 1.9 (a plain string compare gets this wrong).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: UI

    private func alert(_ title: String, _ body: String) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = body
            a.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    private func offer(version: String, notes: String, dmg: URL) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = "MyNotch \(version) is available"
            a.informativeText = notes.isEmpty
                ? "You have \(self.currentVersion). Install the update now?"
                : "You have \(self.currentVersion).\n\n\(notes.prefix(600))"
            a.addButton(withTitle: "Install & Relaunch")
            a.addButton(withTitle: "Later")
            a.addButton(withTitle: "Skip This Version")
            NSApp.activate(ignoringOtherApps: true)
            switch a.runModal() {
            case .alertFirstButtonReturn:  self.download(dmg, version: version)
            case .alertThirdButtonReturn:  UserDefaults.standard.set(version, forKey: self.skipKey)
            default: break
            }
        }
    }

    // MARK: Download + install

    private func download(_ url: URL, version: String) {
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, error in
            guard let self else { return }
            guard let tmp else {
                self.alert("Download failed", error?.localizedDescription ?? "Couldn't download the update.")
                return
            }
            // Move off the URLSession temp path before it's reaped.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("MyNotch-\(version).dmg")
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: tmp, to: dest) }
            catch { self.alert("Download failed", error.localizedDescription); return }
            self.install(dmg: dest)
        }.resume()
    }

    /// Hands the swap to a detached script: we can't replace our own bundle
    /// while running, so the script waits for us to quit, copies, and reopens.
    private func install(dmg: URL) {
        let appPath = Bundle.main.bundlePath
        let script = """
        #!/bin/bash
        set -e
        DMG="\(dmg.path)"
        APP="\(appPath)"
        MOUNT=$(mktemp -d /tmp/mynotch-update-XXXXXX)

        # Wait for the running copy to actually exit (max ~10s).
        for _ in $(seq 1 50); do
          pgrep -f "$APP/Contents/MacOS/" >/dev/null || break
          sleep 0.2
        done

        hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT"
        NEW=$(find "$MOUNT" -maxdepth 1 -name "*.app" -print -quit)
        if [ -n "$NEW" ]; then
          rm -rf "$APP"
          cp -R "$NEW" "$APP"
          xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
        fi
        hdiutil detach "$MOUNT" -quiet || true
        rm -rf "$MOUNT" "$DMG"
        open "$APP"
        """
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynotch-update.sh")
        do {
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        } catch {
            alert("Update failed", error.localizedDescription); return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [path.path]
        do { try task.run() } catch {
            alert("Update failed", error.localizedDescription); return
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
