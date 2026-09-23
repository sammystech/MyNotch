import SwiftUI
import AppKit

// MARK: - Now-playing source
//
// macOS 27 restricts the private MediaRemote framework to Apple-signed apps, so
// a third-party app can't read system now-playing that way. Instead we script
// Music.app and Spotify directly (AppleScript) — exact data, and it works for
// an ad-hoc-signed app after a one-time "control Music/Spotify" permission.

private struct Player {
    let name: String          // AppleScript app name
    let bundleID: String
    let durationIsMS: Bool     // Spotify reports track duration in ms
}

private let players = [
    Player(name: "Music", bundleID: "com.apple.Music", durationIsMS: false),
    Player(name: "Spotify", bundleID: "com.spotify.client", durationIsMS: true),
]

// MARK: - Model

struct NowPlaying: Equatable {
    var app = ""
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var playing = false
    var sampledAt = Date.distantPast

    var isPlaying: Bool { playing }
    var trackKey: String { "\(app)|\(artist)|\(album)|\(title)" }

    func position(at now: Date) -> Double {
        guard playing else { return elapsed }
        let p = elapsed + now.timeIntervalSince(sampledAt)
        return duration > 0 ? min(p, duration) : p
    }
}

// MARK: - Controller

// Physics-y record spin: velocity eases toward a target, so the disc spins
// UP smoothly when playback starts and coasts DOWN to a stop when it pauses —
// no abrupt freeze. Runs a 60 Hz timer only while it's actually turning.
final class Turntable: ObservableObject {
    @Published private(set) var angle: Double = 0
    private var velocity: Double = 0            // deg/sec
    private let targetSpeed: Double = 46        // ~7.7 rpm, a calm spin
    private var timer: Timer?
    private var last = Date()

    var playing: Bool = false {
        didSet { if playing != oldValue { ensureRunning() } }
    }

    private func ensureRunning() {
        guard timer == nil else { return }
        last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: Jog (grab & spin the record to scrub)
    private var jogLastCursor: Double?
    private var jogStartAngle: Double = 0
    private var jogAccum: Double = 0
    private var jogLastTime = Date()
    private(set) var jogVelocity: Double = 0     // smoothed deg/sec while jogging
    var jogTotal: Double { jogAccum }

    func beginJog(cursorAngle: Double) {
        stop()                       // hand control of the angle to the user
        jogLastCursor = cursorAngle
        jogStartAngle = angle
        jogAccum = 0
        jogVelocity = 0
        jogLastTime = Date()
    }

    // Follow the cursor's angular position; return total degrees turned since
    // grab (accumulates across full revolutions).
    @discardableResult
    func updateJog(cursorAngle: Double) -> Double {
        guard let last = jogLastCursor else { return 0 }
        var step = cursorAngle - last
        if step > 180 { step -= 360 }
        if step < -180 { step += 360 }
        jogAccum += step
        jogLastCursor = cursorAngle
        let t = Date()
        let dt = max(0.001, t.timeIntervalSince(jogLastTime))
        jogLastTime = t
        jogVelocity = jogVelocity * 0.65 + (step / dt) * 0.35
        angle = (jogStartAngle + jogAccum).truncatingRemainder(dividingBy: 360)
        return jogAccum
    }

    func endJog() {
        jogLastCursor = nil
        // Hand the user's release speed to the physics so the record coasts
        // out of the spin instead of stopping dead, then eases to its target.
        velocity = min(720, max(-720, jogVelocity))
        jogVelocity = 0
        ensureRunning()
    }

    private func tick() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(last))
        last = now
        let target = playing ? targetSpeed : 0
        // Exponential ease toward target speed (spin-up / spin-down).
        velocity += (target - velocity) * min(1, dt * 2.6)
        angle = (angle + velocity * dt).truncatingRemainder(dividingBy: 360)
        if !playing && abs(velocity) < 0.3 {   // fully coasted to a stop
            velocity = 0
            stop()
        }
    }
}

final class MusicController: ObservableObject {
    static let shared = MusicController()       // AppKit (notch clicks) reaches it too

