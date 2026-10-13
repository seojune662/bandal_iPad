import UIKit
import WebKit
import ObjectiveC

struct BrowserShortcutBinding: Equatable {
    let input: String
    let modifiers: UIKeyModifierFlags
    let action: String
    let title: String
    init?(_ value: [String: Any]) {
        guard let chord = value["chord"] as? String, chord.count < 80,
              let action = value["action"] as? String, !action.isEmpty, action.count < 80 else { return nil }
        var parts = chord.split(separator: "+").map(String.init)
        guard let key = parts.popLast(), Set(parts).count == parts.count, parts.contains("mod"), Set(parts).isSubset(of: ["mod", "alt", "shift"]) else { return nil }
        var flags: UIKeyModifierFlags = .command
        if parts.contains("alt") { flags.insert(.alternate) }
        if parts.contains("shift") { flags.insert(.shift) }
        // Web editing keeps the standard copy/paste/select/undo keys, even if
        // an imported keymap accidentally assigns one to an app command.
        guard !(flags == .command && ["a", "c", "v", "x", "z"].contains(key)), !(flags == [.command, .shift] && key == "z") else { return nil }
        let named = ["arrowup": UIKeyCommand.inputUpArrow, "arrowdown": UIKeyCommand.inputDownArrow,
                     "arrowleft": UIKeyCommand.inputLeftArrow, "arrowright": UIKeyCommand.inputRightArrow,
                     "escape": UIKeyCommand.inputEscape, "home": UIKeyCommand.inputHome, "end": UIKeyCommand.inputEnd,
                     "pageup": UIKeyCommand.inputPageUp, "pagedown": UIKeyCommand.inputPageDown,
                     "f1": UIKeyCommand.f1, "f2": UIKeyCommand.f2, "f3": UIKeyCommand.f3,
                     "f4": UIKeyCommand.f4, "f5": UIKeyCommand.f5, "f6": UIKeyCommand.f6,
                     "f7": UIKeyCommand.f7, "f8": UIKeyCommand.f8, "f9": UIKeyCommand.f9,
                     "f10": UIKeyCommand.f10, "f11": UIKeyCommand.f11, "f12": UIKeyCommand.f12,
                     "tab": "\t", "enter": "\r", "backspace": "\u{8}", "delete": UIKeyCommand.inputDelete, "space": " "]
        if let special = named[key] { input = special }
        else { guard key.count == 1 else { return nil }; input = key }
        modifiers = flags; self.action = action; title = String((value["label"] as? String ?? action).prefix(160))
    }
}

@MainActor private final class BrowserKeyboardState { var bindings: [BrowserShortcutBinding] = [] }
@MainActor private var browserKeyboardStateKey: UInt8 = 0
extension DesktopBrowserHost {
    private var keyboardState: BrowserKeyboardState {
        if let value = objc_getAssociatedObject(self, &browserKeyboardStateKey) as? BrowserKeyboardState { return value }
        let value = BrowserKeyboardState(); objc_setAssociatedObject(self, &browserKeyboardStateKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC); return value
    }
    var keyboardBindings: [BrowserShortcutBinding] { keyboardState.bindings }
    /// Values are resolved by the original shared keymap and guest policy in
    /// the private runtime, including user remaps and site/app priority.
    func applyShortcuts(_ values: [[String: Any]]) {
        var seen = Set<String>()
        keyboardState.bindings = values.prefix(100).compactMap(BrowserShortcutBinding.init).filter {
            seen.insert("\($0.modifiers.rawValue):\($0.input)").inserted
        }
        UIMenuSystem.main.setNeedsRebuild()
    }
}

@MainActor
final class DesktopBrowserWebView: WKWebView {
    weak var nativePage: DesktopBrowserPage?
    private var ownedPage: DesktopBrowserPage? {
        guard let page = nativePage, let host = page.host, host.pages[page.tabID] === page,
              page.liveWebView === self, page.bounds != nil, !isHidden else { return nil }
        return page
    }
    override var keyCommands: [UIKeyCommand]? {
        let inherited = super.keyCommands ?? []
        guard let page = ownedPage else { return inherited }
        return inherited + (page.host?.keyboardBindings ?? []).map { binding in
            let command = UIKeyCommand(input: binding.input, modifierFlags: binding.modifiers, action: #selector(forwardAppShortcut(_:)))
            command.discoverabilityTitle = binding.title
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticMirroring = false
            return command
        }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(forwardAppShortcut(_:)) {
            guard let command = sender as? UIKeyCommand else { return false }
            return matching(command) != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }
    private func matching(_ command: UIKeyCommand) -> (DesktopBrowserPage, BrowserShortcutBinding)? {
        guard let page = ownedPage, let binding = page.host?.keyboardBindings.first(where: { $0.input == command.input && $0.modifiers == command.modifierFlags }) else { return nil }
        return (page, binding)
    }
    @objc func forwardAppShortcut(_ command: UIKeyCommand) {
        // Resolve again at dispatch, so a remap or hidden tab invalidates a
        // key command already cached by UIKit's responder system.
        guard let (page, binding) = matching(command) else { return }
        let action = binding.action
        if action.hasPrefix("new-") || action.hasPrefix("activate-") || ["close-tab", "reopen-tab", "prev-tab", "next-tab", "focus-address", "find", "open-assistant"].contains(action) { page.host?.shell?.becomeFirstResponder() }
        page.host?.emit("shortcut:passthrough", ["action": action, "webContentsId": page.id])
    }
}
