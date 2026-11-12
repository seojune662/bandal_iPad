import UIKit
import UIKit.UIGestureRecognizerSubclass
import os

/// Opt-in input diagnostics for the centre pane: where each touch lands, which gesture recognizers received it
/// and how each one ended, and every state change that can stop an editor from taking input.
///
/// Off unless the process is launched with `--native-input-trace` (simulator, UI tests) or the
/// `native.debug.inputTrace` default is set (a device). When off, every call returns at its first line.
/// It never changes delivery: its window recognizer stays `.possible`, and neither cancels, delays nor prevents.
///
/// Lines go to the unified log (`subsystem == "app.bandal" AND category == "input"`) and, once `start(root:)`
/// ran, to `Logs/input-trace.log` under the storage root. Only class names, accessibility identifiers cut at
/// their first `:`, coordinates, flags and durations are written: no document names, paths or content.
@MainActor enum NativeInputTrace {
    nonisolated static let isEnabled = ProcessInfo.processInfo.arguments.contains("--native-input-trace")
        || UserDefaults.standard.bool(forKey: "native.debug.inputTrace")
    private static let logger = Logger(subsystem: "app.bandal", category: "input")
    private static var file: URL?
    private static let queue = DispatchQueue(label: "app.bandal.input-trace", qos: .utility)
    private static let started = ProcessInfo.processInfo.systemUptime
    private static var last: [String: String] = [:]

