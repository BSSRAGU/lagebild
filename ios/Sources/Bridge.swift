import Foundation
import WebKit

/// Verhindert einen Retain-Zyklus zwischen WKUserContentController und dem View Controller.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

extension Array where Element == Float {
    func base64() -> String {
        return withUnsafeBufferPointer { Data(buffer: $0).base64EncodedString() }
    }
}

extension Data {
    func floatArray() -> [Float] {
        let count = self.count / MemoryLayout<Float>.size
        var out = [Float](repeating: 0, count: count)
        _ = out.withUnsafeMutableBufferPointer { dst in
            self.copyBytes(to: dst)
        }
        return out
    }
}
