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

struct ShelfPanel: View {
    @ObservedObject var controller: ShelfController
    @ObservedObject private var state = NotchState.shared

    var body: some View {
        ZStack {
            Color.black
            if controller.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(state.dragActive ? 0.9 : 0.3))
                    Text(state.dragActive ? "Drop to add" : "Drag files onto the notch")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(state.dragActive ? 0.9 : 0.5))
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("^[\(controller.items.count) file](inflect: true)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                        Button("Clear") { controller.clear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(controller.items) { item in
                                ShelfTile(item: item,
                                          thumb: controller.thumbs[item.id],
                                          onRemove: { controller.remove(item) },
                                          onReveal: { controller.revealInFinder(item) },
                                          justLanded: controller.landed == item.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            // Highlight the whole panel while a drag hovers.
            if state.dragActive {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(3)
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let thumb: NSImage?
    let onRemove: () -> Void
    let onReveal: () -> Void
    var justLanded: Bool = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08))
                    }
                }
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, .black.opacity(0.8))
                }
                .buttonStyle(.plain)
                .offset(x: 7, y: -7)
            }
            Text(item.name)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 92)
        }
        // Pops slightly oversized as it lands, then settles.
        .scaleEffect(justLanded ? 1.12 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: justLanded)
        .transition(.scale(scale: 0.4).combined(with: .opacity))
        // Drag back OUT to Finder, Mail, anywhere.
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { onReveal() }
        .help(item.url.path)
    }
}
