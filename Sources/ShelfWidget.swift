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

    private let storeKey = "shelfPaths"

    init() { restore() }

    func add(_ urls: [URL]) {
        var added = false
        for url in urls {
            // Skip exact duplicates already on the shelf.
            guard !items.contains(where: { $0.url == url }) else { continue }
            let item = ShelfItem(url: url)
            items.append(item)
            loadThumb(for: item)
            added = true
        }
        if added {
            persist()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbs[item.id] = nil
        persist()
    }

    func clear() {
        items.removeAll()
        thumbs.removeAll()
        persist()
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
                        HStack(spacing: 10) {
                            ForEach(controller.items) { item in
                                ShelfTile(item: item,
                                          thumb: controller.thumbs[item.id],
                                          onRemove: { controller.remove(item) },
                                          onReveal: { controller.revealInFinder(item) })
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                }
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

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, .black.opacity(0.75))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
            Text(item.name)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 62)
        }
        // Drag back OUT to Finder, Mail, anywhere.
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { onReveal() }
        .help(item.url.path)
    }
}
