import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox
import ApplicationServices

// MARK: - Volume / brightness in the island
//
// Replaces macOS's own volume + brightness popups with the island. A session
// event tap catches the media keys BEFORE the system does; swallowing them is
// what stops the stock OSD from ever appearing, and we apply the change
// ourselves (CoreAudio for volume, DisplayServices for the built-in screen).
// Needs Accessibility permission once. Without it every key simply passes
// through to macOS as normal — nothing breaks.

enum HUDKind: Equatable { case volume, brightness }

struct HUDState: Equatable {
    var kind: HUDKind
    var level: Double          // 0…1
    var muted = false
    var device: String = "speaker"   // SF Symbol hint for the output (AirPods, display…)
}

// MARK: Volume (CoreAudio)

final class VolumeControl {
    // EVERY CoreAudio (HAL) call happens on this queue — never on the main
    // thread. HAL calls are synchronous IPC to coreaudiod; for Bluetooth
    // outputs a volume set can take tens of ms, and doing them on main at
    // slider-drag / key-repeat rate stalled the whole app. Listeners are
    // registered here too: removing a HAL listener from the queue it's
    // delivered on can stall or deadlock.
    private let hal = DispatchQueue(label: "MyNotch.coreaudio", qos: .userInitiated)

    /// What the rest of the app reads — a cached snapshot, refreshed on `hal`.
    private struct Snapshot {
        var device: AudioObjectID = 0
        var canControl = false
        var volume: Double = 0
        var muted = false
        var name = "Headphones"
        var symbol = "speaker"
        var headphones = false
    }
    private let lock = NSLock()
    private var snap = Snapshot()
    private func read<T>(_ f: (Snapshot) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(snap) }
    private func write(_ f: (inout Snapshot) -> Void) { lock.lock(); f(&snap); lock.unlock() }

    private var device: AudioObjectID = 0      // hal queue only
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []  // hal only
    var onExternalChange: (() -> Void)?        // called on main
    private var externalWork: DispatchWorkItem?   // main only
    // Starts in the future: registering the listeners at launch reports a
    // "change" that flashed the volume pill on every launch/login.
    private var ourChangeUntil = Date().addingTimeInterval(4)   // guarded by lock

    // Coalesced writes: only the latest wish is sent to coreaudiod.
    private var pendingVolume: Double?
    private var pendingMute: Bool?

    private static let mainVolume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    init() {
        hal.async { [weak self] in
            guard let self else { return }
            self.device = Self.defaultOutput()
            self.refreshSnapshot()
            self.watch()
            // Follow the default output (plugging in AirPods, switching to HDMI…).
            var addr = Self.addr(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, self.hal) { [weak self] _, _ in
                guard let self else { return }
                let old = self.device
                self.unwatch()
                self.device = Self.defaultOutput()
                self.refreshSnapshot()
                self.watch()
                guard self.device != old, self.device != 0 else { return }
                // The switch also nudges the volume properties — don't let that
                // flash the volume pill over the "connected" pop-up.
                self.lock.lock(); self.ourChangeUntil = Date().addingTimeInterval(1.5); self.lock.unlock()
                DispatchQueue.main.async { self.onDeviceChange?() }
            }
        }
    }

    /// Fired (on main) when the default output switches (e.g. AirPods connect).
    var onDeviceChange: (() -> Void)?

    /// hal queue: re-read everything the app displays.
    private func refreshSnapshot() {
        var v = Float32(0), m = UInt32(0)
        let gotV = get(Self.mainVolume, &v)
        let gotM = get(kAudioDevicePropertyMute, &m)
        let t = transport
        let name = deviceNameNow
        let headphones = t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
        let symbol: String = headphones ? Self.headphoneSymbol(for: name)
            : (t == kAudioDeviceTransportTypeHDMI || t == kAudioDeviceTransportTypeDisplayPort) ? "tv" : "speaker"
        let can = device != 0 && settable(Self.mainVolume)
        write {
            $0.device = device; $0.canControl = can; $0.name = name; $0.symbol = symbol; $0.headphones = headphones
            if gotV { $0.volume = Double(v) }
            if gotM { $0.muted = m != 0 }
        }
    }

