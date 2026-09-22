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
        ZStack {
            CameraPreview(session: controller.session)
                .background(Color.black)
            if !controller.status.isEmpty {
                VStack(spacing: 10) {
                    Text(controller.status)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    if controller.accessDenied {
                        // Denied is only fixable in System Settings — take them there.
                        Button("Open Settings") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                    }
                }
                .padding()
            }
        }
        // NOTE: no onAppear/onDisappear start/stop here. NotchRootView's
        // onChange handlers are the single driver — a MirrorPanel mid-removal
        // transition would otherwise fire a late onDisappear→stop() that kills
        // the session right after a rapid re-open (black mirror).
    }
}
