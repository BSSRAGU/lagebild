import ARKit

/// Liefert die LiDAR-Tiefenkarte (Meter) verkleinert und hochkant gedreht, etwa 10-mal pro Sekunde.
final class DepthSensor: NSObject, ARSessionDelegate {
    static var isSupported: Bool {
        return ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    var onFrame: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?

    private var session: ARSession?
    private var lastTimestamp: TimeInterval = 0
    private let queue = DispatchQueue(label: "lagebild.depth")

    func start() {
        guard Self.isSupported else {
            onError?("Dieses iPhone hat keinen LiDAR-Sensor.")
            return
        }
        stop()
        let s = ARSession()
        s.delegate = self
        s.delegateQueue = queue
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics = [.smoothedSceneDepth]
        } else {
            config.frameSemantics = [.sceneDepth]
        }
        lastTimestamp = 0
        s.run(config, options: [.resetTracking, .removeExistingAnchors])
        session = s
    }

    func stop() {
        session?.pause()
        session = nil
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onError?(error.localizedDescription)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastTimestamp >= 0.1 else { return }
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        lastTimestamp = frame.timestamp

        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        var confBase: UnsafeMutableRawPointer?
        var confRowBytes = 0
        let confMap = depth.confidenceMap
        if let cm = confMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(cm)
            confRowBytes = CVPixelBufferGetBytesPerRow(cm)
        }
        defer { if let cm = confMap { CVPixelBufferUnlockBaseAddress(cm, .readOnly) } }

        // Sensorbild liegt quer; 4×4-Blöcke zusammenfassen (nächster gültiger Wert) und um 90° im Uhrzeigersinn drehen.
        let step = 4
        let sw = w / step
        let sh = h / step
        let ow = sh
        let oh = sw
        var out = [Float](repeating: 0, count: ow * oh)
        for oy in 0..<oh {
            for ox in 0..<ow {
                let sx = oy
                let sy = sh - 1 - ox
                var best: Float = 0
                for dy in 0..<step {
                    let py = sy * step + dy
                    let row = base.advanced(by: py * rowBytes).assumingMemoryBound(to: Float32.self)
                    let crow = confBase?.advanced(by: py * confRowBytes).assumingMemoryBound(to: UInt8.self)
                    for dx in 0..<step {
                        let px = sx * step + dx
                        if let c = crow, c[px] == 0 { continue } // geringe Zuverlässigkeit verwerfen
                        let v = row[px]
                        if v > 0 && (best == 0 || v < best) { best = v }
                    }
                }
                out[oy * ow + ox] = best
            }
        }

        let tracking: String
        switch frame.camera.trackingState {
        case .normal: tracking = "normal"
        case .notAvailable: tracking = "nicht verfügbar"
        case .limited: tracking = "eingeschränkt"
        }
        onFrame?(["w": ow, "h": oh, "t": frame.timestamp, "tracking": tracking, "data": out.base64()])
    }
}
