import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Own the stylus stream before PDFKit's recognizers decide whether to delay
/// or cancel delivery to a page overlay's UIResponder. Hit testing alone does
/// not guarantee that UIView.touchesBegan will ever receive the contact.
@MainActor
final class NativePDFPencilGestureRecognizer: UIGestureRecognizer {
    var targetAtLocation: ((CGPoint) -> NativePDFInkSurface?)?
    var onDiagnostic: ((String) -> Void)?
    private(set) var inputTouchType: UITouch.TouchType = .pencil
    private var contact: UITouch?
    private var receiver: NativePDFInkSurface?
    private final class WeakSurface {
        weak var value: NativePDFInkSurface?
        init(_ value: NativePDFInkSurface) { self.value = value }
    }
    // UIKit can report estimated-property corrections after touchesEnded and
    // the recognizer's reset. Keep only weak ownership until the final update.
    private var estimationOwners: [NSNumber: WeakSurface] = [:]
    private var estimatedReportCount = 0

    init() {
        super.init(target: nil, action: nil)
        configureTouchType()
        cancelsTouchesInView = true
        delaysTouchesBegan = false; delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }
    #if DEBUG
    /// Only the isolated UI-testing host selects this initializer. XCTest can
    /// dispatch real finger events, but cannot manufacture hardware Pencil.
    convenience init(testTouchType: UITouch.TouchType) {
        self.init()
        precondition(testTouchType == .direct || testTouchType == .pencil)
        inputTouchType = testTouchType; configureTouchType()
    }
    #endif
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func configureTouchType() {
        allowedTouchTypes = [NSNumber(value: inputTouchType.rawValue)]
    }
    private func report(_ phase: String) {
        onDiagnostic?("\(inputTouchType == .pencil ? "pencil" : "fixture-direct").\(phase)")
    }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Controls/editors return no target and never compete with PDF ink.
        // Direct-only PDFKit navigation belongs to a different touch stream.
        // Keep a finger gesture alive when a Pencil arrives beside it.
        if inputTouchType == .pencil,
           !preventedGestureRecognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)) { return false }
        return receiver != nil && super.canPrevent(preventedGestureRecognizer)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard contact == nil else { return }
        guard let touch = touches.first(where: { $0.type == inputTouchType }) else {
            state = .failed; return
        }
        report("begin")
        guard let view, let surface = targetAtLocation?(touch.location(in: view)) else {
            report("ignored-target"); state = .failed; return
        }
        contact = touch; receiver = surface
        rememberEstimates(event.coalescedTouches(for: touch) ?? [touch], for: surface)
        guard surface.beginPencilGesture(touch, with: event, directFixture: inputTouchType == .direct) else {
            report("rejected-surface"); contact = nil; receiver = nil; state = .failed; return
        }
        // Recognize on the first contact, not after a distance/time threshold.
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = contact, touches.contains(touch), let surface = receiver else { return }
        rememberEstimates(event.coalescedTouches(for: touch) ?? [touch], for: surface)
        surface.movePencilGesture(touch, with: event)
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = contact, touches.contains(touch), let surface = receiver else { return }
        rememberEstimates(event.coalescedTouches(for: touch) ?? [touch], for: surface)
        surface.endPencilGesture(touch, with: event)
        report("end"); contact = nil; receiver = nil; state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = contact, touches.contains(touch), let surface = receiver else { return }
        surface.cancelPencilGesture(touch, with: event)
        report("cancel"); contact = nil; receiver = nil; state = .cancelled
    }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        var groups: [ObjectIdentifier: (NativePDFInkSurface, Set<UITouch>)] = [:]
        for touch in touches {
            guard let key = touch.estimationUpdateIndex,
                  let surface = estimationOwners[key]?.value else { continue }
            let identity = ObjectIdentifier(surface)
            if groups[identity] == nil { groups[identity] = (surface, []) }
            groups[identity]?.1.insert(touch)
            if touch.estimatedPropertiesExpectingUpdates.isEmpty { estimationOwners.removeValue(forKey: key) }
        }
        for (surface, updates) in groups.values { surface.updatePencilGestureProperties(updates) }
        estimationOwners = estimationOwners.filter { $0.value.value != nil }
        if !groups.isEmpty {
            estimatedReportCount += 1
            // Hardware Pencil can send hundreds of corrections per second.
            // Keep input processing independent of diagnostic disk traffic.
            if estimatedReportCount <= 8 || estimatedReportCount.isMultiple(of: 100) { report("estimated-update") }
        }
    }
    override func reset() {
        // A recognizer disabled or reset during a contact still finishes its
        // measured data. Predicted points never enter the completion journal.
        if let touch = contact, let receiver { receiver.cancelPencilGesture(touch, with: nil); report("reset-cancel") }
        contact = nil; receiver = nil
        estimationOwners = estimationOwners.filter { $0.value.value != nil }
        super.reset()
    }
    private func rememberEstimates(_ touches: [UITouch], for surface: NativePDFInkSurface) {
        for touch in touches {
            guard let key = touch.estimationUpdateIndex else { continue }
            if !touch.estimatedPropertiesExpectingUpdates.isEmpty { estimationOwners[key] = WeakSurface(surface) }
        }
    }
}
