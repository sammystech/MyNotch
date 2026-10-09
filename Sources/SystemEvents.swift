import AppKit
import IOKit
import IOKit.ps
import IOKit.usb
import IOBluetooth
import Network

// MARK: - Device, Bluetooth, Wi-Fi and power alerts → the notch
//
// Watches for hardware/network changes and pops each one out of the notch:
//   • USB devices plugged in / removed            (IOKit matching notifications)
//   • Bluetooth devices connected / disconnected   (IOBluetooth)
//   • Wi-Fi / internet lost, and back online      (Network.framework path monitor)
//   • Charger plugged in / unplugged              (IOKit power sources)
// AirPods & other headphones are announced by the audio-output switch in
// SystemHUD (with the exact model's glyph), so Bluetooth audio is skipped here
// on connect to avoid a double pop-up.

final class SystemEvents: NSObject {
    static let shared = SystemEvents()

    private var running = false
    private var quietUntil = Date.distantFuture   // swallow the burst of "already connected" at start
    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private var usbNames: [UInt64: String] = [:]  // registry id → product name
    private var btConnect: IOBluetoothUserNotification?
    private var btDisconnects: [IOBluetoothUserNotification] = []
    private var pathMonitor: NWPathMonitor?
    private var online: Bool?
    private var netWork: DispatchWorkItem?
    private var powerSource: CFRunLoopSource?
    private var onAC: Bool?

    func sync() {
        if Prefs.shared.deviceAlerts { start() } else { stop() }
    }

