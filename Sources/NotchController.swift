import AppKit
import SwiftUI
import Combine

// Borderless, floating panel that sits over the menu bar / notch.
// canBecomeKey is false: nothing here takes text input, and a nonactivating
// panel that grabs key focus would steal it from the frontmost app.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Content view that drives hover via an AppKit tracking area (reliable, unlike
// SwiftUI onHover on a resizing view), forwards clicks on the collapsed notch,
// and passes events through the transparent margins so apps below stay usable.
final class HitContainerView: NSView {
    var hoverChanged: ((Bool) -> Void)?
    var clickAction: (() -> Void)?
    private var tracking: NSTrackingArea?

    // Rect helpers, bottom-left origin, anchored top-center. Heights are +1 so
    // the screen's very top pixel row counts as inside — NSRect.contains
    // excludes the max edge, and a cursor slammed against the top of the
    // screen sits exactly on it (that's the natural way to hit the notch).
    private func band(_ size: CGSize) -> NSRect {
        NSRect(x: (bounds.width - size.width) / 2,
               y: bounds.height - size.height,
               width: size.width, height: size.height + 1)
    }

    // Hover: exactly the visible black area — leaving it closes instantly.
    // (Consequence: "show less" shrinks the panel out from under the cursor,
    // which then counts as leaving and closes it. Consistent with the rule.)
    private func hoverRect() -> NSRect {
        let s = NotchState.shared
        return band(s.expanded ? s.openSize : s.collapsedHitSize)
    }

    // Clicks: always against what's visibly there.
    private func hitRect() -> NSRect {
        let s = NotchState.shared
        return band(s.expanded ? s.openSize : s.collapsedHitSize)
    }

    // The album-art (left wing) of the collapsed music island — clicking here
    // toggles play/pause instead of opening the panel.
    private func artWingRect() -> NSRect? {
        let s = NotchState.shared
        guard s.musicActive, !s.expanded else { return nil }
        let vis = s.collapsedVisibleSize
        let wing = (vis.width - s.notchSize.width) / 2
        guard wing > 6 else { return nil }
        return NSRect(x: (bounds.width - vis.width) / 2,
                      y: bounds.height - vis.height,
                      width: wing, height: vis.height + 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: hoverRect(),
                               options: [.activeAlways, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
        evaluate()
    }

    // Re-measure tracking after the open/close/island state changes.
    func refresh() { updateTrackingAreas() }

    // Sync hover state to where the cursor actually is right now.
    private func evaluate() {
        guard let win = window else { return }
        let p = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        hoverChanged?(hoverRect().contains(p))
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitRect().contains(point) else { return nil }
        // Collapsed: the whole notch is one button — take the event ourselves
        // so mouseDown opens the panel. Open: let SwiftUI's controls have it.
        return NotchState.shared.expanded ? super.hitTest(point) : self
    }

    override func mouseDown(with event: NSEvent) {
        if NotchState.shared.expanded { super.mouseDown(with: event); return }
        // Collapsed: clicking the album art toggles playback; anywhere else opens.
        let p = convert(event.locationInWindow, from: nil)
        if let art = artWingRect(), art.contains(p) {
            MusicController.shared.playPause()
        } else {
            clickAction?()
        }
    }

    // Accessory app / non-activating panel: without this, the FIRST click while
    // another app is focused is eaten as an activation click and the notch
    // doesn't open. This makes every click register on the first press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: File shelf drag & drop
    //
    // Dragging files onto the notch opens it straight to the Shelf. The panel
    // joins every Space, so you can drop here, switch desktops, and drag the
    // files back out somewhere else.
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                      options: opts) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(from: sender).isEmpty else { return [] }
        onDragEnter?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragExit?() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !urls(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let found = urls(from: sender)
        guard !found.isEmpty else { return false }
        onDrop?(found)
        return true
    }
}

final class NotchController {
    private let panel: NotchPanel
    private let container: HitContainerView
    private let state = NotchState.shared
    private var bag = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var lastInside = false

    // Smooth, with a gentle settle — a touch slower than instant.
    private static let anim = Animation.spring(response: 0.36, dampingFraction: 0.8)

    init() {
        NotchState.shared.notchSize = Self.detectNotch()
        let size = state.windowSize
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // One level ABOVE .statusBar: menu-bar status icons live at exactly
        // .statusBar, and a same-level tie lets them draw over the island.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                        // shadow is drawn in SwiftUI
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true

        container = HitContainerView(frame: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: NotchRootView())
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container

        container.hoverChanged = { [weak self] inside in self?.setHover(inside) }
        container.clickAction = { [weak self] in self?.openPanel() }

        container.registerForDraggedTypes([.fileURL])
        container.onDragEnter = { [weak self] in self?.beginFileDrag() }
        container.onDragExit  = { [weak self] in self?.endFileDrag() }
        container.onDrop = { [weak self] urls in
            ShelfController.shared.add(urls)
            self?.endFileDrag(keepOpen: true)
        }

        // Whenever any geometry-affecting state changes, remeasure tracking.
        Publishers.MergeMany(
            state.$expanded.map { _ in () }.eraseToAnyPublisher(),
            state.$extended.map { _ in () }.eraseToAnyPublisher(),
            state.$peeking.map { _ in () }.eraseToAnyPublisher(),
            state.$musicActive.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
            DispatchQueue.main.async { self?.container.refresh() }
        }
        .store(in: &bag)

        // Re-measure the notch and re-center if displays/resolution change.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.state.notchSize = Self.detectNotch()
            self.positionAtTop()
            self.container.refresh()
        }

