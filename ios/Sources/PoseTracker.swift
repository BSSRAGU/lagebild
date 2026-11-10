import AVFoundation
import UIKit
import Vision

/// Körperhaltung in Echtzeit mit hoher Bildrate (bis 240 Bilder/s, je nach iPhone).
/// Jedes Kamerabild läuft durch Apple Vision (2D-Körperpunkte); die Punkte gehen gebündelt
/// etwa 30-mal pro Sekunde an die Webseite. Die Auswertung (Schlagart, Geschwindigkeit) passiert dort,
/// damit sie ohne neue App-Version verbessert werden kann.
final class PoseTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onBatch: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    var onStarted: (([String: Any]) -> Void)?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "lagebild.pose", qos: .userInteractive)
    private let request = VNDetectHumanBodyPoseRequest()
    private var configured = false
    private var running = false
    private var batch: [Float] = []
    private var batchCount = 0
    private var t0: Double = -1
    private var lastSend: Double = 0
    private var frameTimes: [Double] = []
    private var dropped = 0
    private var cameraFps: Double = 0
    private var dims: (Int, Int) = (0, 0)

    /// Reihenfolge der Gelenke im Datenstrom (je Gelenk x, y, Sicherheit; y nach unten, 0…1, hochkant)
    static let joints: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist,
        .root, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle
    ]

    func start(maxFps: Double) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.configured {
                do { try self.configure(maxFps: maxFps) } catch {
                    self.onError?(error.localizedDescription)
                    return
                }
                self.configured = true
            }
            self.t0 = -1
            self.batch.removeAll()
            self.batchCount = 0
            self.frameTimes.removeAll()
            self.dropped = 0
            self.running = true
            self.session.startRunning()
            self.onStarted?(["fps": self.cameraFps, "w": self.dims.0, "h": self.dims.1,
                             "joints": Self.joints.map { $0.rawValue.rawValue }])
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.running = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private struct PoseError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    private func configure(maxFps: Double) throws {
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw PoseError(msg: "Keine Rückkamera gefunden.")
        }
        // Format mit der höchsten Bildrate (bis maxFps) und mindestens 1280 × 720, bei Gleichstand das kleinere
        var best: AVCaptureDevice.Format?
        var bestFps: Double = 0
        var bestW: Int32 = .max
        for f in dev.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            if d.width < 1280 || d.height < 720 { continue }
            let fps = min(maxFps, f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0)
            if fps > bestFps + 0.5 || (abs(fps - bestFps) <= 0.5 && d.width < bestW) {
                best = f; bestFps = fps; bestW = d.width
            }
        }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { session.commitConfiguration(); throw PoseError(msg: "Kamera kann nicht verwendet werden.") }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { session.commitConfiguration(); throw PoseError(msg: "Kamerabilder können nicht gelesen werden.") }
        session.addOutput(out)
        if let f = best, bestFps > 0 {
            try dev.lockForConfiguration()
            dev.activeFormat = f
            let dur = CMTimeMake(value: 1, timescale: Int32(bestFps.rounded()))
            dev.activeVideoMinFrameDuration = dur
            dev.activeVideoMaxFrameDuration = dur
            dev.unlockForConfiguration()
            cameraFps = bestFps.rounded()
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            dims = (Int(d.height), Int(d.width)) // hochkant
        }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dropped += 1
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if t0 < 0 { t0 = t; lastSend = t }
        if dims.0 == 0 { dims = (CVPixelBufferGetHeight(pb), CVPixelBufferGetWidth(pb)) }

        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
        try? handler.perform([request])

        var s = [Float](repeating: 0, count: 1 + Self.joints.count * 3)
        s[0] = Float(t - t0)
        // größte erkannte Person verwenden
        var bestObs: VNHumanBodyPoseObservation?
        var bestArea: CGFloat = -1
        for obs in request.results ?? [] {
            guard let pts = try? obs.recognizedPoints(.all) else { continue }
            var x0: CGFloat = 1, x1: CGFloat = 0, y0: CGFloat = 1, y1: CGFloat = 0
            for p in pts.values where p.confidence > 0.2 {
                x0 = min(x0, p.location.x); x1 = max(x1, p.location.x)
                y0 = min(y0, p.location.y); y1 = max(y1, p.location.y)
            }
            let area = max(0, x1 - x0) * max(0, y1 - y0)
            if area > bestArea { bestArea = area; bestObs = obs }
        }
        if let obs = bestObs, let pts = try? obs.recognizedPoints(.all) {
            for (i, j) in Self.joints.enumerated() {
                if let p = pts[j], p.confidence > 0.05 {
                    s[1 + i * 3] = Float(p.location.x)
                    s[2 + i * 3] = Float(1 - p.location.y)
                    s[3 + i * 3] = p.confidence
                }
            }
        }
        batch.append(contentsOf: s)
        batchCount += 1
        frameTimes.append(t)
        while let f = frameTimes.first, f < t - 1 { frameTimes.removeFirst() }

        if t - lastSend >= 0.033 {
            lastSend = t
            let payload: [String: Any] = [
                "n": batchCount, "stride": s.count, "d": batch.base64(),
                "fps": frameTimes.count, "cam": cameraFps, "drop": dropped,
                "w": dims.0, "h": dims.1
            ]
            batch.removeAll(keepingCapacity: true)
            batchCount = 0
            onBatch?(payload)
        }
    }
}