    private func start() {
        guard !running else { return }
        running = true
        quietUntil = Date().addingTimeInterval(3)
        startUSB()
        startBluetooth()
        startNetwork()
        startPower()
        if ProcessInfo.processInfo.environment["MYNOTCH_EVENTLOG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                FileHandle.standardError.write("EVENTS usb=\(usbNames.values.sorted()) bt=\(btDisconnects.count) online=\(String(describing: online)) ac=\(String(describing: onAC)) battery=\(Self.batteryPercent ?? -1)\n".data(using: .utf8)!)
            }
        }
    }

    private func stop() {
        guard running else { return }
        running = false
        if addedIter != 0 { IOObjectRelease(addedIter); addedIter = 0 }
        if removedIter != 0 { IOObjectRelease(removedIter); removedIter = 0 }
        if let p = notifyPort { IONotificationPortDestroy(p); notifyPort = nil }
        btConnect?.unregister(); btConnect = nil
        btDisconnects.forEach { $0.unregister() }; btDisconnects.removeAll()
        pathMonitor?.cancel(); pathMonitor = nil; online = nil
        if let src = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode); powerSource = nil }
    }

    private var quiet: Bool { Date() < quietUntil }

    private func alert(_ title: String, _ subtitle: String, _ symbol: String,
                       tint: String? = nil, check: Bool = false) {
        guard !quiet else { return }
        Toasts.shared.show(title: title, subtitle: subtitle,
                           icon: "device:" + symbol + (tint.map { "#" + $0 } ?? ""),
                           sound: nil, badge: check ? "check" : nil)
    }

    // MARK: USB

    private func startUSB() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                         IOServiceMatching("IOUSBHostDevice"), { refcon, iter in
            Unmanaged<SystemEvents>.fromOpaque(refcon!).takeUnretainedValue().usbAdded(iter)
        }, me, &addedIter)
        usbAdded(addedIter, announce: false)      // arm + record what's already plugged in

        IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                         IOServiceMatching("IOUSBHostDevice"), { refcon, iter in
            Unmanaged<SystemEvents>.fromOpaque(refcon!).takeUnretainedValue().usbRemoved(iter)
        }, me, &removedIter)
        usbRemoved(removedIter, announce: false)
    }

    private func usbAdded(_ iter: io_iterator_t, announce: Bool = true) {
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            guard let name = Self.usbName(service) else { continue }
            usbNames[id] = name
            if announce { alert(name, "Connected", Self.usbSymbol(name), check: true) }
        }
    }

    private func usbRemoved(_ iter: io_iterator_t, announce: Bool = true) {
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            guard let name = usbNames.removeValue(forKey: id) else { continue }
            if announce { alert(name, "Disconnected", Self.usbSymbol(name)) }
        }
    }

    /// A human product name, or nil for things nobody plugged in (hubs, the
    /// Mac's own internal USB devices).
    private static func usbName(_ service: io_service_t) -> String? {
        func prop(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        }
        guard let name = prop("USB Product Name") ?? prop("kUSBProductString"),
              !name.isEmpty else { return nil }
        let n = name.lowercased()
        if n.contains("hub") || n.contains("internal") || n.contains("apple t2") { return nil }
        if let builtIn = IORegistryEntryCreateCFProperty(service, "Built-In" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool, builtIn { return nil }
        return name
    }

    private static func usbSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "computermouse" }
        if n.contains("controller") || n.contains("gamepad") { return "gamecontroller" }
        if n.contains("camera") || n.contains("webcam") { return "web.camera" }
        if n.contains("audio") || n.contains("dac") || n.contains("headset") || n.contains("mic") { return "headphones" }
        if n.contains("ssd") || n.contains("drive") || n.contains("disk") || n.contains("storage")
            || n.contains("flash") || n.contains("t7") || n.contains("t9") || n.contains("sandisk") { return "externaldrive.fill" }
        if n.contains("display") || n.contains("monitor") { return "display" }
        return "cable.connector"
    }

    // MARK: Bluetooth

    private func startBluetooth() {
        btConnect = IOBluetoothDevice.register(forConnectNotifications: self,
                                               selector: #selector(btConnected(_:device:)))
    }

    @objc private func btConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let d = device.register(forDisconnectNotification: self, selector: #selector(btDisconnected(_:device:))) {
            btDisconnects.append(d)
        }
        // Headphones are announced by the audio switch (with the model glyph).
        guard !Self.isAudio(device), !Self.isIgnored(device) else { return }
        alert(device.name ?? "Bluetooth Device", "Connected", Self.btSymbol(device), check: true)
    }

    @objc private func btDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        btDisconnects.removeAll { $0 === note }
        guard !Self.isIgnored(device) else { return }
        let name = device.name ?? "Bluetooth Device"
        let symbol = Self.isAudio(device) ? VolumeControl.headphoneSymbol(for: name) : Self.btSymbol(device)
        alert(name, "Disconnected", symbol)
    }

    /// Things that connect/disconnect constantly on their own and aren't worth
    /// a pop-up — an Apple Watch reconnects every time it wakes.
    private static func isIgnored(_ d: IOBluetoothDevice) -> Bool {
        let n = (d.name ?? "").lowercased()
        return n.contains("apple watch") || n.contains("watch")
            || d.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorWearable)
    }

    private static func isAudio(_ d: IOBluetoothDevice) -> Bool {
        d.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio)
    }

    private static func btSymbol(_ d: IOBluetoothDevice) -> String {
        let n = (d.name ?? "").lowercased()
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return "gamecontroller" }
        if n.contains("pencil") { return "applepencil" }
        if n.contains("watch") { return "applewatch" }
        if n.contains("iphone") { return "iphone" }
        switch d.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorPeripheral): return "keyboard"
        case UInt32(kBluetoothDeviceClassMajorPhone): return "iphone"
        case UInt32(kBluetoothDeviceClassMajorAudio): return "headphones"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    // MARK: Wi-Fi / internet

    private func startNetwork() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.pathChanged(path) }
        }
        m.start(queue: DispatchQueue(label: "mynotch.net"))
        pathMonitor = m
    }

    private func pathChanged(_ path: NWPath) {
        let up = path.status == .satisfied
        let wifi = path.usesInterfaceType(.wifi) || path.availableInterfaces.contains { $0.type == .wifi }
        guard let was = online else { online = up; return }      // first reading: just remember
        guard up != was else { return }
        // Debounce: Wi-Fi often flickers for a second while roaming.
        netWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.online = up
            if up {
                self.alert("Back Online", wifi ? "Wi-Fi connected" : "Connected", "wifi", tint: "34C759", check: true)
            } else {
                self.alert(wifi ? "Wi-Fi Disconnected" : "No Internet", "Your Mac is offline", "wifi.slash", tint: "FF453A")
            }
        }
        netWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    // MARK: Power

    private func startPower() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            Unmanaged<SystemEvents>.fromOpaque(ctx!).takeUnretainedValue().powerChanged()
        }, me)?.takeRetainedValue() else { return }
        powerSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        onAC = Self.isOnAC
    }

    private func powerChanged() {
        let ac = Self.isOnAC
        guard ac != onAC else { return }
        onAC = ac
        if ac {
            // The adapter's details (watts, name) fill in a moment after the
            // plug goes in — wait for them, up to ~4s.
            announceCharger(attempt: 0)
        } else {
            alert("On Battery", Self.batteryPercent.map { "\($0)%" } ?? "", Self.batterySymbol)
        }
    }

    private func announceCharger(attempt: Int) {
        let info = Self.chargerInfo()
        if info.watts == nil && attempt < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.onAC == true else { return }
                self.announceCharger(attempt: attempt + 1)
            }
            return
        }
        let pct = Self.batteryPercent ?? 0
        var parts = [info.port]
        if let w = info.watts { parts.append("\(w)W") }
        if info.charging, let mins = Self.minutesToFull, mins > 0 {
            parts.append(mins >= 60 ? "\(mins / 60) hr \(mins % 60) min to full" : "\(mins) min to full")
        } else if !info.charging, pct < 100 {
            parts.append("charging on hold")
        }
        alert(info.charging ? "Charging · \(pct)%" : "Plugged In · \(pct)%",
              parts.joined(separator: " · "), "battery.100percent.bolt", tint: "34C759", check: true)
    }

    /// Which port the power is coming in on, the adapter's wattage, and
    /// whether the battery is actually taking charge (Optimized Charging can
    /// hold it at 80%). The same IOKit sources power utilities like Vorssaint
    /// read: IOPSCopyExternalPowerAdapterDetails + the AppleSmartBattery entry.
    static func chargerInfo() -> (port: String, watts: Int?, charging: Bool) {
        var watts: Int?
        if let d = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            watts = (d[kIOPSPowerAdapterWattsKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
        }
        let port = magSafeActive ? "MagSafe" : "USB-C"
        let charging = (smartBattery("IsCharging") as? Bool) ?? true
        return (port, watts, charging)
    }

    /// The MagSafe port publishes ConnectionActive in the IORegistry.
    private static var magSafeActive: Bool {
        let match = ["IOPropertyMatch": ["PortTypeDescription": "MagSafe 3"]] as CFDictionary
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iter) }
        var active = false
        while case let s = IOIteratorNext(iter), s != 0 {
            if let v = IORegistryEntryCreateCFProperty(s, "ConnectionActive" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool, v { active = true }
            IOObjectRelease(s)
        }
        return active
    }

    private static func smartBattery(_ key: String) -> Any? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        return IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static var minutesToFull: Int? {
        guard let m = smartBattery("AvgTimeToFull") as? Int, m > 0, m < 65535 else { return nil }
        return m
    }

    private static var isOnAC: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        return type == kIOPMACPowerKey
    }

    private static var batteryPercent: Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
               let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return cur * 100 / max
            }
        }
        return nil
    }

    private static var batterySymbol: String {
        switch batteryPercent ?? 100 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
