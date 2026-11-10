import UIKit
import WebKit
import AVFoundation

final class WebViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let startURL = URL(string: "https://bssragu.github.io/lagebild/")!
    static let allowedHost = "bssragu.github.io"
    static let httpHosts: Set<String> = ["api.adsb.lol", "api.airplanes.live", "api.adsbdb.com"]

    private var webView: WKWebView!
    private let audio = SonarAudio()
    private let depth = DepthSensor()
    private let pose = PoseTracker()
    private var previewView: UIView?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var bgColor = UIColor.black
    private var updateChecked = false
    static let versionURL = URL(string: "https://github.com/BSSRAGU/lagebild/releases/download/app-latest/version.json")!
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var appBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0 }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        let bg = UIColor(red: 7 / 255, green: 12 / 255, blue: 22 / 255, alpha: 1)
        view.backgroundColor = bg
        bgColor = bg

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let ucc = WKUserContentController()
        ucc.add(WeakMessageHandler(self), name: "lagebild")
        let lidar = DepthSensor.isSupported ? "true" : "false"
        let bridge = """
        window.LagebildNative={caps:{version:'\(Self.appVersion) (Build \(Self.appBuild))',build:\(Self.appBuild),rawAudio:true,http:true,persons:\(lidar),lidar:\(lidar),lidarMap:\(lidar),haptics:true,pose:true,poseFront:true,poseZoom:true},on:{},
        post:function(m){window.webkit.messageHandlers.lagebild.postMessage(m)},
        dispatch:function(t,d){var f=this.on[t];if(f){try{f(d)}catch(e){console.error(e)}}}};
        """
        ucc.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = bg
        webView.scrollView.backgroundColor = bg
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view.addSubview(webView)

        audio.onBlock = { [weak self] payload in self?.send("audioBlock", payload) }
        audio.onState = { [weak self] payload in self?.send("audioState", payload) }
        depth.onFrame = { [weak self] payload in self?.send("depth", payload) }
        depth.onError = { [weak self] message in self?.send("depthError", ["message": message]) }
        pose.onBatch = { [weak self] payload in self?.send("pose", payload) }
        pose.onStarted = { [weak self] payload in self?.send("poseStarted", payload) }
        pose.onError = { [weak self] message in
            DispatchQueue.main.async { self?.hidePreview() }
            self?.send("poseError", ["message": message])
        }

        NotificationCenter.default.addObserver(self, selector: #selector(stopSensors),
                                               name: UIApplication.willResignActiveNotification, object: nil)

        webView.load(URLRequest(url: Self.startURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !updateChecked {
            updateChecked = true
            checkForUpdate()
        }
    }

    /// Prüft beim Start, ob auf GitHub ein neuerer Build liegt, und bietet die Installation über AltStore an.
    private func checkForUpdate() {
        let req = URLRequest(url: Self.versionURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let latest = (obj["build"] as? NSNumber)?.intValue,
                  latest > Self.appBuild else { return }
            let ipa = obj["ipa"] as? String ?? "https://github.com/BSSRAGU/lagebild/releases/download/app-latest/Lagebild.ipa"
            DispatchQueue.main.async { self?.offerUpdate(build: latest, ipa: ipa) }
        }.resume()
    }

    private func offerUpdate(build: Int, ipa: String) {
        let alert = UIAlertController(
            title: "Neue App-Version",
            message: "Build \(build) ist verfügbar (installiert: Build \(Self.appBuild)). Jetzt über AltStore aktualisieren? AltServer muss dazu auf dem PC laufen.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Später", style: .cancel))
        alert.addAction(UIAlertAction(title: "Aktualisieren", style: .default) { _ in
            var comps = URLComponents(string: "altstore://install")
            comps?.queryItems = [URLQueryItem(name: "url", value: ipa)]
            guard let target = comps?.url else { return }
            UIApplication.shared.open(target) { ok in
                if !ok, let web = URL(string: ipa) { UIApplication.shared.open(web) }
            }
        })
        present(alert, animated: true)
    }

    @objc private func stopSensors() {
        audio.stop()
        depth.stop()
        pose.stop()
        hidePreview()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView?.bounds ?? .zero
    }

    /// Kamerabild hinter die (dann durchsichtige) Webseite legen
    private func showPreview() {
        if previewView == nil {
            let pv = UIView(frame: view.bounds)
            pv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pv.backgroundColor = .black
            let layer = AVCaptureVideoPreviewLayer(session: pose.session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = pv.bounds
            if let c = layer.connection, c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            pv.layer.addSublayer(layer)
            view.insertSubview(pv, belowSubview: webView)
            previewView = pv
            previewLayer = layer
        }
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func hidePreview() {
        previewLayer?.removeFromSuperlayer()
        previewView?.removeFromSuperview()
        previewLayer = nil
        previewView = nil
        webView?.backgroundColor = bgColor
        webView?.scrollView.backgroundColor = bgColor
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func startPose(maxFps: Double, front: Bool) {
        showPreview()
        pose.start(maxFps: maxFps, front: front)
        // Ausrichtung der Vorschau nach dem Kamerawechsel erneut setzen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if let c = self?.previewLayer?.connection, c.isVideoOrientationSupported { c.videoOrientation = .portrait }
        }
    }

    // MARK: - Nachrichten von der Webseite

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.securityOrigin.host == Self.allowedHost,
              let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "audioStart":
            let n = (body["N"] as? NSNumber)?.intValue ?? 2048
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                startAudio(blockSize: n)
            case .denied:
                send("audioError", ["message": "Mikrofonzugriff verweigert. Einstellungen → Lagebild → Mikrofon erlauben."])
            default:
                session.requestRecordPermission { [weak self] ok in
                    DispatchQueue.main.async {
                        if ok { self?.startAudio(blockSize: n) }
                        else { self?.send("audioError", ["message": "Mikrofonzugriff verweigert."]) }
                    }
                }
            }
        case "audioRef":
            if let b64 = body["ref"] as? String, let data = Data(base64Encoded: b64) {
                audio.setReference(data.floatArray())
            }
            if let g = body["gain"] as? NSNumber { audio.setGain(g.floatValue) }
        case "audioGain":
            if let g = body["v"] as? NSNumber { audio.setGain(g.floatValue) }
        case "audioStop":
            audio.stop()
        case "depthStart":
            depth.start(mapping: (body["map"] as? Bool) ?? false)
        case "depthStop":
            depth.stop()
        case "poseStart":
            let fps = (body["fps"] as? NSNumber)?.doubleValue ?? 240
            let front = (body["front"] as? Bool) ?? false
            depth.stop()
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                startPose(maxFps: fps, front: front)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                    DispatchQueue.main.async {
                        if ok { self?.startPose(maxFps: fps, front: front) }
                        else { self?.send("poseError", ["message": "Kamerazugriff verweigert."]) }
                    }
                }
            default:
                send("poseError", ["message": "Kamerazugriff verweigert. Einstellungen → Lagebild → Kamera erlauben."])
            }
        case "poseZoom":
            pose.setZoom((body["z"] as? NSNumber)?.doubleValue ?? 1)
        case "poseStop":
            pose.stop()
            hidePreview()
        case "http":
            let id = body["id"] as? String ?? ""
            guard let s = body["url"] as? String, let url = URL(string: s),
                  let host = url.host, Self.httpHosts.contains(host) else {
                send("httpResult", ["id": id, "status": 0, "error": "Adresse nicht freigegeben"])
                return
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            req.setValue("Lagebild/1.0", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                var out: [String: Any] = ["id": id, "status": status, "body": String(data: data ?? Data(), encoding: .utf8) ?? ""]
                if let e = error { out["error"] = e.localizedDescription }
                self?.send("httpResult", out)
            }.resume()
        case "haptic":
            let style: UIImpactFeedbackGenerator.FeedbackStyle
            switch body["style"] as? String {
            case "light": style = .light
            case "heavy": style = .heavy
            default: style = .medium
            }
            let gen = UIImpactFeedbackGenerator(style: style)
            gen.prepare()
            gen.impactOccurred()
        default:
            break
        }
    }

    private func startAudio(blockSize: Int) {
        do {
            let fs = try audio.start(blockSize: blockSize)
            send("audioStarted", ["fs": fs])
        } catch {
            send("audioError", ["message": error.localizedDescription])
        }
    }

    // MARK: - Nachrichten an die Webseite

    private func send(_ type: String, _ payload: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        let js = "window.LagebildNative&&window.LagebildNative.dispatch('\(type)',\(text));"
        if Thread.isMainThread {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    // MARK: - Navigation und Berechtigungen

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stopSensors()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let host = url.host, host != Self.allowedHost,
           navigationAction.targetFrame?.isMainFrame ?? true {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == Self.allowedHost ? .grant : .deny)
    }

    func webView(_ webView: WKWebView,
                 requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == Self.allowedHost ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stopSensors()
        webView.reload()
    }
}
