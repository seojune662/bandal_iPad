import SwiftUI

/// SwiftUI registers these with the containing hosting controller, so the
/// shortcuts also work while a native text view has keyboard focus.
struct NativeWorkspaceKeyboardBridge: View {
    @ObservedObject var store: NativeWorkspaceStore
    @State private var bindings: [Binding] = []
    private struct Binding: Identifiable {
        let id: String
        let action: String
        let key: KeyEquivalent
        let modifiers: EventModifiers
    }
    var body: some View {
        ZStack {
            ForEach(bindings) { binding in
                Button("") { store.events.send(.init(channel:"shortcut:passthrough",payload:["action":binding.action])) }
                    .keyboardShortcut(binding.key,modifiers:binding.modifiers)
            }
        }.frame(width:0,height:0).clipped().allowsHitTesting(false).accessibilityHidden(true)
        .task(id:store.isReady) {
            if store.isReady, let settings = try? await store.invoke("settings:get") as? [String:Any] { apply(settings) }
        }
        .onReceive(store.events) { event in
            if event.channel == "settings:changed", let payload = event.payload as? [String:Any], let settings = payload["settings"] as? [String:Any] { apply(settings) }
        }
    }
    private func apply(_ settings: [String:Any]) {
        let actions: Set<String> = ["new-tab","new-markdown","new-whiteboard","new-ai-tab","new-recording-tab","open-study-board","close-tab","prev-tab","next-tab","activate-last-tab","toggle-left-rail"]
        bindings = NativeBrowserShortcuts.resolve(settings).compactMap { item in
            guard let action = item["action"] as? String, actions.contains(action) || action.hasPrefix("activate-tab-"), let raw = item["chord"] as? String else { return nil }
            let parts = raw.split(separator:"+"); guard let rawKey = parts.last, let key = NativeWorkspaceKeyEquivalent.resolve(String(rawKey)) else { return nil }
            var modifiers: EventModifiers = [.command]
            if parts.contains("alt") { modifiers.insert(.option) }; if parts.contains("shift") { modifiers.insert(.shift) }
            return Binding(id:raw,action:action,key:key,modifiers:modifiers)
        }
    }
}

/// The preferences editor accepts these named keys as well as characters.
/// Keep native editors consistent with BrowserShortcutBinding's UIKit mapping.
enum NativeWorkspaceKeyEquivalent {
    static func resolve(_ key: String) -> KeyEquivalent? {
        // UIKit's function-key inputs are string tokens, not characters.
        // SwiftUI cannot register them through KeyEquivalent; the settings
        // editor rejects them instead of accepting an inactive global remap.
        switch key.lowercased() {
        case "arrowup": return .upArrow
        case "arrowdown": return .downArrow
        case "arrowleft": return .leftArrow
        case "arrowright": return .rightArrow
        case "escape": return .escape
        case "backspace": return .delete
        case "delete": return .deleteForward
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "tab": return .tab
        case "space": return .space
        case "enter", "return": return .return
        default: return key.count == 1 ? key.first.map { KeyEquivalent($0) } : nil
        }
    }
}