    var isHeadphones: Bool { read { $0.headphones } }
    /// The output's name as macOS shows it ("Sam's AirPods Pro").
    var deviceName: String { read { $0.name } }
    /// SF Symbol for what's playing out of: AirPods, a display, the Mac.
    var deviceSymbol: String { read { $0.symbol } }
    /// False for outputs macOS can't set a level on (many HDMI/DisplayPort
    /// monitors) — those keys are left to the system. Safe on any thread.
    var canControl: Bool { read { $0.canControl } }

    /// The level we last asked for. macOS eases the speaker toward a new
    /// level over a few hundred ms, so reading it back mid-fade returns a
    /// stale in-between value. While our change is settling, trust this.
    private var intended: Double?        // guarded by lock
    private var intendedMute: Bool?      // guarded by lock

    var volume: Double {
        lock.lock(); defer { lock.unlock() }
        if let intended, Date() < ourChangeUntil { return intended }
        return snap.volume
    }

    var muted: Bool {
        lock.lock(); defer { lock.unlock() }
        if let intendedMute, Date() < ourChangeUntil { return intendedMute }
        return snap.muted
    }

    func set(volume: Double) {
        let v = min(1, max(0, volume))
        lock.lock()
        ourChangeUntil = Date().addingTimeInterval(1.2)
        intended = v
        snap.volume = v
        let wasMuted = (intendedMute != nil && Date() < ourChangeUntil) ? intendedMute! : snap.muted
        pendingVolume = v
        lock.unlock()
        // Like macOS: turning it up unmutes.
        if v > 0, wasMuted { set(muted: false) }
        hal.async { [weak self] in self?.flush() }
    }

    func set(muted on: Bool) {
        lock.lock()
        ourChangeUntil = Date().addingTimeInterval(1.2)
        intendedMute = on
        snap.muted = on
        pendingMute = on
        lock.unlock()
        hal.async { [weak self] in self?.flush() }
    }

    /// hal queue: send only the latest pending values.
    private func flush() {
        lock.lock()
        let v = pendingVolume, m = pendingMute
        pendingVolume = nil; pendingMute = nil
        lock.unlock()
        if var f = v.map({ Float32($0) }) { set(Self.mainVolume, &f) }
        if let m, settable(kAudioDevicePropertyMute) {
            var u = UInt32(m ? 1 : 0)
            set(kAudioDevicePropertyMute, &u)
        }
    }

    private var transport: UInt32 {   // hal queue
        var t = UInt32(0)
        var a = Self.addr(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &t)
        return t
    }

    private var deviceNameNow: String {   // hal queue
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var a = Self.addr(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &name) == noErr,
              let n = name?.takeRetainedValue() else { return "Headphones" }
        return n as String
    }

    /// The SF Symbol for the exact model, by name — Apple ships a glyph for
    /// each AirPods generation and for Beats.
    static func headphoneSymbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return n.contains("4") || n.contains("3") ? "airpods.gen3" : "airpods" }
        if n.contains("beats") && !n.contains("pill") { return "beats.headphones" }
        // Speakers and soundbars aren't headphones.
        let speakers = ["speaker", "soundbar", "sound bar", "jbl", "sonos", "bose soundlink", "charge", "flip",
                        "boom", "megaboom", "homepod", "vizio", "sb36", "beats pill", "marshall", "ue "]
        if speakers.contains(where: { n.contains($0) }) { return "hifispeaker.fill" }
        return "headphones"
    }

    // Changes from Control Center, AirPods, other apps → show the island too.
    // hal queue.
    private func watch() {
        guard device != 0 else { return }
        for sel in [Self.mainVolume, kAudioDevicePropertyMute] {
            var a = Self.addr(sel)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.refreshSnapshot()
                self.lock.lock(); let ours = Date() <= self.ourChangeUntil; self.lock.unlock()
                guard !ours else { return }
                DispatchQueue.main.async {
                    self.externalWork?.cancel()
                    let w = DispatchWorkItem { [weak self] in self?.onExternalChange?() }
                    self.externalWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
                }
            }
            if AudioObjectAddPropertyListenerBlock(device, &a, hal, block) == noErr {
                listeners.append((device, a, block))
            }
        }
    }

    private func unwatch() {   // hal queue
        for (dev, a, block) in listeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(dev, &a, hal, block)
        }
        listeners.removeAll()
    }

    private static func defaultOutput() -> AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    private static func addr(_ sel: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func get<T>(_ sel: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        guard device != 0 else { return false }
        var a = Self.addr(sel)
        guard AudioObjectHasProperty(device, &a) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr
    }

    private func set<T>(_ sel: AudioObjectPropertySelector, _ value: inout T) {
        guard device != 0 else { return }
        var a = Self.addr(sel)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    private func settable(_ sel: AudioObjectPropertySelector) -> Bool {
        guard device != 0 else { return false }
        var a = Self.addr(sel)
        guard AudioObjectHasProperty(device, &a) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &a, &ok) == noErr && ok.boolValue
    }
}

