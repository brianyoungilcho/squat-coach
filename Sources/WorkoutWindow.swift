import AppKit
import SwiftUI
import AVFoundation
import Vision
import QuartzCore

// MARK: - Observable state for the SwiftUI HUD

@MainActor
final class WorkoutState: ObservableObject {
    @Published var reps = 0
    @Published var target = Prefs.targetReps
    @Published var phase: SquatCounter.Phase = .standing
    @Published var bodyVisible = false
    @Published var legsVisible = false
    @Published var depth: Double = 1.0     // 1 = standing, → 0 = deep
    @Published var cameraDenied = false
    var onSkip: (() -> Void)?
    var onDone: (() -> Void)?
}

// MARK: - Camera preview + skeleton overlay (AppKit / CoreAnimation)

final class CameraContainerView: NSView {
    private let skeleton = CAShapeLayer()
    private let preview: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.preview = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        preview.frame = bounds
        layer?.addSublayer(preview)
        skeleton.strokeColor = NSColor.systemGreen.cgColor
        skeleton.fillColor = NSColor.systemGreen.cgColor
        skeleton.lineWidth = 4
        skeleton.lineCap = .round
        layer?.addSublayer(skeleton)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // No implicit animation on resize — keep preview + overlay locked together.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = bounds
        skeleton.frame = bounds
        CATransaction.commit()
    }

    /// Draw the skeleton from a Vision pose (normalized bottom-left coords).
    func render(_ pose: PoseFrame?) {
        guard let pose else { skeleton.path = nil; return }
        func p(_ j: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let n = pose.points[j] else { return nil }
            // Vision (bottom-left) → capture-device space (top-left) → layer point.
            // layerPointConverted honors videoGravity + mirroring, so the overlay
            // stays aligned with the preview regardless of aspect/crop.
            return preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: n.x, y: 1 - n.y))
        }
        let bones: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
            (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
            (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
            (.leftHip, .rightHip), (.leftShoulder, .rightShoulder),
            (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        ]
        let path = CGMutablePath()
        for (a, b) in bones {
            if let pa = p(a), let pb = p(b) { path.move(to: pa); path.addLine(to: pb) }
        }
        for j in pose.points.keys {
            if let pj = p(j) { path.addEllipse(in: CGRect(x: pj.x - 5, y: pj.y - 5, width: 10, height: 10)) }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        skeleton.path = path
        CATransaction.commit()
    }
}

// MARK: - SwiftUI HUD overlaid on the camera

struct WorkoutHUD: View {
    @ObservedObject var state: WorkoutState

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SQUAT TIME").font(.caption).bold().foregroundColor(.white.opacity(0.75))
                    Text("\(min(state.reps, state.target)) / \(state.target)")
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                }
                Spacer()
                pill
            }
            .padding(16)
            .background(.black.opacity(0.4))

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                if state.legsVisible { depthMeter }
                ProgressView(value: Double(min(state.reps, state.target)), total: Double(max(1, state.target)))
                    .tint(.green)
                Text(hint)
                    .font(.callout)
                    .foregroundColor(hintColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                HStack {
                    Button("Skip") { state.onSkip?() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button(state.reps >= state.target ? "Done ✓" : "I'm done") { state.onDone?() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .background(.black.opacity(0.4))
        }
    }

    /// Live depth bar: the fill shrinks as you lower; a yellow tick marks the
    /// "counts as a squat" threshold, so you can see exactly how deep to go.
    private var depthMeter: some View {
        let downAt = Prefs.sensitivityDownEnter
        return VStack(spacing: 3) {
            HStack {
                Text("depth").font(.caption2).foregroundColor(.white.opacity(0.7))
                Spacer()
                Text("\(Int(state.depth * 100))%").font(.caption2).monospacedDigit().foregroundColor(.white.opacity(0.7))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(state.depth <= downAt ? Color.green : Color.orange)
                        .frame(width: g.size.width * CGFloat(min(1, max(0.02, state.depth))))
                    Rectangle().fill(.yellow).frame(width: 2)
                        .offset(x: g.size.width * CGFloat(downAt))
                }
            }
            .frame(height: 8)
        }
    }

    private var hint: String {
        if state.cameraDenied { return "Camera access is off — enable it in System Settings ▸ Privacy & Security ▸ Camera, then reopen." }
        if !state.bodyVisible { return "Step into the camera's view." }
        if !state.legsVisible { return "Move back until your hips and knees (your thighs) are in frame." }
        switch state.phase {
        case .down: return "Good depth — now stand back up"
        case .descending: return "Keep going down…"
        case .standing: return "Squat down"
        }
    }
    private var hintColor: Color { state.cameraDenied ? .yellow : .white.opacity(0.9) }

    private var pill: some View {
        let label = state.cameraDenied ? "no camera" : (state.bodyVisible ? "tracking" : "no body")
        let color: Color = state.cameraDenied ? .red : (state.bodyVisible ? .green : .gray)
        return Text(label)
            .font(.caption).bold()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.85)))
            .foregroundColor(.white)
    }
}