    @Published var now: NowPlaying?
    @Published var artwork: NSImage? {
        // Sampled once per cover (a 12×12 downsample) — tints the EQ bars
        // and the panel glow to the album, like the iPhone's island.
        didSet { if artwork !== oldValue { accent = artwork?.accentColor() ?? .white } }
    }
    @Published private(set) var accent: Color = .white
    @Published var scrubbing: Double?           // 0…1 while dragging the bar
    private var timer: Timer?
    private var artworkKey = ""
    private var pollInFlight = false            // main-thread only
    private var pauseHideWork: DispatchWorkItem?
    private let pauseGrace: TimeInterval = 6     // keep the island this long after pausing

    init() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    // Only script apps that are actually running (so we never launch them).
    private func runningPlayer() -> Player? {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return players.first { ids.contains($0.bundleID) }
    }

    func command(_ verb: String) {
        guard let app = now?.app ?? runningPlayer()?.name else { return }
        Self.runScriptAsync("tell application \"\(app)\" to \(verb)") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.poll() }
        }
    }

    func playPause() { command("playpause") }
    func next()      { command("next track") }
    func previous()  { command("previous track") }

    // MARK: Jog scrubbing (driven by rotating the record)
    //
    // Design: pause on grab, track the target position locally while spinning
    // (with the scratch-whir as feedback), then ONE authoritative seek and an
    // explicit `play` on release. Live-seeking a streaming track mid-spin made
    // Apple Music rebuffer — the old "doesn't resume right away" stutter.
    private(set) var jogging = false
    private var jogStartPos: Double = 0
    private var jogTargetPos: Double?
    private var wasPlayingBeforeJog = false
    let secondsPerRevolution = 25.0
    let scratch = ScratchAudio()

    func beginJog() {
        jogging = true
        wasPlayingBeforeJog = now?.playing ?? false
        jogStartPos = now?.position(at: Date()) ?? 0
        jogTargetPos = nil
        NotchState.shared.interacting = true
        if wasPlayingBeforeJog { command("pause") }   // clean scrub, no stutter
    }

    // total degrees turned since grab → target position; speed drives the whir.
    func jog(totalDegrees deg: Double, speed: Double) {
        guard jogging, let np = now else { return }
        if Prefs.shared.scratchSound { scratch.update(speed: speed) }
        var target = jogStartPos + (deg / 360.0) * secondsPerRevolution
        if np.duration > 0 {
            target = min(np.duration, max(0, target))
            scrubbing = target / np.duration            // move the bar too
        } else {
            target = max(0, target)
        }
        jogTargetPos = target
    }

    func endJog(totalDegrees deg: Double) {
        guard jogging else { return }
        jogging = false
        scratch.beginFadeOut()
        let target = jogTargetPos
        let resume = wasPlayingBeforeJog
        scrubbing = nil
        jogTargetPos = nil
        NotchState.shared.interacting = false
        guard let app = now?.app else { return }

        // Micro-drag (an accidental wiggle while clicking): don't seek at all,
        // just make sure playback is back where it was.
        if abs(deg) < 4 {
            if resume { resumePlayback(app) }
            return
        }
        let pos = max(0, target ?? jogStartPos)
        optimisticPosition(pos, playing: resume)
        // Seek and resume in ONE event so `play` can never be separated from
        // (or reordered before) the seek by other queued work.
        let script = resume
            ? "tell application \"\(app)\"\nset player position to \(pos)\nplay\nend tell"
            : "tell application \"\(app)\" to set player position to \(pos)"
        Self.runScriptAsync(script) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.poll() }
        }
    }

    /// Recovery for a drag that was cancelled rather than ended (SwiftUI never
    /// delivers onEnded in that case). Restores playback if a jog had paused it,
    /// so music can't get stranded in a paused state.
    func abortInteraction() {
        scrubbing = nil
        guard jogging else { return }
        jogging = false
        jogTargetPos = nil
        scratch.beginFadeOut()
        if wasPlayingBeforeJog, let app = now?.app { resumePlayback(app) }
    }

    private func resumePlayback(_ app: String) {
        Self.runScriptAsync("tell application \"\(app)\" to play") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.poll() }
        }
    }

    // Snap the UI to a position immediately instead of waiting for the next
    // poll — the bar and vinyl respond the instant you let go.
    private func optimisticPosition(_ secs: Double, playing: Bool) {
        guard var np = now else { return }
        np.elapsed = secs
        np.sampledAt = Date()
        if playing { np.playing = true }
        now = np
        if playing { updateIsland(playing: true) }
    }

    // Scrub: jump playback to a time (seconds). Music & Spotify both accept
    // `set player position to <seconds>`.
    func seek(to seconds: Double) {
        guard let app = now?.app else { return }
        let secs = max(0, seconds)
        optimisticPosition(secs, playing: false)
        Self.runScriptAsync("tell application \"\(app)\" to set player position to \(secs)") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.poll() }
        }
    }

    private func poll() {
        // Never let polls stack up. Without this the 1.5s timer keeps firing
        // while a slow Apple Event is still outstanding, and every queued poll
        // delays the user's own play/pause/seek behind it.
        guard !pollInFlight else { return }
        guard let player = runningPlayer() else { clear(); return }
        let sep = "\u{001F}"      // unit separator — won't appear in metadata
        let src = """
        tell application "\(player.name)"
          if player state is stopped then return "none"
          set t to current track
          return (player state as text) & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & (duration of t as text) & "\(sep)" & (player position as text)
        end tell
        """
        pollInFlight = true
        Self.runScriptAsync(src) { [weak self] desc in
            let result = desc?.stringValue
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInFlight = false
                self.apply(result, player: player)
            }
        }
    }

    private func apply(_ raw: String?, player: Player) {
        guard let raw, raw != "none" else { clear(); return }
        let parts = raw.components(separatedBy: "\u{001F}")
        guard parts.count >= 6 else { clear(); return }

        var np = NowPlaying()
        np.app = player.name
        np.playing = parts[0].lowercased().contains("playing")
        np.title = parts[1]
        np.artist = parts[2]
        np.album = parts[3]
        var dur = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        if player.durationIsMS { dur /= 1000 }
        np.duration = dur
        np.elapsed = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        np.sampledAt = Date()

        if np.title.isEmpty { clear(); return }

        let changed = now?.trackKey != np.trackKey
        now = np
        if changed { fetchArtwork(for: np) }
        updateIsland(playing: np.playing)
    }

    private func clear() {
        pauseHideWork?.cancel(); pauseHideWork = nil
        if now != nil { now = nil; artwork = nil; artworkKey = "" }
        setIsland(false)
    }

    // Playing → show now. Paused → keep the island a few seconds so the user
    // can click to resume, then hide. (Never pops up for an already-paused track.)
    private func updateIsland(playing: Bool) {
        if playing {
            pauseHideWork?.cancel(); pauseHideWork = nil
            setIsland(true)
        } else if NotchState.shared.musicActive {
            guard pauseHideWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.setIsland(false)
                self?.pauseHideWork = nil
            }
            pauseHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + pauseGrace, execute: work)
        } else {
            setIsland(false)
        }
    }

    private func setIsland(_ active: Bool) {
        let active = active && Prefs.shared.musicIsland
        guard NotchState.shared.musicActive != active else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
            NotchState.shared.musicActive = active
        }
    }

    // Artwork: pull the real thing straight from the player (covers local
    // library + streaming); fall back to an iTunes cover-art lookup.
    private static let musicLog = ProcessInfo.processInfo.environment["MYNOTCH_MUSICLOG"] == "1"
    private static func mlog(_ s: String) {
        guard musicLog else { return }
        FileHandle.standardError.write(("MUSIC " + s + "\n").data(using: .utf8)!)
    }

    private func fetchArtwork(for np: NowPlaying) {
        let key = np.trackKey
        artworkKey = key
        artwork = nil
        if np.app == "Music" {
            Self.runScriptAsync("tell application \"Music\" to get raw data of artwork 1 of current track") { [weak self] desc in
                guard let self else { return }
                let bytes = desc?.data.count ?? -1
                var img: NSImage?
                if let data = desc?.data { img = NSImage(data: data) }
                Self.mlog("rawdata bytes=\(bytes) image=\(img != nil)")
                if let img {
                    DispatchQueue.main.async { if self.artworkKey == key { self.artwork = img } }
                } else {
                    self.fetchITunesArtwork(np, key: key)
                }
            }
        } else if np.app == "Spotify" {
            Self.runScriptAsync("tell application \"Spotify\" to get artwork url of current track") { [weak self] desc in
                guard let self else { return }
                guard let urlStr = desc?.stringValue, let u = URL(string: urlStr) else {
                    self.fetchITunesArtwork(np, key: key); return
                }
                // URLSession (not Data(contentsOf:)) so this can't pin a thread
                // for the 60s default timeout on a flaky/captive network.
                self.loadImage(u, key: key) { ok in
                    if !ok { self.fetchITunesArtwork(np, key: key) }
                }
            }
        } else {
            fetchITunesArtwork(np, key: key)
        }
    }

    // Shared image download with a real timeout; assigns on main if still current.
    private func loadImage(_ url: URL, key: String, done: ((Bool) -> Void)? = nil) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data, let img = NSImage(data: data) else { done?(false); return }
            DispatchQueue.main.async {
                if self.artworkKey == key { self.artwork = img }
            }
            done?(true)
        }.resume()
    }

    private func fetchITunesArtwork(_ np: NowPlaying, key: String) {
        guard !np.artist.isEmpty else { return }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(np.artist) \(np.album.isEmpty ? np.title : np.album)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let art = results.first?["artworkUrl100"] as? String,
                  let u = URL(string: art.replacingOccurrences(of: "100x100", with: "600x600")) else {
                Self.mlog("iTunes lookup failed")
                return
            }
            self.loadImage(u, key: key) { ok in Self.mlog("iTunes artwork set=\(ok)") }
        }.resume()
    }

    // MARK: AppleScript plumbing
    //
    // NSAppleScript is NOT thread-safe (Apple's docs), so every call is
    // serialized onto this one queue. Critically, callers must dispatch
    // ONTO this queue — never `global.async { scriptQueue.sync { … } }`.
    // That older pattern parked a blocked global-pool worker per call: a
    // slow Apple Event (Music.app stalls during library sync, and the
    // "control Music" consent dialog blocks until answered) meant the 1.5s
    // poll timer stacked up one blocked thread every 1.5s until the 64-thread
    // pool was exhausted — which also starved the camera and audio queues,
    // since they draw from that same pool. That was a real hang.
    private static let scriptQueue = DispatchQueue(label: "notchnook.applescript")

    // Bounds how long any single Apple Event can wedge the queue. Without
    // this, AppleScript's own default is ~60s.
    private static func withTimeout(_ body: String) -> String {
        """
        with timeout of 5 seconds
        \(body)
        end timeout
        """
    }

    /// Runs `source` on the script queue and hands the result back on the queue.
    /// Never blocks the caller's thread.
    private static func runScriptAsync(_ source: String,
                                       _ completion: ((NSAppleEventDescriptor?) -> Void)? = nil) {
        scriptQueue.async {
            let result = execute(withTimeout(source))
            completion?(result)
        }
    }

    /// Only ever called from `scriptQueue`.
    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        return err == nil ? result : nil
    }
}