    static func record(_ event: String, _ detail: @autoclosure () -> String = "") {
        guard isEnabled else { return }
        let detail = detail()
        let line = String(format: "%8.3f ", ProcessInfo.processInfo.systemUptime - started) + (detail.isEmpty ? event : event + " " + detail)
        logger.notice("\(line, privacy: .public)")
        guard let file else { return }
        queue.async {
            let bytes = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                if (try? handle.seekToEnd()) ?? 0 > 2_000_000 { try? handle.truncate(atOffset: 0) }
                try? handle.write(contentsOf: bytes)
            } else { try? bytes.write(to: file, options: .atomic) }
        }
    }
    /// A state that is only worth a line when it changes (`key` names the state, `value` its current reading).
    static func change(_ key: String, _ value: @autoclosure () -> String) {
        guard isEnabled else { return }
        let value = value()
        guard last[key] != value else { return }
        last[key] = value; record(key, value)
    }
    static func start(root: URL) {
        guard isEnabled, file == nil else { return }
        let folder = root.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("input-trace.log")
        record("trace.start", "os=\(UIDevice.current.systemVersion)")
    }
    /// Watches every touch of `window`. Safe to call again: one recognizer per window.
    static func install(in window: UIWindow?) {
        guard isEnabled, let window, !(window.gestureRecognizers ?? []).contains(where: { $0 is Watcher }) else { return }
        window.addGestureRecognizer(Watcher())
        record("window", describe(window))
    }
    static func describe(_ window: UIWindow) -> String {
        let insets = window.safeAreaInsets, bounds = window.bounds, screen = window.windowScene?.screen.bounds ?? .zero
        return String(format: "bounds=%.0fx%.0f screen=%.0fx%.0f safeTop=%.1f safeBottom=%.1f safeLeft=%.1f safeRight=%.1f",
                      bounds.width, bounds.height, screen.width, screen.height, insets.top, insets.bottom, insets.left, insets.right)
    }
    /// The view a touch landed on and its ancestors, nearest first: `Class#identifier` joined by `<`.
    static func chain(_ view: UIView?, limit: Int = 16) -> String {
        var names: [String] = [], current = view
        while let item = current, names.count < limit {
            var name = String(describing: type(of: item))
            if name.count > 44 { name = String(name.prefix(44)) + "…" }
            if let identifier = item.accessibilityIdentifier, !identifier.isEmpty { name += "#" + String(identifier.prefix { $0 != ":" }.prefix(40)) }
            if item.isHidden { name += "[hidden]" }
            if !item.isUserInteractionEnabled { name += "[noTouch]" }
            names.append(name); current = item.superview
        }
        if current != nil { names.append("…") }
        return names.isEmpty ? "nil" : names.joined(separator: "<")
    }
    /// The subviews of `root` (to four levels) whose frames contain `point`, top-most first.
    static func under(_ point: CGPoint, in root: UIView, depth: Int = 0) -> String {
        guard depth < 4 else { return "" }
        var parts: [String] = []
        for view in root.subviews.reversed() where view.frame.contains(point) {
            var name = String(describing: type(of: view))
            if name.count > 36 { name = String(name.prefix(36)) + "…" }
            let frame = view.frame
            name += String(format: "(%.0f,%.0f %.0fx%.0f)", frame.minX, frame.minY, frame.width, frame.height)
            if view.isHidden { name += "[hidden]" }
            if !view.isUserInteractionEnabled { name += "[noTouch]" }
            if view.alpha < 0.02 { name += "[clear]" }
            let inner = under(view.convert(point, from: root), in: view, depth: depth + 1)
            parts.append(inner.isEmpty ? name : name + "{" + inner + "}")
        }
        return parts.isEmpty ? (depth == 0 ? "none" : "") : parts.joined(separator: " | ")
    }
    static func name(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: "possible"; case .began: "began"; case .changed: "changed"; case .ended: "ended"
        case .cancelled: "cancelled"; case .failed: "failed"; @unknown default: "unknown"
        }
    }
    static func name(_ type: UITouch.TouchType) -> String {
        switch type { case .direct: "finger"; case .pencil: "pencil"; case .indirect: "indirect"; case .indirectPointer: "pointer"; @unknown default: "unknown" }
    }

    /// Sees the same touches as the views under it and reports them; it takes no part in recognition.
    private final class Watcher: UIGestureRecognizer {
        private struct Contact { let id: Int; let start: CGPoint; var moves = 0; var recognizers: [UIGestureRecognizer]; var states: [ObjectIdentifier: UIGestureRecognizer.State] }
        private var contacts: [ObjectIdentifier: Contact] = [:]
        private var next = 0
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
            requiresExclusiveTouchType = false
            allowedTouchTypes = [UITouch.TouchType.direct, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches {
                next += 1
                let point = touch.location(in: view), others = (touch.gestureRecognizers ?? []).filter { $0 !== self }
                contacts[ObjectIdentifier(touch)] = Contact(id: next, start: point, recognizers: others,
                    states: Dictionary(uniqueKeysWithValues: others.map { (ObjectIdentifier($0), $0.state) }))
                NativeInputTrace.record("touch#\(next).began", String(format: "%@ x=%.0f y=%.0f", NativeInputTrace.name(touch.type), point.x, point.y)
                    + " hit=" + NativeInputTrace.chain(touch.view))
                NativeInputTrace.record("touch#\(next).recognizers", others.isEmpty ? "none" : others.map(Self.label).joined(separator: " "))
                // A touch that stopped at a hosting view was claimed by SwiftUI content: list the UIKit views under
                // the same point that it did not reach.
                if let hit = touch.view, String(describing: type(of: hit)).hasPrefix("_UIHostingView") {
                    NativeInputTrace.record("touch#\(next).under", NativeInputTrace.under(touch.location(in: hit), in: hit))
                }
                if point.y < 64, let window = view as? UIWindow { NativeInputTrace.record("touch#\(next).window", NativeInputTrace.describe(window)) }
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches { contacts[ObjectIdentifier(touch)]?.moves += 1; report(touch, phase: "moved") }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, phase: "ended") }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, phase: "cancelled") }
        override func reset() { super.reset(); contacts.removeAll() }

        /// A line for every recognizer whose state changed since the last look.
        private func report(_ touch: UITouch, phase: String) {
            guard var contact = contacts[ObjectIdentifier(touch)] else { return }
            for recognizer in contact.recognizers where contact.states[ObjectIdentifier(recognizer)] != recognizer.state {
                let before = contact.states[ObjectIdentifier(recognizer)] ?? .possible
                contact.states[ObjectIdentifier(recognizer)] = recognizer.state
                NativeInputTrace.record("touch#\(contact.id).\(phase)", Self.label(recognizer) + " " + NativeInputTrace.name(before) + "→" + NativeInputTrace.name(recognizer.state))
            }
            contacts[ObjectIdentifier(touch)] = contact
        }
        private func finish(_ touches: Set<UITouch>, phase: String) {
            for touch in touches {
                report(touch, phase: phase)
                guard let contact = contacts.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
                let point = touch.location(in: view)
                NativeInputTrace.record("touch#\(contact.id).\(phase)", String(format: "moves=%d dx=%.0f dy=%.0f", contact.moves, point.x - contact.start.x, point.y - contact.start.y)
                    + " final=" + contact.recognizers.map { Self.label($0) + ":" + NativeInputTrace.name($0.state) }.joined(separator: " "))
            }
            // No state is set: a recognizer still `.possible` when its last touch lifts is reset by UIKit, and
            // failing here on the first lift would hide the rest of a two-finger gesture.
        }
        private static func label(_ recognizer: UIGestureRecognizer) -> String {
            var name = String(describing: type(of: recognizer))
            if name.count > 48 { name = String(name.prefix(48)) + "…" }
            let owner = recognizer.view.map { String(describing: type(of: $0)) } ?? "nil"
            return name + "@" + String(owner.prefix(32)) + (recognizer.isEnabled ? "" : "[off]")
        }
    }
}
