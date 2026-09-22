import SwiftUI

// The notch silhouette: square top corners (flush to the screen edge),
// rounded bottom corners. The radius animates with the size.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }
}

struct NotchRootView: View {
    @ObservedObject private var state = NotchState.shared
    @StateObject private var camera = CameraController()
    @StateObject private var calendar = CalendarController()
    @ObservedObject private var music = MusicController.shared
    @StateObject private var turntable = Turntable()
    @ObservedObject private var shelf = ShelfController.shared

    // Hover open/close is driven by AppKit (NotchController), not SwiftUI —
    // onHover is unreliable on a view that resizes while you interact with it.
    private static let anim = Animation.spring(response: 0.36, dampingFraction: 0.8)

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            notch
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundColor(.white)
        .onChange(of: state.expanded) { _, expanded in
            if expanded && state.selected == .mirror { camera.start() }
            if !expanded { camera.stop() }
            syncTurntable()
        }
        .onChange(of: state.selected) { _, kind in
            if kind == .mirror && state.expanded { camera.start() } else { camera.stop() }
            syncTurntable()
        }
        .onChange(of: music.now?.isPlaying) { _, _ in syncTurntable() }
        .onAppear {
            calendar.requestAndLoad()
            camera.prepare()        // pre-configure so the Mirror opens faster
            music.scratch.warm()    // pre-synthesize the jog whir off-thread
        }
    }

    private func toggleExtend() { withAnimation(Self.anim) { state.extended.toggle() } }

    // Spin the record only when the music panel is actually visible & playing.
    private func syncTurntable() {
        turntable.playing = state.expanded && state.selected == .music && (music.now?.isPlaying ?? false)
    }

    private var notch: some View {
        let expanded = state.expanded
        let visible = expanded ? state.openSize : state.collapsedVisibleSize
        // Same radius whether music is active or not — less rounding means
        // less rounded-corner area where the translucent menu bar peeks
        // through around our opaque black, which is most of the mismatch.
        let collapsedRadius: CGFloat = state.peeking ? 12 : 10
        let shape = NotchShape(bottomRadius: expanded ? 30 : collapsedRadius)

        return ZStack(alignment: .top) {
            shape.fill(Color.black)             // pure, fully opaque black
            if expanded {
                expandedPanel
                    .frame(width: state.openSize.width, height: state.openSize.height)
                    .transition(.opacity)
            } else if state.musicActive {
                // Dynamic-island: album thumb + EQ bars flanking the notch.
                MusicIslandContent(controller: music, notchGap: state.notchSize.width)
                    .frame(width: visible.width, height: visible.height)
                    .transition(.opacity)
            }
        }
        .frame(width: visible.width, height: visible.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(expanded ? 0.5 : (state.peeking ? 0.35 : 0)),
                radius: expanded ? 28 : 10, x: 0, y: expanded ? 14 : 4)
    }

    private var expandedPanel: some View {
        VStack(spacing: 10) {
            // Tabs flank the hardware notch: mirror + music on the left,
            // calendar on the right, the notch sitting in the gap between.
            HStack(spacing: 2) {
                sideTab(.mirror)
                sideTab(.music)
                Spacer(minLength: state.notchSize.width - 20)
                sideTab(.shelf)
                sideTab(.calendar)
            }
            .frame(height: state.notchSize.height)

            // Selected widget, directly on black (no gray card).
            Group {
                switch state.selected {
                case .mirror:   MirrorPanel(controller: camera)
                case .music:    MusicPanel(controller: music, turntable: turntable)
                case .shelf:    ShelfPanel(controller: shelf)
                case .calendar: CalendarPanel(controller: calendar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 0)
        .padding(.bottom, 16)
        // Tap-to-extend handle pinned to the bottom edge.
        .overlay(alignment: .bottom) {
            Button(action: toggleExtend) {
                Image(systemName: state.extended ? "chevron.compact.up" : "chevron.compact.down")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(width: 80, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.extended ? "Show less" : "Show more")
            .padding(.bottom, 1)
        }
    }

    // Icon button that sits beside the notch — active tab gets the glass pill.
    private func sideTab(_ kind: WidgetKind) -> some View {
        let active = state.selected == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { state.selected = kind }
        } label: {
            Group {
                if active {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 24)
                        .darkGlass(Capsule(), intensity: 0.9)
                } else {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 36, height: 24)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind.title)
    }
}