// MARK: - Shared pieces

struct ArtworkView: View {
    let image: NSImage?
    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.2), Color(white: 0.07)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

/// The player's own app icon + name ("Music", "Spotify"), cached per app.
private enum SourceBadge {
    private static var cache: [String: NSImage] = [:]
    static func icon(for app: String) -> NSImage? {
        if let hit = cache[app] { return hit }
        guard let id = players.first(where: { $0.name == app })?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[app] = img
        return img
    }
    static func label(for app: String) -> String { app == "Music" ? "Apple Music" : app }
}

// Animated equalizer bars — TimelineView-driven, no @State needed.
// Movement is layered to feel like real audio: a beat "thump" sweeping across
// the bars, a slower groove, and fast shimmer, with a mid-heavy spectrum
// shape. Tinted to the album, like the iPhone island.
struct EQBars: View {
    var playing: Bool
    var tint: Color = .white
    var barCount: Int = 5
    var maxHeight: CGFloat = 15
    var barWidth: CGFloat = 2.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: barWidth * 0.9) {
                ForEach(0..<barCount, id: \.self) { i in
                    let p = Double(i) * 1.37
                    // Beat pulse (~100 bpm) that ripples bar-to-bar…
                    let beat = pow(max(0, sin(t * 2 * .pi * 0.83 + p * 0.8)), 3)
                    // …under a slower groove and a fast shimmer.
                    let groove = 0.5 + 0.5 * sin(t * 2.9 + p * 2.1)
                    let shimmer = 0.5 + 0.5 * sin(t * 12.7 + p * 4.7)
                    // Mid bars run hotter, like a spectrum.
                    let shape = 1.0 - Double(abs(i - barCount / 2)) * 0.16
                    let level = playing
                        ? (0.14 + (0.55 * beat + 0.24 * groove + 0.12 * shimmer) * shape)
                        : 0.1
                    Capsule()
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.72)],
                                             startPoint: .top, endPoint: .bottom))
                        .opacity(playing ? 1 : 0.45)
                        .frame(width: barWidth, height: maxHeight * 0.2 + maxHeight * 0.8 * CGFloat(min(1, level)))
                }
            }
            .frame(height: maxHeight, alignment: .center)
        }
    }
}

