import SwiftUI
import AVFoundation

final class CameraController: ObservableObject {
    let session = AVCaptureSession()
    @Published var status: String = ""
    @Published var accessDenied = false
    private let queue = DispatchQueue(label: "notchnook.camera")
    private var configured = false

    private func setStatus(_ s: String, denied: Bool = false) {
        DispatchQueue.main.async {
            self.status = s
            self.accessDenied = denied
        }
    }

    // Wire up the device/input at launch (if already authorized) so opening the
    // Mirror only has to call startRunning — no green light until then.
    func prepare() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        queue.async { [weak self] in
            guard let self, !self.configured else { return }
            self.configure()
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // Clear any stale error from a previous denied run — otherwise the
            // old message stayed overlaid on top of a perfectly working feed.
            setStatus("")
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                guard granted else {
                    self.setStatus("Camera access denied", denied: true)
                    return
                }
                self.setStatus("")
                DispatchQueue.main.async {
                    // The permission dialog steals the cursor, so the notch has
                    // usually auto-closed by the time the user clicks Allow.
                    // Only start if the Mirror is still what's on screen —
                    // otherwise the camera (and its green light) would run
                    // with the panel closed.
                    let s = NotchState.shared
                    if s.expanded && s.selected == .mirror { self.run() }
                }
            }
        default:
            setStatus("Camera access is off for MyNotch", denied: true)
        }
    }

    private func run() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        if let device, let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        } else {
            setStatus("No camera found")
        }
        session.commitConfiguration()
        configured = true
    }
}

// Layer-hosting NSView whose preview layer follows its bounds.
final class CameraNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraNSView {
        let v = CameraNSView(frame: .zero)
        v.previewLayer.session = session
        if let conn = v.previewLayer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true            // mirror like a real mirror
        }
        return v
    }
    func updateNSView(_ nsView: CameraNSView, context: Context) {}
}

struct MirrorPanel: View {
    @ObservedObject var controller: CameraController
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            // Shows for the instant before the first frame arrives.
            if controller.status.isEmpty {
                Image(systemName: "camera.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.12))
            }
            CameraPreview(session: controller.session)
            // Soft vignette + glass rim so the feed sits IN the panel like a
            // lens rather than a flat rectangle.
            RadialGradient(colors: [.clear, .black.opacity(0.35)],
                           center: .center, startRadius: 80, endRadius: 240)
                .allowsHitTesting(false)
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
                .allowsHitTesting(false)
            if !controller.status.isEmpty {
                Color.black.opacity(0.7)
                VStack(spacing: 9) {
                    Image(systemName: controller.accessDenied ? "video.slash.fill" : "camera.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 38, height: 38)
                        .darkGlass(Circle(), intensity: 0.7)
                    Text(controller.status)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    if controller.accessDenied {
                        // Denied is only fixable in System Settings — take them there.
                        GlassPillButton(title: "Open Settings", symbol: "gearshape.fill") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .background(Color.black)
        .clipShape(shape)
        // NOTE: no onAppear/onDisappear start/stop here. NotchRootView's
        // onChange handlers are the single driver — a MirrorPanel mid-removal
        // transition would otherwise fire a late onDisappear→stop() that kills
        // the session right after a rapid re-open (black mirror).
    }
}
