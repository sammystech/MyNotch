import SwiftUI

struct SettingsPanel: View {
    @ObservedObject private var settings = Prefs.shared
    @ObservedObject private var shelf = ShelfController.shared
    @ObservedObject private var state = NotchState.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        ZStack {
            Color.black
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Version + update
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("MyNotch \(version)")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Up to date checks run daily")
                                .font(.system(size: 9.5))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Spacer()
                        Button("Check for Updates") { Updater.shared.checkNow() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .darkGlass(Capsule(), intensity: 0.9)
                    }
                    .padding(.bottom, 10)

                    divider

                    toggle("Open at login", "power", $settings.launchAtLogin)
                    toggle("Haptic feedback", "hand.tap", $settings.haptics)
                    toggle("Show music in the notch", "music.note", $settings.musicIsland)
                    toggle("Scratch sound when scrubbing", "waveform", $settings.scratchSound)
                    toggle("Open shelf on hover", "tray.full", $settings.shelfAutoOpen)

                    divider

                    HStack {
                        Label("\(shelf.items.count) on the shelf", systemImage: "tray")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Button("Empty Shelf") { shelf.clear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(shelf.items.isEmpty ? 0.25 : 0.8))
                            .disabled(shelf.items.isEmpty)
                    }
                    .padding(.vertical, 7)

                    divider

                    HStack {
                        Button("Quit MyNotch") { NSApp.terminate(nil) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                        Link("GitHub", destination: URL(string: "https://github.com/\(Updater.repo)")!)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.top, 7)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }

    private func toggle(_ title: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 15)
            Text(title)
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            Toggle("", isOn: value)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(.white.opacity(0.85))
        }
        .padding(.vertical, 6)
    }
}
