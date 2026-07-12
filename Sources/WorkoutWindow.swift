import AppKit
import SwiftUI
import AVFoundation
import Vision
import QuartzCore

struct WorkoutSessionConfiguration {
    let targetReps: Int
    let sensitivityMinPromFrac: Double
    let sensitivityDownEnter: Double
    let soundEnabled: Bool

    @MainActor static func snapshot() -> WorkoutSessionConfiguration {
        WorkoutSessionConfiguration(
            targetReps: Prefs.targetReps,
            sensitivityMinPromFrac: Prefs.sensitivityMinPromFrac,
            sensitivityDownEnter: Prefs.sensitivityDownEnter,
            soundEnabled: Prefs.soundEnabled)
    }
}

enum WorkoutOutcome {
    case completed(reps: Int)
    case partial(reps: Int)
    case discarded
}

// MARK: - Observable state for the SwiftUI HUD

@MainActor
final class WorkoutState: ObservableObject {
    @Published var reps = 0
    @Published var target = Prefs.targetReps
    @Published var phase: SquatCounter.Phase = .standing
    @Published var bodyVisible = false
    @Published var legsVisible = false
    @Published var depth: Double = 1.0     // 1 = standing, → 0 = deep
    @Published var depthThreshold = Prefs.sensitivityDownEnter
    @Published var cameraStatus: CameraStatus = .requesting
    @Published var showEndEarly = false
    var onEndEarly: (() -> Void)?
    var onSavePartial: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onDone: (() -> Void)?
    var onOpenCameraSettings: (() -> Void)?
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
                        .accessibilityLabel("Rep count")
                        .accessibilityValue("\(state.reps) of \(state.target)")
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
                    .accessibilityLabel("Workout progress")
                    .accessibilityValue("\(state.reps) of \(state.target) reps")
                Text(hint)
                    .font(.callout)
                    .foregroundColor(hintColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                if offersCameraSettings {
                    Button("Open System Settings") { state.onOpenCameraSettings?() }
                        .buttonStyle(.bordered)
                }
                HStack {
                    Button("End early") { state.onEndEarly?() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Done ✓") { state.onDone?() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(state.reps < state.target)
                }
            }
            .padding(16)
            .background(.black.opacity(0.4))
        }
        .confirmationDialog("End workout early?", isPresented: $state.showEndEarly) {
            Button("Save partial effort") { state.onSavePartial?() }
            Button("Discard workout", role: .destructive) { state.onDiscard?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save \(state.reps) completed reps as partial effort, or discard this workout.")
        }
    }

    /// Live depth bar: the fill shrinks as you lower; a yellow tick marks the
    /// "counts as a squat" threshold, so you can see exactly how deep to go.
    private var depthMeter: some View {
        let downAt = state.depthThreshold
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Squat depth")
        .accessibilityValue("\(Int(state.depth * 100)) percent")
    }

    private var hint: String {
        switch state.cameraStatus {
        case .requesting:
            return "Requesting camera access…"
        case .denied:
            return "Camera access is off. Enable it in System Settings."
        case .restricted:
            return "Camera access is restricted on this Mac."
        case .unavailable:
            return "No camera is available."
        case .interrupted:
            return "Camera tracking was interrupted."
        case .failed(let message):
            return message
        case .running:
            break
        }
        if !state.bodyVisible { return "Step into the camera's view." }
        if !state.legsVisible { return "Move back until your hips and knees (your thighs) are in frame." }
        switch state.phase {
        case .down: return "Good depth — now stand back up"
        case .descending: return "Keep going down…"
        case .standing: return "Squat down"
        }
    }
    private var hintColor: Color { state.cameraStatus == .running ? .white.opacity(0.9) : .yellow }

    private var offersCameraSettings: Bool {
        switch state.cameraStatus {
        case .denied, .restricted:
            return true
        case .requesting, .running, .unavailable, .interrupted, .failed:
            return false
        }
    }

    private var pill: some View {
        let label: String
        let color: Color
        switch state.cameraStatus {
        case .requesting:
            label = "requesting"; color = .gray
        case .running:
            label = state.bodyVisible ? "tracking" : "no body"
            color = state.bodyVisible ? .green : .gray
        case .denied:
            label = "denied"; color = .red
        case .restricted:
            label = "restricted"; color = .red
        case .unavailable:
            label = "no camera"; color = .red
        case .interrupted:
            label = "interrupted"; color = .orange
        case .failed:
            label = "camera error"; color = .red
        }
        return Text(label)
            .font(.caption).bold()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.85)))
            .foregroundColor(.white)
            .accessibilityLabel("Tracking status")
            .accessibilityValue(label)
    }
}

