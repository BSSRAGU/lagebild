import ARKit
import simd
import Vision

/// Liefert die LiDAR-Tiefenkarte verkleinert und hochkant gedreht (etwa 8-mal pro Sekunde).
/// Zusätzlich je Bildpunkt: Höhe über dem erkannten Boden und waagerechter Abstand zum Telefon.
final class DepthSensor: NSObject, ARSessionDelegate {
    static var isSupported: Bool {
        return ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    var onFrame: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?

    private var session: ARSession?
    private var lastTimestamp: TimeInterval = 0
    private let queue = DispatchQueue(label: "lagebild.depth")

    // Eigene Raumkarte: Messpunkte als 5-cm-Würfel (Voxel) im Raumkoordinatensystem sammeln
    static let voxelSize: Float = 0.05
    static let maxVoxels = 400_000
    private var mapping = false
    private var voxels = Set<Int64>()

    // Personenerkennung (Apple Vision) auf dem Kamerabild, Abstand aus LiDAR
    private var lastPersonTime: TimeInterval = 0
    private var persons: [[Float]] = []
    // Objekterkennung: Bildklassifikation je Drittel (links, Mitte, rechts) etwa 1-mal pro Sekunde
    private var lastObjectTime: TimeInterval = 0
    private var objects: [[String: Any]] = []
    private static let ignoredLabels: Set<String> = ["structure", "indoor", "interior_room", "room", "material", "wood_processed", "wood_natural", "textile", "wall", "floor", "ceiling", "housewares", "consumer_electronics", "machine", "conveyance", "tool", "document", "liquid", "art", "light", "sky", "outdoor"]
    private lazy var humanRequest: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = false
        return r
    }()

    private static func key(_ x: Int32, _ y: Int32, _ z: Int32) -> Int64 {
        let ox = Int64(x) + 1_048_576, oy = Int64(y) + 1_048_576, oz = Int64(z) + 1_048_576
        return (ox << 42) | (oy << 21) | oz
    }

    func start(mapping: Bool = false) {
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
        config.planeDetection = [.horizontal]
        lastTimestamp = 0
        self.mapping = mapping
        queue.async { self.voxels.removeAll(keepingCapacity: true) }
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

    /// Bodenhöhe aus erkannten waagerechten Ebenen: bevorzugt als Boden klassifiziert,
    /// sonst die tiefste Ebene, die mindestens 50 cm unter dem Telefon liegt.
    private func floorHeight(_ frame: ARFrame, cameraY: Float) -> Float? {
        var best: Float?
        for anchor in frame.anchors {
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { continue }
            let y = plane.transform.columns.3.y
            var isFloor = false
            if ARPlaneAnchor.isClassificationSupported, case .floor = plane.classification { isFloor = true }
            if !isFloor && y > cameraY - 0.5 { continue }
            if best == nil || y < best! { best = y }
        }
        return best
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastTimestamp >= 0.12 else { return }
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

        // Kameramodell auf die Auflösung der Tiefenkarte umrechnen
        let K = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let scaleX = Float(w) / Float(res.width)
        let scaleY = Float(h) / Float(res.height)
        let fx = K[0][0] * scaleX, fy = K[1][1] * scaleY
        let cx = K[2][0] * scaleX, cy = K[2][1] * scaleY
        let T = frame.camera.transform
        let camPos = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        let floorY = floorHeight(frame, cameraY: camPos.y)

        // 4×4-Blöcke zusammenfassen (nächster gültiger Wert) und um 90° im Uhrzeigersinn drehen
        let step = 4
        let sw = w / step
        let sh = h / step
        let ow = sh
        let oh = sw
        var outDepth = [Float](repeating: 0, count: ow * oh)
        var outHeight = [Float](repeating: -999, count: ow * oh)
        var outHoriz = [Float](repeating: 0, count: ow * oh)
        for oy in 0..<oh {
            for ox in 0..<ow {
                let sx = oy
                let sy = sh - 1 - ox
                var best: Float = 0
                var bpx = 0, bpy = 0
                for dy in 0..<step {
                    let py = sy * step + dy
                    let row = base.advanced(by: py * rowBytes).assumingMemoryBound(to: Float32.self)
                    let crow = confBase?.advanced(by: py * confRowBytes).assumingMemoryBound(to: UInt8.self)
                    for dx in 0..<step {
                        let px = sx * step + dx
                        if let c = crow, c[px] == 0 { continue }
                        let v = row[px]
                        if v > 0 && (best == 0 || v < best) { best = v; bpx = px; bpy = py }
                    }
                }
                let i = oy * ow + ox
                outDepth[i] = best
                if best > 0 {
                    let xc = (Float(bpx) - cx) * best / fx
                    let yc = -(Float(bpy) - cy) * best / fy
                    let wp = T * SIMD4<Float>(xc, yc, -best, 1)
                    outHoriz[i] = ((wp.x - camPos.x) * (wp.x - camPos.x) + (wp.z - camPos.z) * (wp.z - camPos.z)).squareRoot()
                    if let fy0 = floorY { outHeight[i] = wp.y - fy0 }
                }
            }
        }

        // Personen etwa 3-mal pro Sekunde erkennen; je Person: Mitte, Größe (normiert, hochkant),
        // Abstand (Median LiDAR im Kern des Rahmens), Sicherheit, Raumposition
        if frame.timestamp - lastPersonTime >= 0.3 {
            lastPersonTime = frame.timestamp
            let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .right, options: [:])
            try? handler.perform([humanRequest])
            var list: [[Float]] = []
            for obs in humanRequest.results ?? [] {
                let bb = obs.boundingBox
                let x = Float(bb.midX), y = Float(1 - bb.midY), bw = Float(bb.width), bh = Float(bb.height)
                var vals: [Float] = []
                let gx0 = max(0, Int((x - bw * 0.2) * Float(ow))), gx1 = min(ow - 1, Int((x + bw * 0.2) * Float(ow)))
                let gy0 = max(0, Int((y - bh * 0.2) * Float(oh))), gy1 = min(oh - 1, Int((y + bh * 0.2) * Float(oh)))
                if gx0 <= gx1 && gy0 <= gy1 {
                    for gy in gy0...gy1 {
                        for gx in gx0...gx1 {
                            let v = outDepth[gy * ow + gx]
                            if v > 0 { vals.append(v) }
                        }
                    }
                }
                var d: Float = -1
                var wx: Float = 0, wy: Float = 0, wz: Float = 0
                if !vals.isEmpty {
                    vals.sort()
                    d = vals[vals.count / 2]
                    // Bildmitte der Person zurück in Sensorkoordinaten (quer) und in den Raum projizieren
                    let px = y * Float(w)
                    let py = (1 - x) * Float(h)
                    let xc = (px - cx) * d / fx
                    let yc = -(py - cy) * d / fy
                    let wp = T * SIMD4<Float>(xc, yc, -d, 1)
                    wx = wp.x; wy = wp.y; wz = wp.z
                }
                list.append([x, y, bw, bh, d, Float(obs.confidence), wx, wy, wz])
            }
            persons = list
        }

        if frame.timestamp - lastObjectTime >= 1.0 {
            lastObjectTime = frame.timestamp
            var found: [[String: Any]] = []
            let thirds: [(Int, CGRect)] = [(0, CGRect(x: 0, y: 0.15, width: 0.34, height: 0.7)),
                                           (1, CGRect(x: 0.33, y: 0.15, width: 0.34, height: 0.7)),
                                           (2, CGRect(x: 0.66, y: 0.15, width: 0.34, height: 0.7))]
            let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .right, options: [:])
            var requests: [(Int, VNClassifyImageRequest)] = []
            for (idx, roi) in thirds {
                let r = VNClassifyImageRequest()
                r.regionOfInterest = roi
                requests.append((idx, r))
            }
            try? handler.perform(requests.map { $0.1 })
            for (idx, r) in requests {
                let top = (r.results ?? [])
                    .filter { $0.confidence >= 0.25 && !Self.ignoredLabels.contains($0.identifier) }
                    .prefix(3)
                    .map { [$0.identifier, $0.confidence] as [Any] }
                found.append(["dir": idx, "labels": Array(top)])
            }
            objects = found
        }