        // Safety-net poll: enter/exit events don't fire for warped cursors,
        // space switches, or a cursor already parked on the notch at launch.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollCursor()
        }
    }

    func show() {
        positionAtTop()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.container.refresh() }
    }

    private func pollCursor() {
        let live = state.expanded ? state.openSize : state.collapsedHitSize
        let f = panel.frame
        // +1 above the screen top so the topmost cursor row counts as inside.
        let rect = NSRect(x: f.midX - live.width / 2, y: f.maxY - live.height,
                          width: live.width, height: live.height + 1)
        let mouse = NSEvent.mouseLocation

        // Safety net for a stuck drag. `interacting` (set while scrubbing the
        // progress bar or jogging the record) suppresses auto-close, and it's
        // normally cleared in DragGesture.onEnded — but SwiftUI does NOT send
        // onEnded when a gesture is CANCELLED (Mission Control, a hot corner,
        // a Space switch mid-drag). That left `interacting` true forever: the
        // notch could never close again and, if the jog had paused playback,
        // music stayed paused with no way to resume. If no mouse button is
        // actually held, no drag is in progress — recover.
        if state.interacting && NSEvent.pressedMouseButtons == 0 {
            state.interacting = false
            MusicController.shared.abortInteraction()
        }

        setHover(rect.contains(mouse))

        // Precise hover over the island's album art (left wing) — drives the
        // play/pause overlay, only when the cursor is actually ON the art.
        var overArt = false
        if state.musicActive && !state.expanded {
            let vis = state.collapsedVisibleSize
            let wing = (vis.width - state.notchSize.width) / 2
            if wing > 6 {
                let artRect = NSRect(x: f.midX - vis.width / 2, y: f.maxY - vis.height,
                                     width: wing, height: vis.height + 1)
                overArt = artRect.contains(mouse)
            }
        }
        if state.hoveringArt != overArt {
            withAnimation(.easeOut(duration: 0.15)) { state.hoveringArt = overArt }
        }
    }

    // Gated transition log for automated testing (MYNOTCH_TESTLOG=1).
    private static let testLog = ProcessInfo.processInfo.environment["MYNOTCH_TESTLOG"] == "1"
    private func logTransition(_ inside: Bool) {
        guard Self.testLog else { return }
        let m = NSEvent.mouseLocation
        FileHandle.standardError.write(
            "HOVER inside=\(inside) cursor=(\(Int(m.x)),\(Int(m.y))) expanded=\(state.expanded) peeking=\(state.peeking) island=\(state.musicActive)\n"
                .data(using: .utf8)!)
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }

    // Hover in → peek (slight grow + haptic tick). Click → open. Hover out →
    // un-peek, and if open, close after a short grace period.
    // Change-driven: repeated same-state calls (e.g. from the poll) are
    // ignored so they can't keep re-deferring the pending close.
    private func setHover(_ inside: Bool) {
        guard inside != lastInside else { return }
        lastInside = inside
        logTransition(inside)
        if inside {
            // Files waiting on the shelf? Hovering opens it straight away so
            // grabbing them back out is one motion, no click needed.
            if !state.expanded && state.shelfHasFiles {
                withAnimation(Self.anim) {
                    state.peeking = false
                    state.selected = .shelf
                    state.expanded = true
                }
                haptic(.alignment)
                return
            }
            if !state.expanded && !state.peeking {
                haptic(.alignment)
                withAnimation(Self.anim) { state.peeking = true }
            }
        } else {
            // Don't close while the user is dragging something inside (e.g.
            // scrubbing the music progress bar) even if the cursor strays out.
            if state.interacting || state.debugPinned || state.dragActive { return }
            // Close the instant the cursor leaves the black area — no grace
            // delay. (Edge flicker was fixed by the +1pt top-edge rects.)
            withAnimation(Self.anim) {
                if state.peeking { state.peeking = false }
                if state.expanded {
                    state.expanded = false
                    state.extended = false
                }
            }
        }
    }

    // A drag is hovering: pop the notch open on the Shelf so there's a big
    // target to drop into.
    private func beginFileDrag() {
        withAnimation(Self.anim) {
            state.dragActive = true
            state.selected = .shelf
            state.peeking = false
            state.expanded = true
        }
    }

    private func endFileDrag(keepOpen: Bool = false) {
        withAnimation(Self.anim) { state.dragActive = false }
        guard !keepOpen else { return }
        // Cursor may already be off the panel — let the normal hover rules decide.
        lastInside = true            // force the next evaluation to re-check
        pollCursor()
    }

    private func openPanel() {
        guard !state.expanded else { return }
        // No artificial haptic here — the trackpad's own click is the
        // feedback; adding .levelChange on top read as a hard double-click.
        withAnimation(Self.anim) {
            state.peeking = false
            // Clicking the island while music plays goes straight to Music,
            // like tapping the iPhone Dynamic Island.
            if state.musicActive { state.selected = .music }
            state.expanded = true
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    // Fixed-size window, flush to the very top, centered horizontally.
    private func positionAtTop() {
        guard let screen = targetScreen()?.frame else { return }
        let size = state.windowSize
        let x = screen.midX - size.width / 2
        let y = screen.maxY - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // Measure the real hardware notch so the collapsed pill fits it exactly.
    private static func detectNotch() -> CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 220, height: 32) }
        let top = screen.safeAreaInsets.top
        if top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return CGSize(width: width, height: top)
        }
        // No hardware notch — use a tidy pill.
        return CGSize(width: 220, height: 32)
    }
}