struct WorkoutReceiptView: View {
    let outcome: WorkoutOutcome
    let queuedForPack: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
            Text(detail)
                .foregroundStyle(.secondary)
            if queuedForPack {
                Label("Queued for your Pack", systemImage: "person.3")
                    .font(.callout)
            }
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 300)
    }

    private var icon: String {
        switch outcome {
        case .completed:
            return "checkmark.circle.fill"
        case .partial:
            return "figure.walk.circle.fill"
        case .discarded:
            return "xmark.circle"
        }
    }

    private var title: String {
        switch outcome {
        case .completed:
            return "Set complete"
        case .partial:
            return "Partial effort saved"
        case .discarded:
            return "Workout discarded"
        }
    }

    private var detail: String {
        switch outcome {
        case .completed(let reps):
            return "\(reps) squats · \(Prefs.setsToday) sets today · \(Prefs.currentStreak)-day streak"
        case .partial(let reps):
            return "\(reps) reps saved locally. Streak and Pack totals were not changed."
        case .discarded:
            return "No workout data was saved."
        }
    }
}

// MARK: - Controller: builds the pop-to-front window, owns the camera + completion

@MainActor
final class WorkoutController: NSObject {
    var onFinished: ((WorkoutOutcome) -> Void)?
    var onVisibilityChange: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    private var window: NSPanel?
    private var container: CameraContainerView?
    private let state = WorkoutState()
    private var camera: PoseCamera?
    private var configuration: WorkoutSessionConfiguration?
    private var finished = false

    func present() {
        // If a session is already up, just bring it forward.
        if window != nil { popToFront(); return }

        let configuration = WorkoutSessionConfiguration.snapshot()
        self.configuration = configuration
        finished = false
        state.reps = 0
        state.target = configuration.targetReps
        state.phase = .standing
        state.bodyVisible = false
        state.legsVisible = false
        state.depth = 1.0
        state.depthThreshold = configuration.sensitivityDownEnter
        state.cameraStatus = .requesting
        state.showEndEarly = false
        state.onEndEarly = { [weak self] in self?.state.showEndEarly = true }
        state.onSavePartial = { [weak self] in
            guard let self else { return }
            self.complete(outcome: .partial(reps: self.state.reps))
        }
        state.onDiscard = { [weak self] in self?.complete(outcome: .discarded) }
        state.onDone = { [weak self] in
            guard let self else { return }
            guard self.state.reps >= configuration.targetReps else { return }
            self.complete(outcome: .completed(reps: self.state.reps))
        }
        state.onOpenCameraSettings = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
            else { return }
            NSWorkspace.shared.open(url)
        }

        let camera = PoseCamera(minPromFrac: configuration.sensitivityMinPromFrac)
        self.camera = camera
        camera.onStatus = { [weak self] status in self?.state.cameraStatus = status }
        camera.onUpdate = { [weak self] pose, reps, phase in
            guard let self else { return }
            self.container?.render(pose)
            self.state.bodyVisible = (pose != nil)
            self.state.legsVisible = (pose?.depth != nil)
            self.state.depth = pose?.depth ?? 1.0
            self.state.phase = phase
            if reps != self.state.reps {
                self.state.reps = reps
                if configuration.soundEnabled { NSSound(named: "Tink")?.play() }
                if reps >= configuration.targetReps {
                    self.complete(outcome: .completed(reps: reps))
                }
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
        onVisibilityChange?()
    }

    private func complete(outcome: WorkoutOutcome) {
        guard !finished else { return }
        finished = true
        var queuedForPack = false
        switch outcome {
        case .completed(let reps):
            Prefs.recordCompletedSet()
            queuedForPack = PackStore.shared.isJoined
            PackStore.shared.recordCompletedWorkout(reps: reps)
        case .partial(let reps):
            Prefs.recordPartialEffort(reps: reps)
        case .discarded:
            break
        }
        onFinished?(outcome)
        if case .discarded = outcome {
            window?.close()
            return
        }
        camera?.stop()
        camera = nil
        container = nil
        window?.contentView = NSHostingView(
            rootView: WorkoutReceiptView(
                outcome: outcome,
                queuedForPack: queuedForPack,
                onClose: { [weak self] in self?.window?.close() }
            )
        )
    }

    /// Single teardown path for every exit (Done, Skip, red close button).
    private func handleClosed() {
        camera?.stop()
        camera = nil
        configuration = nil
        container = nil
        window = nil
        if !finished {
            finished = true
            onFinished?(.discarded)
        }
        onVisibilityChange?()
    }
}
