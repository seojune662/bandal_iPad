import Foundation

/// A WebKit completion belongs to one dialog and must settle exactly once,
/// including navigation, backgrounding and controller teardown.
@MainActor
final class DesktopDialogCompletion<Value> {
    private var callback: ((Value) -> Void)?
    init(_ callback: @escaping (Value) -> Void) { self.callback = callback }
    func finish(_ value: Value) { let pending = callback; callback = nil; pending?(value) }
}

