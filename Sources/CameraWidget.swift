import SwiftUI
import AVFoundation

final class CameraController: ObservableObject {
    let session = AVCaptureSession()
    @Published var status: String = ""
    @Published var accessDenied = false
    private let queue = DispatchQueue(label: "notchnook.camera")
    private var configured = false

    // ONE preview view for the app's lifetime. It used to be created and
    // destroyed with the Mirror panel; destroying it detaches the preview
    // layer from the session, which takes the session's lock ON THE MAIN
    // THREAD — and if the camera queue was mid start/stopRunning (1–2s,
    // holding that lock) the whole app froze until it finished. Panels now
    // only borrow this view (CameraHostView), so it is never torn down.
    private(set) lazy var previewView: CameraNSView = {
        let v = CameraNSView(frame: .zero)
        v.previewLayer.session = session
        if let conn = v.previewLayer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true            // mirror like a real mirror
        }
        return v
    }()

    init() {
        // Build the preview view — and attach it to the session — RIGHT NOW,
        // at launch, while the camera queue has never run. Attaching takes the
        // session's lock; done lazily on first Mirror open it raced the queue's
        // startRunning (which holds that lock for 1–2s) and froze main for up
        // to 2s (seen in a stress-test sample: addVideoPreviewLayer → ulock).
        // After this the main thread never touches the session again.
        _ = previewView
    }

    // Start/stop requests are coalesced: only the LATEST wish is applied, so
    // flicking between tabs can't queue up a stack of slow start/stops.
    private let wishLock = NSLock()
    private var wantRunning = false
    private var wish: Bool {
        get { wishLock.lock(); defer { wishLock.unlock() }; return wantRunning }
        set { wishLock.lock(); wantRunning = newValue; wishLock.unlock() }
    }

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
        wish = true
        queue.async { [weak self] in self?.applyWish() }
    }

    func stop() {
        guard wish else { return }
        wish = false
        // A short grace: leaving the Mirror and coming straight back (or a
        // quick close/open) shouldn't pay a full stop + start.
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.applyWish() }
    }

    /// camera queue: bring the session in line with the latest wish.
    private func applyWish() {
        if wish {
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        } else if session.isRunning {
            session.stopRunning()
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
        // The preview's connection only exists once an input is added, so
        // mirroring is applied here (camera queue) — the view was created
        // before the camera was configured.
        if let conn = previewView.previewLayer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
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

    // The feed now sits UNDER the tab bar and footer (full-bleed). Never take
    // clicks, or AppKit would route taps on those buttons to the video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Borrows the controller's single long-lived preview view while on screen.
/// When this host goes away the preview view is merely un-parented — never
/// deallocated — so nothing touches the capture session on the main thread.
final class CameraHostView: NSView {
    weak var controller: CameraController?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        adopt()
    }

    func adopt() {
        guard window != nil, let preview = controller?.previewView else { return }
        if preview.superview !== self {
            preview.removeFromSuperview()
            addSubview(preview)
        }
        preview.frame = bounds
    }

    override func layout() {
        super.layout()
        controller?.previewView.frame = bounds
    }

    // Clicks belong to the SwiftUI buttons drawn over the feed.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct CameraPreview: NSViewRepresentable {
    let controller: CameraController
    func makeNSView(context: Context) -> CameraHostView {
        let v = CameraHostView(frame: .zero)
        v.controller = controller
        return v
    }
    func updateNSView(_ nsView: CameraHostView, context: Context) { nsView.adopt() }
}

// Full-bleed mirror: the feed fills the ENTIRE open notch, edge to edge —
// no inner card, no black bezel. The notch shape itself does the clipping, and
// the tabs + footer float on top over soft scrims so they stay readable.
struct MirrorPanel: View {
    @ObservedObject var controller: CameraController

    var body: some View {
        ZStack {
            Color.black
            // Shows for the instant before the first frame arrives.
            if controller.status.isEmpty {
                Image(systemName: "camera.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.12))
            }
            CameraPreview(controller: controller)

            // Scrims: darken just the strips where the tabs and footer sit.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.2), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 58)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 40)
            }
            .allowsHitTesting(false)

            if !controller.status.isEmpty {
                Color.black.opacity(0.75)
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
                .padding(.top, 20)   // clear of the tab bar
            }
        }
        // NOTE: no onAppear/onDisappear start/stop here. NotchRootView's
        // onChange handlers are the single driver — a MirrorPanel mid-removal
        // transition would otherwise fire a late onDisappear→stop() that kills
        // the session right after a rapid re-open (black mirror).
    }
}