// MARK: Brightness (DisplayServices, built-in display)

final class BrightnessControl {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var getFn: GetFn?
    private var setFn: SetFn?
    private var ramp: CADisplayLink?
    private var rampFrom: Float = 0, rampTo: Float = 0, rampStart: CFTimeInterval = 0
    private let rampDuration: CFTimeInterval = 0.14

    init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        else { return }
        if let g = dlsym(h, "DisplayServicesGetBrightness") { getFn = unsafeBitCast(g, to: GetFn.self) }
        if let s = dlsym(h, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(s, to: SetFn.self) }
    }

    private var display: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n = UInt32(0)
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    var canControl: Bool { getFn != nil && setFn != nil && display != nil }

    var brightness: Double {
        guard let getFn, let id = display else { return 0 }
        var v = Float(0)
        return getFn(id, &v) == 0 ? Double(v) : 0
    }

    /// Glide to the new level over ~140ms at the display's full refresh rate
    /// (120Hz on ProMotion) — the way macOS eases it, not a hard jump.
    func set(brightness target: Double) {
        rampFrom = Float(brightness)
        rampTo = Float(min(1, max(0, target)))
        rampStart = CACurrentMediaTime()
        if ramp == nil, let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            ramp = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let setFn, let id = display else { stopRamp(); return }
        let t = min(1, (CACurrentMediaTime() - rampStart) / rampDuration)
        let eased = Float(1 - pow(1 - t, 3))             // ease-out
        _ = setFn(id, rampFrom + (rampTo - rampFrom) * eased)
        if t >= 1 { stopRamp() }
    }

    private func stopRamp() { ramp?.invalidate(); ramp = nil }
}

// MARK: Media-key tap