// MARK: - Controller: builds the pop-to-front window, owns the camera + completion

@MainActor
final class WorkoutController: NSObject {
    /// true = hit the target, false = skipped / closed early.
    var onFinished: ((Bool) -> Void)?

    private var window: NSPanel?
    private var container: CameraContainerView?
    private let state = WorkoutState()
    private var camera: PoseCamera?
    private var finished = false

    func present() {
        // If a session is already up, just bring it forward.
        if window != nil { popToFront(); return }

        finished = false
        state.reps = 0
        state.target = Prefs.targetReps
        state.phase = .standing
        state.bodyVisible = false
        state.cameraDenied = false
        state.onSkip = { [weak self] in self?.complete(success: false) }
        state.onDone = { [weak self] in
            guard let self else { return }
            self.complete(success: self.state.reps >= Prefs.targetReps)
        }

        let camera = PoseCamera()
        self.camera = camera
        camera.onAuth = { [weak self] ok in self?.state.cameraDenied = !ok }
        camera.onUpdate = { [weak self] pose, reps, phase in
            guard let self else { return }
            self.container?.render(pose)
            self.state.bodyVisible = (pose != nil)
            self.state.legsVisible = (pose?.depth != nil)
            self.state.depth = pose?.depth ?? 1.0
            self.state.phase = phase
            if reps != self.state.reps {
                self.state.reps = reps
                if Prefs.soundEnabled { NSSound(named: "Tink")?.play() }
                if reps >= Prefs.targetReps { self.complete(success: true) }
            }
        }

        buildWindow(camera: camera)
        camera.startRequestingAccess()
        popToFront()
    }

    private func buildWindow(camera: PoseCamera) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Squat Time"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()

        let container = CameraContainerView(previewLayer: camera.previewLayer)
        container.translatesAutoresizingMaskIntoConstraints = false
        let hud = NSHostingView(rootView: WorkoutHUD(state: state))
        hud.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(container)
        root.addSubview(hud)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hud.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hud.topAnchor.constraint(equalTo: root.topAnchor),
            hud.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClosed() }
        }

        self.container = container
        self.window = panel
    }

    private func popToFront() {
        // macOS 14+ accessory apps can't just activate() — flip to .regular first.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func complete(success: Bool) {
        guard !finished else { return }
        finished = true
        if success { Prefs.recordCompletedSet() }
        onFinished?(success)
        window?.close()          // → willClose → handleClosed()
    }

    /// Single teardown path for every exit (Done, Skip, red close button).
    private func handleClosed() {
        camera?.stop()
        camera = nil
        container = nil
        window = nil
        if !finished { finished = true; onFinished?(false) }
        NSApp.setActivationPolicy(.accessory)
    }
}
