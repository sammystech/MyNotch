import SwiftUI

// iOS Settings, in the dark: inset-grouped glass cards, coloured squircle
// icon tiles, and iOS switches — all on pure black.
struct SettingsPanel: View {
    @ObservedObject private var settings = Prefs.shared
    @ObservedObject private var shelf = ShelfController.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        ZStack {
            Color.black
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    header

                    card {
                        row("Open at Login", "power", .gray, $settings.launchAtLogin)
                        separator
                        row("Haptic Feedback", "hand.tap.fill", .blue, $settings.haptics)
                    }

                    card {
                        row("Music in the Notch", "music.note", .pink, $settings.musicIsland)
                        separator
                        row("Scratch Sound", "waveform", .orange, $settings.scratchSound)
                    }

                    card {
                        row("Open Tray on Hover", "tray.full.fill", .teal, $settings.shelfAutoOpen)
                        separator
                        HStack(spacing: 10) {
                            tile("doc.on.doc.fill", .indigo)
                            Text(shelf.items.isEmpty ? "Tray is empty"
                                 : "^[\(shelf.items.count) file](inflect: true) in the tray")
                                .font(.system(size: 11.5))
                                .foregroundColor(.white.opacity(0.9))
                            Spacer()
                            Button("Empty") { shelf.clear() }
                                .buttonStyle(PressStyle(scale: 0.92))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(red: 1, green: 0.42, blue: 0.4)
                                    .opacity(shelf.items.isEmpty ? 0.3 : 1))
                                .disabled(shelf.items.isEmpty)
                        }
                        .padding(.vertical, 6)
                    }

                    HStack {
                        Button { NSApp.terminate(nil) } label: {
                            Label("Quit My Notch", systemImage: "power")
                        }
                        .buttonStyle(PressStyle(scale: 0.94))
                        Spacer()
                        Link(destination: URL(string: "https://github.com/\(Updater.repo)")!) {
                            Label("GitHub", systemImage: "arrow.up.right")
                                .labelStyle(TrailingIconLabel())
                        }
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("My Notch")
                    .font(.system(size: 13, weight: .semibold))
                Text("Version \(version)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            GlassPillButton(title: "Check for Updates", symbol: "arrow.down.circle.fill") {
                Updater.shared.checkNow()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard()
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .glassCard()
    }

    // Hairline that starts after the icon tile, like iOS.
    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            .padding(.leading, 30)
    }

    private func tile(_ symbol: String, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
            .fill(LinearGradient(colors: [color, color.opacity(0.78)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .frame(width: 20, height: 20)
            .overlay(Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white))
    }

    private func row(_ title: String, _ symbol: String, _ color: Color, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            tile(symbol, color)
            Text(title)
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.92))
            Spacer()
            Toggle("", isOn: value)
                .toggleStyle(IslandSwitchStyle())
                .labelsHidden()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.title; configuration.icon.font(.system(size: 8.5, weight: .bold)) }
    }
}
