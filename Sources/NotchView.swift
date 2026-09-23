import SwiftUI

// The notch silhouette. Square top edge flush with the screen, continuous
// ("squircle") bottom corners like Apple's hardware, and — when open —
// small concave shoulders at the top so the panel reads as growing OUT of
// the bezel rather than a box pasted under it. Both radii animate.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulder) }
        set { bottomRadius = newValue.first; shoulder = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 4))
        let left = rect.minX + s, right = rect.maxX - s
        let bodyW = right - left
        // Continuous corners bleed further up the sides than a circular arc.
        let r = min(bottomRadius, rect.height / 2.4, bodyW / 2.4)
        let k = r * 1.28        // where the curve starts along each edge
        let c = r * 0.38        // control-point pull toward the corner

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        if s > 0 {
            p.addQuadCurve(to: CGPoint(x: right, y: rect.minY + s),
                           control: CGPoint(x: right, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: right, y: rect.maxY - k))
        p.addCurve(to: CGPoint(x: right - k, y: rect.maxY),
                   control1: CGPoint(x: right, y: rect.maxY - c),
                   control2: CGPoint(x: right - c, y: rect.maxY))
        p.addLine(to: CGPoint(x: left + k, y: rect.maxY))
        p.addCurve(to: CGPoint(x: left, y: rect.maxY - k),
                   control1: CGPoint(x: left + c, y: rect.maxY),
                   control2: CGPoint(x: left, y: rect.maxY - c))
        if s > 0 {
            p.addLine(to: CGPoint(x: left, y: rect.minY + s))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                           control: CGPoint(x: left, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @ObservedObject private var state = NotchState.shared
    @StateObject private var camera = CameraController()
    @StateObject private var calendar = CalendarController()
    @ObservedObject private var music = MusicController.shared
    @StateObject private var turntable = Turntable()
    @ObservedObject private var shelf = ShelfController.shared
    @Namespace private var tabNS

    private static let shoulder: CGFloat = 12

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

    private func toggleExtend() { withAnimation(NotchMotion.morph) { state.extended.toggle() } }

    private func select(_ kind: WidgetKind) {
        guard state.selected != kind else { return }
        withAnimation(NotchMotion.tab) { state.selected = kind }
    }

    // Spin the record only when the music panel is actually visible & playing.
    private func syncTurntable() {
        turntable.playing = state.expanded && state.selected == .music && (music.now?.isPlaying ?? false)
    }

    private var notch: some View {
        let expanded = state.expanded
        let visible = expanded ? state.openSize : state.collapsedVisibleSize
        let flare = expanded ? Self.shoulder : 0
        // Tight radius when collapsed — less rounded-corner area where the
        // translucent menu bar peeks through around our opaque black.
        let radius: CGFloat = expanded ? 32 : (state.peeking ? 12 : 10)
        let shape = NotchShape(bottomRadius: radius, shoulder: flare)

        return ZStack(alignment: .top) {
            shape.fill(Color.black)             // pure, fully opaque black
            if expanded {
                expandedPanel
                    .frame(width: state.openSize.width, height: state.openSize.height)
                    .transition(.bloom)
            } else if state.musicActive {
                // Dynamic-island: album thumb + EQ bars flanking the notch.
                MusicIslandContent(controller: music, notchGap: state.notchSize.width)
                    .frame(width: visible.width, height: visible.height)
                    .transition(.bloom)
            }
        }
        .frame(width: visible.width + flare * 2, height: visible.height)
        .clipShape(shape)
        // Two-layer shadow: a tight contact shadow plus a wide soft one, so
        // the panel floats like a real object instead of casting a smudge.
        .shadow(color: .black.opacity(expanded ? 0.45 : (state.peeking ? 0.3 : 0)),
                radius: expanded ? 6 : 4, x: 0, y: expanded ? 3 : 2)
        .shadow(color: .black.opacity(expanded ? 0.5 : 0),
                radius: expanded ? 26 : 0, x: 0, y: expanded ? 16 : 0)
    }

    private var expandedPanel: some View {
        VStack(spacing: 8) {
            // Tabs flank the hardware notch: mirror + music on the left,
            // shelf + calendar on the right, the notch sitting in the gap.
            HStack(spacing: 4) {
                sideTab(.mirror)
                sideTab(.music)
                Spacer(minLength: state.notchSize.width - 16)
                sideTab(.shelf)
                sideTab(.calendar)
            }
            .padding(.horizontal, 2)
            .frame(height: state.notchSize.height)
            // Always above the panel content, so nothing a widget draws (or
            // overflows) can ever sit over the tabs and eat their clicks.
            .zIndex(2)

            ZStack {
                Group {
                    switch state.selected {
                    case .mirror:   MirrorPanel(controller: camera)
                    case .music:    MusicPanel(controller: music, turntable: turntable)
                    case .shelf:    ShelfPanel(controller: shelf)
                    case .calendar: CalendarPanel(controller: calendar)
                    case .settings: SettingsPanel()
                    }
                }
                .id(state.selected)
                .transition(.swap)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            footer
                .zIndex(2)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // Slim footer: settings on the left, a sheet-style grabber in the middle
    // (tap, or drag down/up, to show more or less).
    private var footer: some View {
        ZStack {
            Grabber(extended: state.extended, onToggle: toggleExtend) { wantExtended in
                guard state.extended != wantExtended else { return }
                toggleExtend()
            }
            HStack {
                let on = state.selected == .settings
                Button { select(on ? .mirror : .settings) } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(on ? 0.95 : 0.34))
                        .rotationEffect(.degrees(on ? 90 : 0))
                        .frame(width: 26, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Settings")
                Spacer()
            }
        }
        .frame(height: 16)
    }

    // Icon button beside the notch. The active one sits on a glass pill that
    // slides between tabs (it passes under the hardware notch on the way).
    private func sideTab(_ kind: WidgetKind) -> some View {
        let active = state.selected == kind
        return Button { select(kind) } label: {
            ZStack {
                if active {
                    Capsule()
                        .fill(Color.clear)
                        .darkGlass(Capsule(), intensity: 0.95)
                        .matchedGeometryEffect(id: "tabPill", in: tabNS)
                }
                Image(systemName: active ? kind.activeSymbol : kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(active ? 1 : 0.42))
            }
            .frame(width: 36, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .help(kind.title)
    }
}

// Sheet grabber: tap toggles; a vertical drag chooses the direction.
private struct Grabber: View {
    let extended: Bool
    let onToggle: () -> Void
    let onDrag: (Bool) -> Void
    @GestureState private var pressing = false

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(pressing ? 0.5 : 0.22))
            .frame(width: pressing ? 42 : 34, height: 4)
            .animation(NotchMotion.press, value: pressing)
            .frame(width: 90, height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, s, _ in s = true }
                    .onEnded { v in
                        let dy = v.translation.height
                        if dy > 6 { onDrag(true) }
                        else if dy < -6 { onDrag(false) }
                        else { onToggle() }
                    }
            )
            .help(extended ? "Show less" : "Show more")
    }
}
