import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Model

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    static func == (a: ShelfItem, b: ShelfItem) -> Bool { a.id == b.id }
}

// MARK: - Controller

/// Holds files dropped on the notch. The panel lives on every Space
/// (canJoinAllSpaces), so you can drop here, switch desktops, and drag back out.
final class ShelfController: ObservableObject {
    static let shared = ShelfController()

    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbs: [UUID: NSImage] = [:]
    @Published var landed: UUID?          // most recent arrival, for the drop pop

    private let storeKey = "shelfPaths"

    init() { restore() }

    func add(_ urls: [URL]) {
        var new: [ShelfItem] = []
        for url in urls {
            // Skip exact duplicates already on the shelf.
            guard !items.contains(where: { $0.url == url }) else { continue }
            new.append(ShelfItem(url: url))
        }
        guard !new.isEmpty else { return }

        // Bouncy spring so files visibly "land" on the shelf.
        withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) {
            items.append(contentsOf: new)
        }
        new.forEach(loadThumb)
        landed = new.last?.id
        persist()
        syncState()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        // Clear the "just landed" marker after the pop finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.landed == new.last?.id { self?.landed = nil }
        }
    }

    /// Mirrors emptiness into NotchState — drives hover-to-open and panel height.
    private func syncState() {
        let has = !items.isEmpty
        if NotchState.shared.shelfHasFiles != has {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                NotchState.shared.shelfHasFiles = has
            }
        }
    }

    func remove(_ item: ShelfItem) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            items.removeAll { $0.id == item.id }
        }
        thumbs[item.id] = nil
        persist()
        syncState()
    }

    func clear() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            items.removeAll()
        }
        thumbs.removeAll()
        persist()
        syncState()
    }

    /// Hand files to AirDrop — the system share sheet takes it from there.
    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let svc = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)   // the AirDrop picker needs a key app
        svc.perform(withItems: urls)
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }

    func revealInFinder(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Thumbnails

    private func loadThumb(for item: ShelfItem) {
        // Generic icon immediately so a tile never renders empty…
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.size = NSSize(width: 64, height: 64)
        thumbs[item.id] = icon

        // …then upgrade to a real QuickLook preview when one exists.
        let req = QLThumbnailGenerator.Request(
            fileAt: item.url, size: CGSize(width: 128, height: 128),
            scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep else { return }
            let img = rep.nsImage
            DispatchQueue.main.async {
                guard let self, self.items.contains(where: { $0.id == item.id }) else { return }
                self.thumbs[item.id] = img
            }
        }
    }

    // MARK: Persistence (survives relaunch; drops anything since deleted/moved)

    private func persist() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: storeKey)
    }

    private func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        for p in paths where FileManager.default.fileExists(atPath: p) {
            let item = ShelfItem(url: URL(fileURLWithPath: p))
            items.append(item)
            loadThumb(for: item)
        }
        if items.count != paths.count { persist() }   // prune stale entries
        syncState()
    }
}

// MARK: - Panel
//
// Modelled on NotchNook's Tray: two drop boxes side by side — AirDrop on the
// left, the Files Tray on the right. While a file is dragged over, the box
// under it lights up; files sit in a two-row grid of big icons with their
// names underneath, and hovering one reveals its remove button.

struct ShelfPanel: View {
    @ObservedObject var controller: ShelfController
    @ObservedObject private var state = NotchState.shared

    var body: some View {
        HStack(spacing: 8) {
            AirDropBox(controller: controller)
                .frame(width: 92)
            TrayBox(controller: controller)
        }
        .padding(.vertical, 2)
        .background(Color.black)
    }
}

/// Shared chrome for both drop boxes: faint fill, dashed rim at rest, solid
/// bright rim + lift when a drag is over it.
private struct DropBox: ViewModifier {
    let dragging: Bool      // a file drag is over the panel
    let targeted: Bool      // …and over THIS box
    let dashed: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(Color.white.opacity(targeted ? 0.1 : (dragging ? 0.05 : 0.035))))
            .overlay(
                shape.strokeBorder(
                    Color.white.opacity(targeted ? 0.55 : (dragging ? 0.22 : 0.12)),
                    style: StrokeStyle(lineWidth: targeted ? 1.5 : 1,
                                       dash: (dashed && !targeted) ? [5, 4] : []))
            )
            .scaleEffect(targeted ? 1.03 : 1)
            .animation(NotchMotion.nudge, value: targeted)
            .animation(NotchMotion.nudge, value: dragging)
    }
}

private struct AirDropBox: View {
    @ObservedObject var controller: ShelfController
    @ObservedObject private var state = NotchState.shared