final class MediaKeyTap {
    enum Key: Hashable { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }
    /// (key, isKeyDown, isRepeat, fineStep) → true = swallow (we handled it).
    /// Called on the tap's own thread — must be quick and thread-safe.
    var handler: ((Key, Bool, Bool, Bool) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    var isRunning: Bool { tap != nil }

    // Tap-thread state (only touched inside handle()).
    /// Keys whose key-DOWN we swallowed. Only their key-UP may be swallowed;
    /// any other key-up goes through to macOS. If macOS ever saw a down and
    /// not its up, it believes the key is HELD and auto-repeats it forever —
    /// that was the "volume keeps going down by itself" bug.
    private var swallowedDowns = Set<Key>()
    /// Runaway guard: repeats seen for the current press.
    private var repeatCount: [Key: Int] = [:]
    private let maxRepeats = 40

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask: CGEventMask = (1 << 14)   // NSEventTypeSystemDefined
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, refcon in
                                            guard let refcon else { return Unmanaged.passUnretained(event) }
                                            return Unmanaged<MediaKeyTap>.fromOpaque(refcon)
                                                .takeUnretainedValue().handle(type, event)
                                        },
                                        userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        source = src
        // The tap runs on its OWN thread. On the main thread, any moment the
        // app was busy made macOS time the tap out and deliver a key-down to
        // the system — while we still swallowed the matching key-up.
        let th = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "MyNotch.media-keys"
        th.qualityOfService = .userInteractive
        th.start()
        thread = th
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil; source = nil; thread = nil; runLoop = nil
    }

    /// Test hook: push a synthetic media-key event through handle().
    /// Returns true if it would be swallowed (not seen by macOS).
    func testFeed(code: Int, down: Bool, repeat r: Bool, timeout: Bool = false) -> Bool {
        let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8) | (r ? 1 : 0)
        guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          subtype: 8, data1: data1, data2: -1)?.cgEvent else { return false }
        let type: CGEventType = timeout ? .tapDisabledByTimeout : CGEventType(rawValue: 14)!
        return handle(type, ev) == nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // macOS paused the tap. Turn it back on, and forget what we swallowed:
        // during the gap the system may have seen downs, so from here every
        // key-up passes through and nothing can be left "held".
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            swallowedDowns.removeAll()
            repeatCount.removeAll()
            return pass
        }
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        var key: Key?
        var down = false, isRepeat = false
        if type.rawValue == 14 {
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return pass }
            let code = (ns.data1 & 0xFFFF_0000) >> 16
            down = (ns.data1 & 0xFF00) >> 8 == 0xA
            isRepeat = ns.data1 & 0x1 == 1
            switch code {
            case 0: key = .volumeUp
            case 1: key = .volumeDown
            case 7: key = .mute
            case 2: key = .brightnessUp
            case 3: key = .brightnessDown
            default: break
            }
        } else {
            // Some keyboards send brightness as plain key codes.
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: key = .brightnessUp
            case 145: key = .brightnessDown
            default: break
            }
            down = type == .keyDown
            isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        }
        guard let key, let handler else { return pass }

        if !down {
            repeatCount[key] = nil
            // Only swallow an up whose down we swallowed — otherwise macOS
            // needs it to stop its own key repeat.
            guard swallowedDowns.remove(key) != nil else { return pass }
            _ = handler(key, false, false, fine)
            return nil
        }

        if isRepeat {
            // A repeat of a press macOS owns: leave it to macOS.
            guard swallowedDowns.contains(key) else { return pass }
            let n = (repeatCount[key] ?? 0) + 1
            repeatCount[key] = n
            // Runaway guard: a "held" key that never lets go stops counting.
            if n > maxRepeats { return nil }
            _ = handler(key, true, true, fine)
            return nil
        }

        repeatCount[key] = 0
        if handler(key, true, false, fine) {
            swallowedDowns.insert(key)
            return nil
        }
        swallowedDowns.remove(key)
        return pass
    }
}

// MARK: Controller

final class SystemHUD {
    static let shared = SystemHUD()

    let volume = VolumeControl()
    let brightness = BrightnessControl()
    private let tap = MediaKeyTap()
    private var hideWork: DispatchWorkItem?
    private var trustPoll: Timer?
    private var adjustedVolume = false
    private let feedback = NSSound(contentsOfFile:
        "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
        byReference: true)

    /// How long the island stays out after the last press.
    private let holdTime: TimeInterval = 1.5
    private static let step = 1.0 / 16.0       // macOS's own step
    private static let fineStep = 1.0 / 64.0   // ⌥⇧ + key, also like macOS

    var isActive: Bool { tap.isRunning }
    var isTrusted: Bool { AXIsProcessTrusted() }

    private init() {
        tap.handler = { [weak self] key, down, rep, fine in self?.handle(key, down: down, repeat: rep, fine: fine) ?? false }
        volume.onDeviceChange = { [weak self] in
            guard let self, self.volume.isHeadphones else { return }
            let name = self.volume.deviceName, symbol = self.volume.deviceSymbol
            // Same card as macOS's own: who connected and how charged each bud is.
            let battery = DeviceBattery.text(forAudioDevice: name)
            Toasts.shared.show(title: name, subtitle: ["Connected", battery].compactMap { $0 }.joined(separator: " · "),
                               icon: "device:" + symbol, sound: nil)
        }
        volume.onExternalChange = { [weak self] in
            guard let self, Prefs.shared.systemHUD else { return }
            Self.log("external volume change")
            self.show(.volume)
        }
    }

