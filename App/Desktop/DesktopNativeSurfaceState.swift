import UIKit

/// Shell-owned state. Old renderer sessions and out-of-order layout messages
/// cannot uncover a native document after a modal has claimed the screen.
@MainActor
final class DesktopNativeSurfaceState {
    private(set) var sessionID = UUID().uuidString
    private(set) var revision = 0
    private(set) var blocked = false
    private(set) var inputBlocked = false
    private(set) var overlays: [CGRect] = []
    var onChange: (() -> Void)?

    func reset() {
        sessionID = UUID().uuidString; revision = 0
        // Keep old surfaces inaccessible until the new renderer publishes.
        blocked = true; inputBlocked = true; overlays = []
        onChange?()
    }

    func apply(_ request: [String: Any]) throws -> [String: Any] {
        guard request["sessionId"] as? String == sessionID else { throw CancellationError() }
        guard let next = request["revision"] as? Int, next > 0,
              let blocked = request["blocked"] as? Bool,
              let inputBlocked = request["inputBlocked"] as? Bool,
              let rectangles = request["overlays"] as? [[String: Double]], rectangles.count <= 128 else {
            throw DesktopRuntimeError("화면 표시 정보를 확인해 주세요.", code: "INVALID_SURFACE_STATE")
        }
        guard next > revision else { return ["revision": revision] }
        let parsed = try rectangles.map { value -> CGRect in
            guard let x = value["x"], let y = value["y"], let width = value["width"], let height = value["height"],
                  [x,y,width,height].allSatisfy({ $0.isFinite && abs($0) < 100_000 }), width > 0, height > 0 else {
                throw DesktopRuntimeError("화면 영역 정보를 확인해 주세요.", code: "INVALID_SURFACE_STATE")
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        revision = next; self.blocked = blocked; self.inputBlocked = inputBlocked; overlays = parsed
        onChange?()
        return ["revision": revision]
    }
}
