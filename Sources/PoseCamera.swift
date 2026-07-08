import AppKit
import AVFoundation
import Vision
import QuartzCore

/// One processed frame's pose, in Vision's normalized [0,1] BOTTOM-LEFT space.
struct PoseFrame {
    var points: [VNHumanBodyPoseObservation.JointName: CGPoint]
    var depth: Double?   // 1.0 = standing, → 0 = deep squat; nil until a full leg is in frame
    var confidence: Double
}

/// Captures webcam frames, runs Vision body-pose off the main thread, derives a
/// calibrated hip-drop "depth" (robust from any camera angle, unlike a raw knee
/// angle), drives the SquatCounter, and reports results on main. On-device only.
final class PoseCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let counter = SquatCounter()

    var onUpdate: ((PoseFrame?, Int, SquatCounter.Phase) -> Void)?
    var onAuth: ((Bool) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "squatcoach.camera")
    private let request = VNDetectHumanBodyPoseRequest()
    private var lastProcess: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 1.0 / 12.0   // throttle Vision to ~12 Hz

    // Calibration: standing hip-height baseline = running max of (hipY - ankleY).
    private var h0: Double = 0
    private var calibrated = false
    private var warmup = 0

    static let jointConfGate: Double = 0.5   // per-joint confidence to trust for depth

    // MARK: Lifecycle

    func startRequestingAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun(); deliverAuth(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                guard let self else { return }
                if ok { self.configureAndRun() }
                self.deliverAuth(ok)
            }
        default:
            deliverAuth(false)
        }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    func resetCount() { queue.async { self.resetAll() } }

    private func resetAll() {
        counter.config.downEnter = Prefs.sensitivityDownEnter
        counter.config.upEnter = min(0.90, Prefs.sensitivityDownEnter + 0.18)
        counter.reset()
        h0 = 0; calibrated = false; warmup = 0
        PoseCamera.startLog()
    }

    private func deliverAuth(_ ok: Bool) { DispatchQueue.main.async { self.onAuth?(ok) } }

    private func configureAndRun() {
        queue.async { [weak self] in
            guard let self else { return }
            self.resetAll()
            if self.session.isRunning { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration(); return
            }
            self.session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(output) { self.session.addOutput(output) }
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                self.previewLayer.session = self.session
                // Show the WHOLE frame (letterboxed) — not a center crop — so the
                // user can see their feet and frame their full body correctly.
                self.previewLayer.videoGravity = .resizeAspect
                if let conn = self.previewLayer.connection, conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = true
                }
            }
            self.session.startRunning()
        }
    }

    // MARK: Frame processing (camera queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastProcess >= minInterval else { return }
        lastProcess = now
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let obs = request.results?.first,
              let ex = PoseCamera.extract(obs) else { deliver(nil); return }

        var depth: Double? = nil
        if let m = ex.measure {
            // Thigh signal: hip-above-knee. Standing ≈ thigh length (large); as you
            // squat the thigh rotates toward horizontal and this shrinks toward 0.
            // Needs only hips + knees in frame — no ankles — so a laptop webcam works.
            let rawT = m.hipY - m.kneeY
            if !calibrated {
                if rawT > 0.05 { h0 = rawT; calibrated = true }
            } else if rawT > h0 {
                h0 = rawT   // running max = standing baseline
            }
            if calibrated {
                warmup += 1
                let d = min(1.2, max(0.0, rawT) / h0)
                depth = d
                if warmup >= 6 {   // let the standing baseline settle before counting
                    counter.update(depth: d, confidence: m.conf, time: now)
                }
                let ankle = m.ankleY.map { String(format: "%.3f", $0) } ?? "nil"
                PoseCamera.poseLog(String(format: "t=%.2f depth=%.3f rawT=%.3f h0=%.3f conf=%.2f ankleY=%@ phase=%@ reps=%d",
                                          now, d, rawT, h0, m.conf, ankle, "\(counter.phase)", counter.reps))
            }
        }
        deliver(PoseFrame(points: ex.points, depth: depth, confidence: ex.measure?.conf ?? 0))
    }

    private func deliver(_ frame: PoseFrame?) {
        let reps = counter.reps
        let phase = counter.phase
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(frame, reps, phase) }
    }

    // MARK: Extraction

    /// Returns drawable joints plus, when a full leg is confidently visible, the
    /// averaged hip/knee/ankle heights used for the depth metric.
    static func extract(_ obs: VNHumanBodyPoseObservation)
        -> (points: [VNHumanBodyPoseObservation.JointName: CGPoint],
            measure: (hipY: Double, kneeY: Double, ankleY: Double?, conf: Double)?)? {
        typealias J = VNHumanBodyPoseObservation.JointName
        var raw: [J: (CGPoint, Double)] = [:]
        for j in [J.leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
                  .leftShoulder, .rightShoulder, .neck, .root] {
            if let p = try? obs.recognizedPoint(j), p.confidence > 0.1 {
                raw[j] = (CGPoint(x: p.location.x, y: p.location.y), Double(p.confidence))
            }
        }
        guard !raw.isEmpty else { return nil }
        let points = raw.mapValues { $0.0 }

        // A joint "group" (e.g. both hips): average the sides that clear the gate.
        func grp(_ names: [J]) -> (y: Double, conf: Double)? {
            let good = names.compactMap { raw[$0] }.filter { $0.1 >= jointConfGate }
            guard !good.isEmpty else { return nil }
            let y = good.map { Double($0.0.y) }.reduce(0, +) / Double(good.count)
            return (y, good.map { $0.1 }.min() ?? 0)
        }
        // Require hips + knees (thighs). Ankles are optional — used only for logging.
        if let hip = grp([.leftHip, .rightHip]), let knee = grp([.leftKnee, .rightKnee]) {
            let ankle = grp([.leftAnkle, .rightAnkle])
            return (points, (hipY: hip.y, kneeY: knee.y, ankleY: ankle?.y, conf: min(hip.conf, knee.conf)))
        }
        return (points, nil)
    }

    // MARK: Depth logging (for threshold tuning against real squats)

    static let logPath = "/tmp/squatcoach-pose.log"
    private static var loggingActive = false

    static func startLog() {
        loggingActive = true
        let header = "=== squat set (uptime \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime))s) ===\n"
        try? header.data(using: .utf8)?.write(to: URL(fileURLWithPath: logPath))
    }

    static func poseLog(_ s: String) {
        guard loggingActive, let data = (s + "\n").data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}