    /// Start (or stop) according to Settings. Asks for Accessibility ONCE
    /// ever; after that it just quietly waits until access is granted.
    func sync() {
        guard Prefs.shared.systemHUD else {
            tap.stop(); trustPoll?.invalidate(); trustPoll = nil
            return
        }
        if tap.start() { trustPoll?.invalidate(); trustPoll = nil; return }
        let askedKey = "askedAccessibility"
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            requestAccess()
        }
        if trustPoll == nil {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.tap.start() { self.trustPoll?.invalidate(); self.trustPoll = nil
                    NotificationCenter.default.post(name: .systemHUDChanged, object: nil) }
            }
            RunLoop.main.add(t, forMode: .common)
            trustPoll = t
        }
    }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // Runs inside the event tap callback: decide fast, do the work right after.
    /// Runs on the media-key tap's own thread (see MediaKeyTap). Decide fast,
    /// then do the actual work on the main thread.
    private func handle(_ key: MediaKeyTap.Key, down: Bool, repeat isRepeat: Bool, fine: Bool) -> Bool {
        guard Prefs.shared.systemHUD else { return false }
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard volume.canControl else { return false }      // let macOS handle it
            if !down {
                // macOS's volume "pop", on release, only if the user has it on.
                if adjustedVolume, key != .mute,
                   UserDefaults(suiteName: ".GlobalPreferences")?.integer(forKey: "com.apple.sound.beep.feedback") == 1 {
                    DispatchQueue.main.async { self.feedback?.stop(); self.feedback?.play() }
                }
                adjustedVolume = false
                return true
            }
            if key == .mute && isRepeat { return true }
            if key != .mute { adjustedVolume = true }   // tap-thread only
            DispatchQueue.main.async { self.applyVolume(key, fine: fine) }
            return true
        case .brightnessUp, .brightnessDown:
            guard brightness.canControl else { return false }
            if down {
                DispatchQueue.main.async { self.applyBrightness(up: key == .brightnessUp, fine: fine) }
            }
            return true
        }
    }

    private func applyVolume(_ key: MediaKeyTap.Key, fine: Bool) {
        Self.log("key \(key) before=\(volume.volume)")
        let step = fine ? Self.fineStep : Self.step
        switch key {
        case .mute:
            volume.set(muted: !volume.muted)
        case .volumeUp:
            volume.set(volume: Self.snap(volume.volume + step, step))
        default:
            volume.set(volume: Self.snap(volume.volume - step, step))
        }
        show(.volume)
    }

    private func applyBrightness(up: Bool, fine: Bool) {
        let step = fine ? Self.fineStep : Self.step
        let target = Self.snap(brightness.brightness + (up ? step : -step), step)
        brightness.set(brightness: target)
        show(.brightness, level: target)
    }

    /// Land exactly on the step grid, like macOS's 16 squares.
    private static func snap(_ v: Double, _ step: Double) -> Double {
        min(1, max(0, (v / step).rounded() * step))
    }

    // MARK: Dragging the slider

    private(set) var dragging = false

    /// Set the level straight from the slider (click or drag), keeping the
    /// pill out until the finger lifts.
    func drag(to fraction: Double) {
        guard let hud = NotchState.shared.hud else { return }
        if !dragging {
            dragging = true; hideWork?.cancel()
            // Keeps the open panel from collapsing mid-drag (which cancels the
            // gesture). The 10 Hz poll clears it if the mouse is released
            // without onEnded ever firing.
            NotchState.shared.interacting = true
        }
        let f = min(1, max(0, fraction))
        switch hud.kind {
        case .volume:
            volume.set(volume: f)
            if f > 0.001, volume.muted { volume.set(muted: false) }
            NotchState.shared.hud = HUDState(kind: .volume, level: f, muted: f <= 0.001, device: hud.device)
        case .brightness:
            brightness.set(brightness: f)
            NotchState.shared.hud = HUDState(kind: .brightness, level: f)
        }
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        NotchState.shared.interacting = false
        if NotchState.shared.hud?.kind == .volume,
           UserDefaults(suiteName: ".GlobalPreferences")?.integer(forKey: "com.apple.sound.beep.feedback") == 1 {
            feedback?.stop(); feedback?.play()      // the macOS volume "pop", like its own slider
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard self?.dragging == false else { return }
            withAnimation(NotchMotion.collapse) { NotchState.shared.hud = nil }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + holdTime, execute: w)
    }

    /// Clicked away: tuck the volume/brightness pill back in right now.
    func dismissQuickly() {
        hideWork?.cancel()
        if dragging { dragging = false; NotchState.shared.interacting = false }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) { NotchState.shared.hud = nil }
    }

    /// Show (or update) the island HUD, then tuck it away after a pause.
    static let dbg = ProcessInfo.processInfo.environment["MYNOTCH_HUDLOG"] == "1"
    static func log(_ m: String) {
        if dbg { FileHandle.standardError.write(String(format: "HUD %.3f %@\n", CACurrentMediaTime(), m).data(using: .utf8)!) }
    }

    func show(_ kind: HUDKind, level: Double? = nil) {
        if dragging { return }       // the slider is in charge right now
        let s = NotchState.shared
        let new: HUDState = kind == .volume
            ? HUDState(kind: .volume, level: volume.volume, muted: volume.muted || volume.volume <= 0.001,
                       device: volume.deviceSymbol)
            : HUDState(kind: .brightness, level: level ?? brightness.brightness)
        if s.hud?.kind != new.kind || s.hud == nil {
            withAnimation(NotchMotion.morph) { s.hud = new }      // island springs out
        } else {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { s.hud = new }  // bar glides
        }
        Self.log("show \(kind) level=\(new.level) muted=\(new.muted)")
        scheduleHide()
    }

    /// Debug: drive the HUD without the event tap (MYNOTCH_KEYS="volup,volup,bridown").
    func runDebugKeys(_ spec: String) {
        let map: [String: MediaKeyTap.Key] = ["volup": .volumeUp, "voldown": .volumeDown, "mute": .mute,
                                              "briup": .brightnessUp, "bridown": .brightnessDown]
        for (i, name) in spec.split(separator: ",").enumerated() {
            guard let key = map[String(name)] else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(i) * 0.35) {
                _ = self.handle(key, down: true, repeat: false, fine: false)
                _ = self.handle(key, down: false, repeat: false, fine: false)
            }
        }
    }
}

