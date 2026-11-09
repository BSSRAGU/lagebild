import AVFoundation

/// Sendet ein periodisches Referenzsignal über den Lautsprecher und liefert das Mikrofonsignal
/// in Blöcken fester Länge. Die Audio-Session läuft im Messmodus: keine Echounterdrückung,
/// keine Rauschunterdrückung, keine automatische Verstärkung.
final class SonarAudio {
    var onBlock: (([String: Any]) -> Void)?
    var onState: (([String: Any]) -> Void)?

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var reference: [Float] = []
    private var gain: Float = 0
    private var txPos = 0

    private let inputQueue = DispatchQueue(label: "lagebild.sonar.input")
    private var acc: [Float] = []
    private var accStartFrame: Int64 = 0
    private var nextFrame: Int64 = -1
    private var seq = 0
    private var clip = 0
    private var gap = 0
    private var blockSize = 2048
    private(set) var sampleRate: Double = 48000
    private var observers: [NSObjectProtocol] = []

    func start(blockSize: Int) throws -> Double {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)

        let eng = AVAudioEngine()
        let input = eng.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Lagebild", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Kein Mikrofon verfügbar."])
        }
        sampleRate = inFormat.sampleRate
        self.blockSize = blockSize

        lock.lock()
        reference = []
        gain = 0
        txPos = 0
        lock.unlock()
        inputQueue.sync {
            acc = []
            nextFrame = -1
            seq = 0
            clip = 0
            gap = 0
        }

        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "Lagebild", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audioformat nicht verfügbar."])
        }
        let sourceNode = AVAudioSourceNode(format: outFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            guard let self = self else {
                for b in buffers { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
                return noErr
            }
            self.lock.lock()
            let ref = self.reference
            let g = self.gain
            let pos = self.txPos
            self.lock.unlock()
            let m = ref.count
            for b in buffers {
                guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if m == 0 {
                    for i in 0..<n { d[i] = 0 }
                } else {
                    var q = pos
                    for i in 0..<n {
                        d[i] = ref[q] * g
                        q += 1
                        if q == m { q = 0 }
                    }
                }
            }
            if m > 0 {
                self.lock.lock()
                if self.reference.count == m { self.txPos = (pos + n) % m }
                self.lock.unlock()
            }
            return noErr
        }
        eng.attach(sourceNode)
        eng.connect(sourceNode, to: eng.mainMixerNode, format: outFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, time in
            guard let self = self, let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var samples = [Float](repeating: 0, count: n)
            for i in 0..<n { samples[i] = ch[i] }
            let start: Int64 = time.isSampleTimeValid ? time.sampleTime : -1
            self.inputQueue.async { self.consume(samples, start: start) }
        }

        eng.prepare()
        try eng.start()
        engine = eng
        observe()
        return sampleRate
    }

    private func consume(_ samples: [Float], start: Int64) {
        let n = samples.count
        let first = start >= 0 ? start : (nextFrame >= 0 ? nextFrame : 0)
        if nextFrame >= 0 && first != nextFrame { gap += 1 }
        if acc.isEmpty { accStartFrame = first }
        nextFrame = first + Int64(n)
        for v in samples {
            if v > 0.98 || v < -0.98 { clip += 1 }
        }
        acc.append(contentsOf: samples)
        while acc.count >= blockSize {
            let block = Array(acc[0..<blockSize])
            acc.removeFirst(blockSize)
            let payload: [String: Any] = [
                "seq": seq, "frame": accStartFrame, "clip": clip, "gap": gap, "data": block.base64()
            ]
            seq += 1
            accStartFrame += Int64(blockSize)
            clip = 0
            gap = 0
            onBlock?(payload)
        }
    }

    func setReference(_ ref: [Float]) {
        lock.lock()
        reference = ref
        txPos = 0
        lock.unlock()
    }

    func setGain(_ g: Float) {
        lock.lock()
        gain = max(0, min(1, g))
        lock.unlock()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let eng = engine else { return }
        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
        engine = nil
        lock.lock()
        reference = []
        gain = 0
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
            self?.onState?(["type": "interrupted", "reason": "Audio vom System unterbrochen (z. B. Anruf)."])
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .override {
                self?.stop()
                self?.onState?(["type": "route", "reason": "Audioausgang oder Mikrofon gewechselt – bitte neu starten."])
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
            self?.onState?(["type": "reset", "reason": "Audiodienste von iOS neu gestartet."])
        })
    }
}