    var body: some View {
        let targeted = state.dropTarget == .airdrop
        Button {
            // Click = AirDrop everything on the tray.
            controller.airDrop(controller.items.map(\.url))
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.62, blue: 1),
                                                      Color(red: 0.1, green: 0.42, blue: 0.95)],
                                             startPoint: .top, endPoint: .bottom))
                        .opacity(targeted ? 1 : 0.9)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 38, height: 38)
                .shadow(color: Color.blue.opacity(targeted ? 0.6 : 0.25), radius: targeted ? 10 : 5)
                .scaleEffect(targeted ? 1.1 : 1)
                Text("AirDrop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(targeted ? 1 : 0.75))
            }
            .modifier(DropBox(dragging: state.dragActive, targeted: targeted, dashed: true))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .disabled(controller.items.isEmpty && !state.dragActive)
        .help(controller.items.isEmpty ? "Drop files here to AirDrop them" : "AirDrop everything on the tray")
        // Publish where the box is so AppKit's drop handler can hit-test it.
        .background(GeometryReader { g in
            Color.clear
                .onAppear { state.airDropRect = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in state.airDropRect = f }
                .onDisappear { state.airDropRect = .zero }
        })
    }
}

private struct TrayBox: View {
    @ObservedObject var controller: ShelfController
    @ObservedObject private var state = NotchState.shared

    var body: some View {
        let targeted = state.dropTarget == .tray || (state.dragActive && state.dropTarget == nil)
        ZStack {
            if controller.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: targeted ? "arrow.down.doc.fill" : "tray.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(targeted ? 0.95 : 0.4))
                        .scaleEffect(targeted ? 1.12 : 1)
                        .offset(y: targeted ? 3 : 0)
                    Text(targeted ? "Drop to add" : "Files Tray")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(targeted ? 0.95 : 0.7))
                    if !targeted {
                        Text("Drag files here to keep them handy")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
                .animation(NotchMotion.nudge, value: targeted)
            } else {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: rows, alignment: .top, spacing: 6) {
                            ForEach(controller.items) { item in
                                TrayFileView(item: item,
                                             thumb: controller.thumbs[item.id],
                                             controller: controller,
                                             justLanded: controller.landed == item.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    HStack {
                        Text("^[\(controller.items.count) file](inflect: true)")
                        Spacer()
                        Button("Clear All") { controller.clear() }
                            .buttonStyle(PressStyle(scale: 0.92))
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 7)
                }
            }
        }
        .modifier(DropBox(dragging: state.dragActive, targeted: targeted,
                          dashed: controller.items.isEmpty))
    }

    // Two rows once the tray is roomy (NotchNook's default grid height), one
    // in the compact panel.
    private var rows: [GridItem] {
        let n = state.shelfHasFiles && !state.extended ? 2 : (state.extended ? 3 : 1)
        return Array(repeating: GridItem(.fixed(TrayFileView.height), spacing: 4), count: n)
    }
}

// Hover state without @State (SwiftUI's @State is a macro — unavailable
// without Xcode's plugin host).
private final class HoverBox: ObservableObject { @Published var on = false }

private struct TrayFileView: View {
    static let height: CGFloat = 86
    let item: ShelfItem
    let thumb: NSImage?
    @ObservedObject var controller: ShelfController
    var justLanded: Bool = false
    @StateObject private var hover = HoverBox()

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 54, height: 54)
                .padding(4)

                if hover.on {
                    Button { controller.remove(item) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color(white: 0.2)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6))
                            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    }
                    .buttonStyle(PressStyle())
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            Text(item.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 70, height: 24, alignment: .top)
        }
        .frame(width: 76, height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hover.on ? 0.08 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { h in withAnimation(NotchMotion.press) { hover.on = h } }
        // Lands with a spring pop, then settles.
        .scaleEffect(justLanded ? 1.14 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.5), value: justLanded)
        .transition(.asymmetric(
            insertion: .modifier(active: BloomModifier(progress: 0), identity: BloomModifier(progress: 1))
                .combined(with: .offset(y: -18)),
            removal: .scale(scale: 0.6).combined(with: .opacity)))
        // Drag back OUT to Finder, Mail, anywhere.
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { controller.open(item) }
        .contextMenu {
            Button("Open") { controller.open(item) }
            Button("Show in Finder") { controller.revealInFinder(item) }
            Button("AirDrop") { controller.airDrop([item.url]) }
            Divider()
            Button("Remove from Tray") { controller.remove(item) }
        }
        .help(item.url.path)
    }
}