        let tracking: String
        switch frame.camera.trackingState {
        case .normal: tracking = "normal"
        case .notAvailable: tracking = "nicht verfügbar"
        case .limited: tracking = "eingeschränkt"
        }
        var payload: [String: Any] = [
            "w": ow, "h": oh, "t": frame.timestamp, "tracking": tracking,
            "data": outDepth.base64(), "hd": outHoriz.base64(), "floor": floorY != nil
        ]
        if let fy0 = floorY {
            payload["hgt"] = outHeight.base64()
            payload["camH"] = camPos.y - fy0
            payload["floorY"] = fy0
        }
        payload["persons"] = persons
        payload["objects"] = objects
        payload["pose"] = [camPos.x, camPos.y, camPos.z, -T.columns.2.x, -T.columns.2.z]

        if mapping, case .normal = frame.camera.trackingState {
            // Feinere Abtastung (jeder 2. Punkt), nur zuverlässige Werte bis 5 m
            var fresh: [Int16] = []
            let vs = Self.voxelSize
            var py = 0
            while py < h {
                let row = base.advanced(by: py * rowBytes).assumingMemoryBound(to: Float32.self)
                let crow = confBase?.advanced(by: py * confRowBytes).assumingMemoryBound(to: UInt8.self)
                var px = 0
                while px < w {
                    let d = row[px]
                    let conf: UInt8 = crow?[px] ?? 2
                    if d > 0.25 && d < 5.0 && conf >= 1 {
                        let xc = (Float(px) - cx) * d / fx
                        let yc = -(Float(py) - cy) * d / fy
                        let wp = T * SIMD4<Float>(xc, yc, -d, 1)
                        let ix = Int32((wp.x / vs).rounded(.down))
                        let iy = Int32((wp.y / vs).rounded(.down))
                        let iz = Int32((wp.z / vs).rounded(.down))
                        if abs(ix) < 32000 && abs(iy) < 32000 && abs(iz) < 32000 && voxels.count < Self.maxVoxels {
                            if voxels.insert(Self.key(ix, iy, iz)).inserted {
                                fresh.append(Int16(ix)); fresh.append(Int16(iy)); fresh.append(Int16(iz))
                            }
                        }
                    }
                    px += 2
                }
                py += 2
            }
            payload["vox"] = fresh.withUnsafeBufferPointer { Data(buffer: $0).base64EncodedString() }
            payload["vs"] = vs
            payload["nvox"] = voxels.count
        }
        onFrame?(payload)
    }
}