extension Notification.Name {
    static let systemHUDChanged = Notification.Name("MyNotchSystemHUDChanged")
}

// MARK: - The island HUD view

/// What the island shows while you press volume/brightness. It stays level
/// with the notch: the icon sits in the left wing, the level bar and the
/// number in the right wing, the hardware notch in the gap between them.
struct HUDIslandContent: View {
    let hud: HUDState
    /// Width of the hardware notch to leave empty in the middle (0 = a
    /// free-standing pill, used when the panel is already open).
    let notchGap: CGFloat

    private var symbol: String {
        if hud.kind == .brightness {
            return hud.level < 0.34 ? "sun.min.fill" : "sun.max.fill"
        }
        if hud.muted { return "speaker.slash.fill" }
        if hud.device != "speaker" && hud.device != "tv" { return hud.device }   // AirPods model, Beats…
        return "speaker.wave.3.fill"
    }

    private var shown: Double { hud.muted ? 0 : hud.level }

    var body: some View {
        HStack(spacing: 0) {
            // Larger, with hierarchical shading so AirPods/speaker glyphs read
            // as real objects instead of flat 11pt marks.
            Image(systemName: symbol, variableValue: hud.kind == .volume && !hud.muted ? hud.level : 1)
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(hud.muted ? 0.55 : 1))
                .frame(width: 26, height: 22)
                .contentTransition(.symbolEffect(.replace))
                .padding(.leading, 10)
            Spacer(minLength: notchGap == 0 ? 12 : notchGap)
            HStack(spacing: 6) {
                // Click or drag the slider to set the level directly. The
                // visible bar is 6pt; the grab area is the full island height.
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: max(6, g.size.width * CGFloat(shown)))
                            .opacity(hud.muted ? 0 : 1)
                    }
                    .frame(height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in SystemHUD.shared.drag(to: Double(v.location.x / g.size.width)) }
                            .onEnded { _ in SystemHUD.shared.endDrag() }
                    )
                }
                .frame(width: 48)
                // One line, always — "100" used to wrap onto two lines.
                Text("\(Int(shown * 100 + 0.5))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 26, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .padding(.trailing, 11)
        }
        .frame(maxHeight: .infinity)
    }
}
