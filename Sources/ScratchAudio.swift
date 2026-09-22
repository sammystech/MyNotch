import AVFoundation

// Synthesized "tape whir" for the jog wheel: low-passed noise with a fast
// flutter, looped seamlessly, pitched and mixed by spin speed. Sounds like
// rewinding/fast-forwarding; silent when the record isn't being spun.
//
// IMPORTANT: every AVAudioEngine call lives on its own serial queue, never on
// the caller's thread. `update(speed:)` is invoked from a live DragGesture on
// the MAIN thread on every drag delta — engine.start()/attach()/connect() talk
// to CoreAudio and can stall (device wake, driver hiccup); doing that inline
// on the main thread is exactly what froze the app while jogging the record.
final class ScratchAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private var prepared = false
    private var running = false
    private var nodesAttached = false
    private var buffer: AVAudioPCMBuffer?
    private var fadeSource: DispatchSourceTimer?
    private var lastUpdate = Date.distantPast
    private var idleSource: DispatchSourceTimer?
    private let q = DispatchQueue(label: "notchnook.scratch")

    // Hysteresis so speed noise near the boundary can't thrash start/stop.
    private let startThreshold = 18.0
    private let stopThreshold = 10.0

    init() {
        // When the output device changes (AirPods disconnect, headphones
        // plugged in, Bluetooth speaker drops), AVAudioEngine tears down the
        // graph and mainMixerNode adopts the NEW hardware format. Calling
        // connect()/start() afterwards with the old hardcoded format raises an
        // Objective-C NSException — which `try/catch` CANNOT catch in Swift,
        // so it's an instant hard crash. Rebuild the graph instead.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.q.async {
                self.cancelFade()
                self.engine.stop()
                self.running = false
                self.prepared = false     // next update() rebuilds for the new device
            }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // Pay the buffer-synthesis cost ahead of time (e.g. at launch), off the
    // main thread, so the first real spin doesn't do any first-time setup.
    func warm() { q.async { [weak self] in self?.prepare() } }

    // Synthesized once and reused across graph rebuilds.
    private static func makeBuffer() -> AVAudioPCMBuffer? {
        let sr: Double = 44100
        let frames = AVAudioFrameCount(sr * 0.6)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let n = Int(frames)
        let data = buf.floatChannelData![0]
        var prev: Float = 0
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<n {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let white = Float(Int64(bitPattern: seed >> 11)) / Float(Int64.max)
            prev = prev * 0.82 + white * 0.18            // darkened, tape-ish noise
            let t = Double(i) / sr
            let flutter = Float(0.55 + 0.45 * sin(2 * .pi * 25 * t))  // 15 whole cycles → loops clean
            data[i] = prev * flutter * 0.9
        }
        // Crossfade the loop seam so it doesn't click.
        let xf = 2048
        for i in 0..<xf {
            let a = Float(i) / Float(xf)
            data[n - xf + i] = data[n - xf + i] * (1 - a) + data[i] * a
        }
        return buf
    }

    private func prepare() {
        guard !prepared else { return }
        if buffer == nil { buffer = Self.makeBuffer() }
        guard let buf = buffer else { return }

        if !nodesAttached {
            engine.attach(player)
            engine.attach(varispeed)
            nodesAttached = true
        }
        player.stop()
        engine.connect(player, to: varispeed, format: buf.format)
        // nil format = let the engine adopt the mixer's CURRENT format. After a
        // device change the hardware format differs from ours, and forcing the
        // old one is what raises the fatal exception.
        engine.connect(varispeed, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0
        player.scheduleBuffer(buf, at: nil, options: .loops)
        prepared = true
    }

    // Safe to call from ANY thread — the actual CoreAudio work always
    // happens on the private serial queue, never on the caller's thread.
    func update(speed: Double) {
        q.async { [weak self] in self?.applyUpdate(speed: speed) }
    }

    func beginFadeOut() {
        q.async { [weak self] in self?.scheduleFadeOut() }
    }

    private func applyUpdate(speed: Double) {
        let mag = abs(speed)
        lastUpdate = Date()
        if mag >= startThreshold {
            startIdleWatchdog()
            cancelFade()
            prepare()
            guard prepared else { return }
            if !engine.isRunning {
                do { try engine.start() } catch { return }
            }
            if !running { player.play(); running = true }
            varispeed.rate = Float(min(2.6, max(0.45, mag / 220)))
            engine.mainMixerNode.outputVolume = Float(min(1.0, mag / 260)) * 0.35
        } else if mag < stopThreshold {
            scheduleFadeOut()
        }
        // Dead zone between the two thresholds: hold current state, no thrash.
    }

    private func cancelFade() {
        fadeSource?.cancel()
        fadeSource = nil
    }

    // The whir is driven only by drag deltas, so holding the record perfectly
    // still sends no updates and the sound would sustain at full volume until
    // release. Fade out if motion stops.
    private func startIdleWatchdog() {
        guard idleSource == nil else { return }
        let src = DispatchSource.makeTimerSource(queue: q)
        src.schedule(deadline: .now() + 0.15, repeating: 0.15)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastUpdate) > 0.15 else { return }
            self.scheduleFadeOut()
            self.idleSource?.cancel()
            self.idleSource = nil
        }
        idleSource = src
        src.resume()
    }

    // Quick fade to silence, then park the engine. DispatchSourceTimer (not
    // Foundation Timer) so it runs on our GCD queue without needing a run loop.
    private func scheduleFadeOut() {
        guard running, fadeSource == nil else { return }
        let src = DispatchSource.makeTimerSource(queue: q)
        src.schedule(deadline: .now(), repeating: 0.05)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let v = self.engine.mainMixerNode.outputVolume
            if v <= 0.02 {
                self.engine.mainMixerNode.outputVolume = 0
                self.player.pause()
                self.running = false
                self.engine.pause()
                self.cancelFade()
            } else {
                self.engine.mainMixerNode.outputVolume = v * 0.55
            }
        }
        fadeSource = src
        src.resume()
    }
}