// MARK: - Collapsed island content (album thumb left, EQ right)

struct MusicIslandContent: View {
    @ObservedObject var controller: MusicController
    @ObservedObject private var state = NotchState.shared
    let notchGap: CGFloat

    var body: some View {
        let playing = controller.now?.isPlaying ?? false
        let art = RoundedRectangle(cornerRadius: 6.5, style: .continuous)
        HStack(spacing: 0) {
            // Album art doubles as a play/pause button — the control appears
            // only when the cursor is actually ON the art (state.hoveringArt),
            // not merely anywhere on the island.
            ZStack {
                ArtworkView(image: controller.artwork)
                    .frame(width: 22, height: 22)
                    .clipShape(art)
                    .overlay(art.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                if state.hoveringArt {
                    art.fill(Color.black.opacity(0.55)).frame(width: 22, height: 22)
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.white)
                        .transition(.opacity)
                }
            }
            .scaleEffect(playing ? 1 : 0.9)
            .animation(NotchMotion.nudge, value: playing)
            .padding(.leading, 7)
            Spacer(minLength: notchGap)
            EQBars(playing: playing, tint: controller.accent)
                .padding(.trailing, 8)
        }
    }
}

// MARK: - Expanded music panel (spinning record + track info + controls)

// A record pressed from the album art: cover printed across the disc, fine
// grooves, a spindle label, and a still light-sheen on top. The sheen stays
// fixed while the disc turns under it — that's what makes it read as a real
// spinning record. Isolated view so the 60 Hz rotation only re-renders this.
struct VinylView: View {
    @ObservedObject var turntable: Turntable
    @ObservedObject var controller: MusicController
    let image: NSImage?
    private let size: CGFloat = 124

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width / 2, cy = geo.size.height / 2
            ZStack {
                ZStack {
                    ArtworkView(image: image)
                    // Grooves ride along with the disc.
                    ForEach(0..<9, id: \.self) { i in
                        let d = size * (0.5 + CGFloat(i) * 0.058)
                        Circle()
                            .stroke(Color.black.opacity(i % 3 == 0 ? 0.3 : 0.16), lineWidth: 0.6)
                            .frame(width: d, height: d)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .rotationEffect(.degrees(turntable.angle))

                // Fixed light: two soft glints across the vinyl.
                Circle()
                    .fill(AngularGradient(
                        stops: [
                            .init(color: .white.opacity(0), location: 0.0),
                            .init(color: .white.opacity(0.16), location: 0.1),
                            .init(color: .white.opacity(0), location: 0.22),
                            .init(color: .white.opacity(0), location: 0.5),
                            .init(color: .white.opacity(0.1), location: 0.6),
                            .init(color: .white.opacity(0), location: 0.72),
                            .init(color: .white.opacity(0), location: 1.0),
                        ],
                        center: .center))
                    .frame(width: size, height: size)
                    .allowsHitTesting(false)

                // Rim: bright top edge, like the glass controls.
                Circle()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.06)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .frame(width: size, height: size)
                // Spindle label + hole.
                Circle().fill(Color.black.opacity(0.5)).frame(width: 28, height: 28)
                Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7).frame(width: 28, height: 28)
                Circle().fill(Color.black).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Circle())
            // Grab & spin to scrub: rotating the record seeks the song, with a
            // speed-tracked whir while you spin.
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        let ang = atan2(Double(v.location.y - cy), Double(v.location.x - cx)) * 180 / .pi
                        if !controller.jogging {
                            NSHapticFeedbackManager.defaultPerformer
                                .perform(.alignment, performanceTime: .default)
                            controller.beginJog()
                            turntable.beginJog(cursorAngle: ang)
                        }
                        let turned = turntable.updateJog(cursorAngle: ang)
                        controller.jog(totalDegrees: turned, speed: turntable.jogVelocity)
                    }
                    .onEnded { _ in
                        let turned = turntable.jogTotal
                        turntable.endJog()          // coast from release speed
                        controller.endJog(totalDegrees: turned)
                    }
            )
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.7), radius: 14, x: 0, y: 8)
    }
}

struct MusicPanel: View {
    @ObservedObject var controller: MusicController
    let turntable: Turntable

    var body: some View {
        ZStack {
            backdrop
            if let np = controller.now {
                HStack(spacing: 18) {
                    VinylView(turntable: turntable, controller: controller, image: controller.artwork)
                    VStack(alignment: .leading, spacing: 0) {
                        source(np)
                            .padding(.bottom, 6)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(np.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            EQBars(playing: np.isPlaying, tint: controller.accent,
                                   barCount: 4, maxHeight: 11, barWidth: 2)
                                .opacity(np.isPlaying ? 1 : 0)
                                .animation(.easeInOut(duration: 0.25), value: np.isPlaying)
                        }
                        Text(np.artist.isEmpty ? np.album : np.artist)
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                            .padding(.top, 2)
                        Spacer(minLength: 4)
                        progress(np)
                        controls(np)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 14)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 42, height: 42)
                        .darkGlass(Circle(), intensity: 0.8)
                    Text("Not Playing")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                    GlassPillButton(title: "Open Music", symbol: "play.fill") {
                        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
                            NSWorkspace.shared.openApplication(at: u, configuration: .init())
                        }
                    }
                }
            }
        }
        .background(Color.black)
    }

    // Faint cover wash + an album-coloured glow behind the record — the
    // panel takes on the song's colour without ever getting light.
    @ViewBuilder private var backdrop: some View {
        if let art = controller.artwork {
            GeometryReader { geo in
                ZStack {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(0.16)
                        // Feathered, so the wash has no card edge — it just
                        // glows out of the black behind the record.
                        .mask(RadialGradient(colors: [.white, .white.opacity(0.4), .clear],
                                             center: UnitPoint(x: 0.25, y: 0.5),
                                             startRadius: 20, endRadius: geo.size.width * 0.62))
                    RadialGradient(colors: [controller.accent.opacity(0.22), .clear],
                                   center: UnitPoint(x: 0.22, y: 0.5),
                                   startRadius: 10, endRadius: geo.size.width * 0.55)
                    LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .transition(.opacity)
        }
    }

    private func source(_ np: NowPlaying) -> some View {
        HStack(spacing: 4) {
            if let icon = SourceBadge.icon(for: np.app) {
                Image(nsImage: icon).resizable().frame(width: 11, height: 11)
            }
            Text(SourceBadge.label(for: np.app).uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // iOS-style scrubber: a slim bar that swells while you hold it. No knob.
    private func progress(_ np: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let livePos = np.position(at: ctx.date)
            let active = controller.scrubbing != nil
            let frac: Double = controller.scrubbing
                ?? (np.duration > 0 ? min(1, livePos / np.duration) : 0)
            let shownPos = np.duration > 0 ? frac * np.duration : livePos
            VStack(spacing: 3) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h: CGFloat = active ? 8 : 5
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(active ? 0.24 : 0.17))
                        Capsule().fill(Color.white.opacity(active ? 1 : 0.85))
                            .frame(width: max(h, w * CGFloat(frac)))
                    }
                    .frame(height: h)
                    .frame(height: geo.size.height, alignment: .center)
                    .animation(NotchMotion.nudge, value: active)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                NotchState.shared.interacting = true
                                controller.scrubbing = min(1, max(0, Double(v.location.x / w)))
                            }
                            .onEnded { v in
                                let f = min(1, max(0, Double(v.location.x / w)))
                                if np.duration > 0 { controller.seek(to: f * np.duration) }
                                controller.scrubbing = nil
                                NotchState.shared.interacting = false
                            }
                    )
                }
                .frame(height: 14)
                HStack {
                    Text(np.duration > 0 ? Self.mmss(shownPos) : "")
                    Spacer()
                    Text(np.duration > 0 ? "-" + Self.mmss(max(0, np.duration - shownPos)) : "")
                }
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundColor(.white.opacity(active ? 0.8 : 0.42))
            }
        }
        .frame(height: 28)
    }

    private func controls(_ np: NowPlaying) -> some View {
        HStack(spacing: 18) {
            ctrl("backward.fill", size: 12) { controller.previous() }
            Button { controller.playPause() } label: {
                Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .darkGlass(Circle(), intensity: 1.15)
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            ctrl("forward.fill", size: 12) { controller.next() }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func ctrl(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundColor(.white.opacity(0.88))
                .frame(width: 30, height: 30)
                .darkGlass(Circle(), intensity: 0.6)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
    }

    private static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
